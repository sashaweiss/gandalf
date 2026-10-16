import Foundation
import NIOConcurrencyHelpers

/// A request as the router sees it, independent of the HTTP library.
public struct Request: Sendable {
    public var method: String
    /// The raw request target, e.g. `/api/review?since=2`.
    public var uri: String
    /// Header names lowercased.
    public var headers: [String: String]
    public var body: Data

    public init(method: String, uri: String, headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.uri = uri
        self.headers = headers
        self.body = body
    }

    private var components: URLComponents? { URLComponents(string: uri) }

    public var path: String { components?.path ?? uri }

    /// The first value of a query parameter, or "" when absent.
    public func queryValue(_ key: String) -> String {
        components?.queryItems?.first { $0.name == key }?.value ?? ""
    }
}

public struct Response: Sendable {
    public var status: Int
    public var contentType: String
    public var body: Data

    public static func json(_ value: JSON, status: Int = 200) -> Response {
        Response(
            status: status, contentType: "application/json; charset=utf-8",
            body: Data(value.serialized().utf8)
        )
    }

    public static func error(_ message: String, status: Int = 500) -> Response {
        json(.object(["error": .string(message)]), status: status)
    }
}

// Hostnames that count as "this machine". The server only ever binds
// loopback, so a request whose Host names anything else reached us via DNS
// rebinding.
let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]

let contentTypes = [
    "html": "text/html; charset=utf-8",
    "css": "text/css; charset=utf-8",
    "js": "text/javascript; charset=utf-8",
    "svg": "image/svg+xml",
]

/// The web UI, by file name, compiled in from `public/` so the binary is all
/// there is to install. A file added to `public/` needs an entry here; the
/// tests check that none is missing.
let uiFiles: [String: Data] = [
    "index.html": Data(PackageResources.index_html),
    "style.css": Data(PackageResources.style_css),
    "app.js": Data(PackageResources.app_js),
    "highlight.js": Data(PackageResources.highlight_js),
    "favicon.svg": Data(PackageResources.favicon_svg),
]

/// Routes requests to the review logic. Safe to call from any thread: the
/// only mutable state is on disk, behind `stateLock`.
public final class Router: Sendable {
    public let cfg: ReviewConfig
    private let stateLock = NIOLock()

    public init(_ cfg: ReviewConfig) {
        self.cfg = cfg
    }

    private var repo: String { cfg.repo }
    private var stateRoot: String { cfg.stateRoot }

    // MARK: - Entry point

    public func handle(_ req: Request) -> Response {
        if let denied = guardLocal(req) { return denied }
        do {
            switch req.method {
            case "GET": return try get(req)
            case "POST": return try post(req)
            default: return .error("unsupported method", status: 501)
            }
        } catch let e as GitError {
            return .error("git: \(e)", status: 500)
        } catch {
            return .error("\(error)", status: 500)
        }
    }

    // MARK: - Request-origin guard
    //
    // The server is unauthenticated and loopback-only; these two checks keep
    // *other* things on the machine from driving it. The Host check defeats
    // DNS rebinding (a rebound page still sends the attacker's hostname); the
    // Origin check defeats cross-site requests (a browser always attaches
    // Origin to cross-origin fetches, and can't forge a loopback one). Absent
    // Origin => not a browser CSRF vector (e.g. curl, or a same-origin
    // top-level navigation), so it's allowed through.

    static func hostIsLoopback(_ host: String) -> Bool {
        let hostname: String
        if host.hasPrefix("[") {  // bracketed IPv6, e.g. [::1]:4633
            if let close = host.firstIndex(of: "]") {
                hostname = String(host[host.index(after: host.startIndex)..<close])
            } else {
                hostname = host
            }
        } else if let colon = host.lastIndex(of: ":") {
            hostname = String(host[..<colon])
        } else {
            hostname = host
        }
        return loopbackHosts.contains(hostname)
    }

    /// The origin's hostname: lowercased, without port or brackets.
    static func originHostname(_ origin: String) -> String? {
        guard let range = origin.range(of: "//") else { return nil }
        var rest = origin[range.upperBound...]
        if let slash = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            rest = rest[..<slash]
        }
        if let at = rest.lastIndex(of: "@") { rest = rest[rest.index(after: at)...] }
        var host: Substring
        if rest.hasPrefix("[") {
            guard let close = rest.firstIndex(of: "]") else { return nil }
            host = rest[rest.index(after: rest.startIndex)..<close]
        } else if let colon = rest.lastIndex(of: ":") {
            host = rest[..<colon]
        } else {
            host = rest
        }
        if host.isEmpty { return nil }
        return host.lowercased()
    }

    private func guardLocal(_ req: Request) -> Response? {
        if !Router.hostIsLoopback(req.headers["host"] ?? "") {
            return .error("forbidden: non-local Host header", status: 403)
        }
        if let origin = req.headers["origin"] {
            guard let hostname = Router.originHostname(origin), loopbackHosts.contains(hostname) else {
                return .error("forbidden: cross-origin request", status: 403)
            }
        }
        return nil
    }

    private func bodyJSON(_ req: Request) throws -> JSON {
        if req.body.count > 20 * 1024 * 1024 {
            throw ServerError("request too large")
        }
        return try JSON.parse(req.body)
    }

    // MARK: - Routes

    private func get(_ req: Request) throws -> Response {
        switch req.path {
        case "/": return serveStatic("index.html")
        case "/api/review": return try apiReview(req)
        case "/api/status": return try apiStatus(req)
        case "/api/file": return try apiFile(req)
        case "/api/revision": return try apiRevision(req, markdown: false)
        case "/api/revision-md": return try apiRevision(req, markdown: true)
        default: return serveStatic(String(req.path.dropFirst()))
        }
    }

    private func post(_ req: Request) throws -> Response {
        switch req.path {
        case "/api/drafts": return try apiDrafts(req)
        case "/api/submit": return try apiSubmit(req)
        case "/api/stage": return try apiStage(req)
        case "/api/viewed": return try apiViewed(req)
        case "/api/reset-history": return try apiResetHistory(req)
        default: return .error("not found", status: 404)
        }
    }

    private func serveStatic(_ name: String) -> Response {
        guard let body = uiFiles[name] else {
            return .error("not found", status: 404)
        }
        let ext = (name as NSString).pathExtension
        return Response(
            status: 200, contentType: contentTypes[ext] ?? "application/octet-stream",
            body: body
        )
    }

    /// --base as a commit: its merge-base with HEAD, so a branch name reviews
    /// what this branch changed (GitHub's `base...HEAD`).
    private func defaultBase() throws -> String {
        if let sha = try? Git.runText(repo, ["merge-base", cfg.base, "HEAD"]) {
            return sha.trimmed
        }
        guard let sha = Git.revParse(repo, cfg.base) else {
            throw GitError("unknown base ref '\(cfg.base)'")
        }
        return sha
    }

    /// The view a request asks for.
    struct ViewParams {
        var since: Int?
        var commit: String?
        var all = false

        init() {}

        /// From query parameters.
        init(_ req: Request) {
            since = Int(req.queryValue("since"))
            commit = req.queryValue("commit").isEmpty ? nil : req.queryValue("commit")
            all = !req.queryValue("all").isEmpty
        }

        /// From a submit payload's `view`: the client sends the same values
        /// it put in the query, as strings.
        init(_ view: JSON) {
            since = view["since"].intValue ?? view["since"].stringValue.flatMap { Int($0) }
            commit = view["commit"].stringValue.flatMap { $0.isEmpty ? nil : $0 }
            all = view["all"].isTrue || !(view["all"].stringValue ?? "").isEmpty
        }
    }

    /// `params` picks the view: since=N (review rN's snapshot -> working
    /// tree), commit=SHA (one commit vs its parent), or all=1 (the branch
    /// point -> working tree). Without any, --base -> working tree.
    private func collectView(
        _ params: ViewParams, revisions: [JSON], defaultBase: String, ignoreWs: Bool, raws: Raws? = nil
    ) throws -> ([DiffFile], View) {
        if let since = params.since {
            guard let rev = revisions.first(where: { $0["revision"].intValue == since }),
                  let tree = rev["tree"].stringValue, !tree.isEmpty
            else {
                throw ViewError("no snapshot for review r\(since)")
            }
            let files: [DiffFile]
            do {
                files = try Review.collectReviewSince(cfg, tree: tree, ignoreWs: ignoreWs)
            } catch let e as GitError {
                throw ViewError("snapshot for review r\(since) is unreadable (\(e))")
            }
            return (files, .since(revision: since))
        }
        if let commit = params.commit {
            guard Git.isSha(commit), let info = Review.commitInfo(cfg, commit) else {
                throw ViewError("no such commit \(commit)")
            }
            return (
                try Review.collectCommit(cfg, info.sha, ignoreWs: ignoreWs),
                .commit(sha: info.sha, short: info.short, subject: info.subject)
            )
        }
        var viewBase = defaultBase
        var sinceBranch: String?
        if params.all {
            guard let point = Review.branchPoint(cfg) else {
                throw ViewError("no default branch to diff against")
            }
            // On the default branch, that is just the default view.
            if point.sha != defaultBase {
                viewBase = point.sha
                sinceBranch = point.name
            }
        }
        var (files, _) = try Review.collectReview(
            cfg, base: viewBase, raws: viewBase == defaultBase ? raws : nil, ignoreWs: ignoreWs
        )
        // Staging works on the index, so its badges and hunk patches only
        // make sense when the diff is relative to HEAD.
        if viewBase != Git.revParse(repo, "HEAD") {
            for i in files.indices {
                files[i].stagedState = nil
                for h in files[i].hunks.indices {
                    files[i].hunks[h].staged = false
                }
            }
        }
        return (files, .base(base: viewBase, all: sinceBranch))
    }

    private func apiReview(_ req: Request) throws -> Response {
        let branch = try State.currentBranch(repo)
        let ignoreWs = req.queryValue("ws") == "1"
        let params = ViewParams(req)
        let revisions = stateLock.withLock {
            State.read(stateRoot, branch)["revisions"]?.arrayValue ?? []
        }
        let defaultBase = try defaultBase()
        let raws = try Review.gatherRaws(cfg, base: defaultBase, ignoreWs: ignoreWs)
        let files: [DiffFile]
        let view: View
        do {
            (files, view) = try collectView(
                params, revisions: revisions, defaultBase: defaultBase, ignoreWs: ignoreWs, raws: raws
            )
        } catch let e as ViewError {
            return .error("\(e)", status: 404)
        }
        var state: [String: JSON] = [:]
        var drafts: [JSON] = []
        try stateLock.withLock {
            state = State.read(stateRoot, branch)
            drafts = state["drafts"]?.arrayValue ?? []
            if try Drafts.reanchor(cfg, files: files, drafts: &drafts, view: view) {
                state["drafts"] = .array(drafts)
                try State.write(stateRoot, branch, state)
            }
        }
        // Viewed marks are per path in the working-tree views, and per
        // commit + path in a commit view.
        let viewedMap = state["viewed"]?.objectValue ?? [:]
        var filesJSON: [JSON] = []
        for f in files {
            var f = f
            let key: String
            if case .commit(let sha, _, _) = view {
                key = "\(sha):\(f.pathOrEmpty)"
            } else {
                key = f.pathOrEmpty
            }
            f.viewedKey = key
            f.viewed = viewedMap[key]?.stringValue == f.sig
            filesJSON.append(f.json)
        }
        let reviewedHead = revisions.reversed().first { $0["headSha"].stringValue != nil }?["headSha"].stringValue
        let pinned = Set(drafts.compactMap { Git.isSha($0["commit"]) ? $0["commit"].stringValue : nil })
        let point = Review.branchPoint(cfg)
        // "All changes" only means something off the default branch, and
        // when it isn't what the default view already shows.
        var allChanges: String?
        if let point, point.sha != Git.revParse(repo, "HEAD"), point.sha != defaultBase {
            allChanges = point.name
        }
        var fingerprint: JSON = .string(raws.fingerprint)
        if case .commit = view {
            fingerprint = .null  // A commit never changes, so nothing goes stale.
        }
        return .json(.object([
            "repo": .string(Paths.name(repo)),
            "branch": .string(branch),
            "base": .string(cfg.base),
            "view": view.json,
            "ignoreWhitespace": .bool(ignoreWs),
            "head": .string(raws.head),
            "fingerprint": fingerprint,
            "files": .array(filesJSON),
            "drafts": .array(drafts),
            "revisions": state["revisions"] ?? .array([]),
            "commits": .array(Review.listCommits(cfg, point: point?.sha, reviewedHead: reviewedHead)),
            "allChanges": allChanges.map { .string($0) } ?? .null,
            "lostCommits": .array(pinned.filter { !Git.isAncestor(repo, $0) }.sorted().map { .string($0) }),
        ]))
    }

    private func apiStatus(_ req: Request) throws -> Response {
        // Same ?ws= the review was fetched with, so fingerprints compare.
        let ignoreWs = req.queryValue("ws") == "1"
        let raws = try Review.gatherRaws(cfg, base: try defaultBase(), ignoreWs: ignoreWs)
        return .json(.object(["fingerprint": .string(raws.fingerprint), "head": .string(raws.head)]))
    }

    /// A file's lines in the working tree, or at ?rev= (a commit view).
    private func apiFile(_ req: Request) throws -> Response {
        let rel = req.queryValue("path")
        if rel.isEmpty {
            return .error("missing ?path=", status: 400)
        }
        let rev = req.queryValue("rev")
        if !rev.isEmpty, !Git.isSha(rev) {
            return .error("bad ?rev=", status: 400)
        }
        guard let data = try Review.fileBytes(cfg, rel: rel, rev: rev.isEmpty ? nil : rev) else {
            return .error("file missing or too large for context expansion", status: 404)
        }
        return .json(.object([
            "path": .string(rel),
            "lines": .array(Diff.splitLines(data).map { .string($0) }),
        ]))
    }

    private func apiRevision(_ req: Request, markdown: Bool) throws -> Response {
        guard let number = Int(req.queryValue("n")), number >= 0 else {
            return .error("missing ?n=", status: 400)
        }
        let branch = try State.currentBranch(repo)
        let p = Paths.join(Paths.join(State.branchDir(stateRoot, branch), "revisions"), "\(number).json")
        guard Paths.isFile(p) else {
            return .error("no such revision", status: 404)
        }
        let snap = try JSON.parse(try Paths.readData(p))
        if !markdown { return .json(snap) }
        return .json(.object(["markdown": .string(Markdown.render(snap))]))
    }

    private func apiDrafts(_ req: Request) throws -> Response {
        let payload = try bodyJSON(req)
        guard let drafts = payload["drafts"].arrayValue else {
            return .error("expected {drafts: [...]}", status: 400)
        }
        let branch = try State.currentBranch(repo)
        try stateLock.withLock {
            var state = State.read(stateRoot, branch)
            state["drafts"] = .array(drafts)
            try State.write(stateRoot, branch, state)
        }
        return .json(.object(["ok": .bool(true), "count": .int(drafts.count)]))
    }

    private func apiViewed(_ req: Request) throws -> Response {
        let payload = try bodyJSON(req)
        guard let path = payload["path"].stringValue, let sig = payload["sig"].stringValue,
              let viewed = payload["viewed"].boolValue
        else {
            return .error("expected {path, sig, viewed}", status: 400)
        }
        let branch = try State.currentBranch(repo)
        try stateLock.withLock {
            var state = State.read(stateRoot, branch)
            var viewedMap = state["viewed"]?.objectValue ?? [:]
            viewedMap[path] = viewed ? .string(sig) : nil
            state["viewed"] = .object(viewedMap)
            try State.write(stateRoot, branch, state)
        }
        return .json(.object(["ok": .bool(true)]))
    }

    private func apiResetHistory(_ req: Request) throws -> Response {
        let payload = try bodyJSON(req)
        guard let scope = payload["scope"].stringValue, scope == "branch" || scope == "all" else {
            return .error("expected {scope: \"branch\"|\"all\"}", status: 400)
        }
        let branch = try State.currentBranch(repo)
        let stats = try stateLock.withLock {
            try State.wipeHistory(stateRoot, branch, allBranches: scope == "all")
        }
        return .json(.object([
            "ok": .bool(true), "reviews": .int(stats.reviews), "branches": .int(stats.branches),
        ]))
    }

    private func apiSubmit(_ req: Request) throws -> Response {
        let payload = try bodyJSON(req)
        // An empty list is a valid review: it approves the changes.
        guard let comments = payload["comments"].arrayValue else {
            return .error("expected {comments: [...]}", status: 400)
        }
        let branch = try State.currentBranch(repo)
        let ignoreWs = payload["ignoreWs"].isTrue
        let viewParams = ViewParams(payload["view"])
        let defaultBase = try defaultBase()
        let revisions = stateLock.withLock {
            State.read(stateRoot, branch)["revisions"]?.arrayValue ?? []
        }
        // Freeze the diff the way the reviewer saw it, for the audit trail
        // (comments carry their own excerpts either way).
        var files: [DiffFile]
        var view: View
        do {
            (files, view) = try collectView(
                viewParams, revisions: revisions, defaultBase: defaultBase, ignoreWs: ignoreWs
            )
        } catch is ViewError {
            (files, view) = try collectView(
                ViewParams(), revisions: revisions, defaultBase: defaultBase, ignoreWs: ignoreWs
            )
        }
        // The checkpoint the next "since" view diffs against.
        let tree = try Review.snapshotTree(cfg)
        let headSha = Git.revParse(repo, "HEAD")
        let head = try Git.runText(repo, ["rev-parse", "--short", "HEAD"]).trimmed
        var commits: [String: JSON] = [:]
        for c in comments {
            guard Git.isSha(c["commit"]), let sha = c["commit"].stringValue, commits[sha] == nil else { continue }
            let info = Review.commitInfo(cfg, sha)
            commits[sha] = .object([
                "sha": .string(sha),
                "short": .string(info?.short ?? String(sha.prefix(7))),
                "subject": .string(info?.subject ?? ""),
                "time": .int(info?.time ?? 0),
                "gone": .bool(!Git.isAncestor(repo, sha)),
            ])
        }
        let submittedAt = State.nowISO()
        var revision = 0
        var revisionsOut: JSON = .array([])
        var markdown = ""
        try stateLock.withLock {
            var state = State.read(stateRoot, branch)
            let existing = state["revisions"]?.arrayValue ?? []
            revision = (existing.last?["revision"].intValue ?? 0) + 1
            let snapshot: JSON = .object([
                "revision": .int(revision),
                "branch": .string(branch),
                "base": .string(cfg.base),
                "baseSha": .string(defaultBase),
                "head": .string(head),
                "headSha": headSha.map { .string($0) } ?? .null,
                "submittedAt": .string(submittedAt),
                "view": view.json,
                "commits": .object(commits),
                "comments": .array(comments),
                "files": .array(files.map { $0.json }),
            ])
            try State.writeJSONAtomic(
                Paths.join(Paths.join(State.branchDir(stateRoot, branch), "revisions"), "\(revision).json"),
                snapshot
            )
            let entry: JSON = .object([
                "revision": .int(revision),
                "submittedAt": .string(submittedAt),
                "head": .string(head),
                "headSha": headSha.map { .string($0) } ?? .null,
                "tree": .string(tree),
                "commentCount": .int(comments.count),
            ])
            state["revisions"] = .array(existing + [entry])
            state["drafts"] = .array([])
            try State.write(stateRoot, branch, state)
            // The agent-facing handoff file: latest submitted review only,
            // self-describing markdown (see Markdown.render).
            markdown = Markdown.render(snapshot)
            try Paths.writeTextAtomic(Paths.join(stateRoot, "pending-review.md"), markdown)
            // Predecessor format; remove so no agent reads a stale review.
            Paths.unlink(Paths.join(stateRoot, "pending-review.json"))
            revisionsOut = state["revisions"] ?? .array([])
        }
        return .json(.object([
            "ok": .bool(true),
            "revision": .int(revision),
            "revisions": revisionsOut,
            "markdown": .string(markdown),
        ]))
    }

    /// Stage/unstage a whole file or a single hunk. Requires a writable
    /// .git; failures (e.g. read-only mounts) surface as error toasts.
    private func apiStage(_ req: Request) throws -> Response {
        let payload = try bodyJSON(req)
        let action = payload["action"].stringValue
        guard let rel = payload["path"].stringValue, !rel.isEmpty else {
            return .error("missing path", status: 400)
        }
        _ = try Review.safeRepoPath(repo, rel)  // traversal guard; git does the real work
        var paths = [rel]
        if let oldRel = payload["oldPath"].stringValue, !oldRel.isEmpty {
            _ = try Review.safeRepoPath(repo, oldRel)
            paths.append(oldRel)
        }
        switch action {
        case "stage-file":
            try Git.run(repo, ["add", "--"] + paths)
        case "unstage-file":
            try Git.run(repo, ["reset", "-q", "HEAD", "--"] + paths)
        case "stage-hunk", "unstage-hunk":
            guard let hunk = payload["hunk"].objectValue else {
                return .error("missing hunk", status: 400)
            }
            var args = ["apply", "--cached", "--whitespace=nowarn"]
            if action == "unstage-hunk" {
                args.append("--reverse")
            }
            args.append("-")
            try Git.run(repo, args, input: try Drafts.hunkPatch(path: rel, hunk: .object(hunk)))
        default:
            return .error("unknown action", status: 400)
        }
        return .json(.object(["ok": .bool(true)]))
    }
}
