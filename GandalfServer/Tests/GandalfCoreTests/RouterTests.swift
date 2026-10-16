import Foundation
import Testing
@testable import GandalfCore

@Suite struct RequestParsingTests {
    @Test func pathAndQuery() {
        let r = Request(method: "GET", uri: "/api/review?since=2&ws=1&empty=&a=x+y%2Fz&a=2#frag")
        #expect(r.path == "/api/review")
        #expect(r.queryValue("since") == "2")
        #expect(r.queryValue("ws") == "1")
        #expect(r.queryValue("empty") == "")
        #expect(r.queryValue("missing") == "")
        #expect(r.queryValue("a") == "x+y/z")
        #expect(Request(method: "GET", uri: "/").queryValue("x") == "")
        #expect(Request(method: "GET", uri: "/api/file?path=dir%20with%20space%2Fx.txt").queryValue("path") == "dir with space/x.txt")
    }

    @Test func hostAndOriginChecks() {
        #expect(Router.hostIsLoopback("127.0.0.1:4633"))
        #expect(Router.hostIsLoopback("localhost"))
        #expect(Router.hostIsLoopback("[::1]:4633"))
        #expect(!Router.hostIsLoopback("[::1"))
        #expect(!Router.hostIsLoopback("evil.example:4633"))
        #expect(!Router.hostIsLoopback(""))
        #expect(Router.originHostname("http://localhost:4633") == "localhost")
        #expect(Router.originHostname("http://LOCALHOST") == "localhost")
        #expect(Router.originHostname("http://[::1]:1/x") == "::1")
        #expect(Router.originHostname("http://u:p@127.0.0.1:1") == "127.0.0.1")
        #expect(Router.originHostname("null") == nil)
        #expect(Router.originHostname("http://") == nil)
    }
}

@Suite struct RouterTests {
    /// A repo with one commit, a staged + unstaged edit, a deletion, a rename,
    /// a binary change and an untracked file.
    static let original = """
        import Foundation

        func greet() {
            print("hi")
        }

        func a() {}
        func b() {}
        func c() {}
        func d() {}
        func e() {}
        func f() {}

        func other() {}

        """
    static let stagedEdit = original.replacingOccurrences(of: "print(\"hi\")", with: "print(\"hello\")")
    static let bothEdits = stagedEdit.replacingOccurrences(of: "func other() {}", with: "func other() { /* x */ }")

    func makeRepo() throws -> (FixtureRepo, Router) {
        let repo = try FixtureRepo()
        try repo.write("src/main.swift", Self.original)
        try repo.write("docs/gone.txt", "gone\n")
        try repo.write("docs/old.txt", "1\n2\n3\n4\n5\n")
        try repo.write("img.bin", "\u{0}bin")
        try repo.write(".gitignore", ".gandalf/\npublic/\n")
        _ = try repo.commit("Initial")
        try repo.write("src/main.swift", Self.stagedEdit)
        try repo.git(["add", "src/main.swift"])
        try repo.write("src/main.swift", Self.bothEdits)
        try repo.git(["rm", "-q", "docs/gone.txt"])
        try repo.git(["mv", "docs/old.txt", "docs/new.txt"])
        try repo.write("img.bin", "\u{0}bin2")
        try repo.write("untracked.txt", "u1\nu2\n")
        try repo.write("public/index.html", "<html></html>")
        try repo.write("public/app.js", "// js")
        try repo.write("public/secret.txt", "no")
        return (repo, Router(repo.config()))
    }

    @Test func guardsNonLocalRequests() throws {
        let (repo, router) = try makeRepo()
        defer { withExtendedLifetime(repo) {} }
        let host = router.handle(Request(method: "GET", uri: "/api/status", headers: ["host": "evil:1"]))
        #expect(host.status == 403 && host.text == #"{"error":"forbidden: non-local Host header"}"#)
        let origin = router.get("/api/status", headers: ["origin": "http://evil"])
        #expect(origin.status == 403 && origin.text == #"{"error":"forbidden: cross-origin request"}"#)
        #expect(router.get("/api/status", headers: ["origin": "http://127.0.0.1:1"]).status == 200)
        #expect(router.handle(Request(method: "PUT", uri: "/api/status", headers: ["host": "localhost"])).status == 501)
    }

    @Test func servesStaticWhitelistOnly() throws {
        let (repo, router) = try makeRepo()
        defer { withExtendedLifetime(repo) {} }
        let index = router.get("/")
        #expect(index.status == 200 && index.contentType == "text/html; charset=utf-8" && index.text == "<html></html>")
        #expect(router.get("/app.js").contentType == "text/javascript; charset=utf-8")
        #expect(router.get("/style.css").status == 404)  // not present in this fixture
        #expect(router.get("/secret.txt").status == 404)
        #expect(router.get("/nope").text == #"{"error":"not found"}"#)
        #expect(router.get("/api/nope").status == 404)
    }

    @Test func servesStaticThroughASymlinkedDirectory() throws {
        let repo = try FixtureRepo()
        try repo.write("a.txt", "a\n")
        _ = try repo.commit("one")
        let tmp = try TempDir()
        try tmp.write("real/public/index.html", "<p>linked</p>")
        try FileManager.default.createSymbolicLink(
            atPath: Paths.join(tmp.path, "link"), withDestinationPath: "real"
        )
        let router = Router(repo.config(publicDir: Paths.join(tmp.path, "link/public")))
        let index = router.get("/")
        #expect(index.status == 200 && index.text == "<p>linked</p>")
        #expect(router.get("/style.css").status == 404)
    }

    @Test func reviewPayloadShape() throws {
        let (repo, router) = try makeRepo()
        defer { withExtendedLifetime(repo) {} }
        let r = router.get("/api/review")
        #expect(r.status == 200)
        let o = try #require(r.json.objectValue)
        #expect(o.keys.sorted() == [
            "allChanges", "base", "branch", "commits", "drafts", "files", "fingerprint", "head",
            "ignoreWhitespace", "lostCommits", "repo", "revisions", "view",
        ])
        #expect(o["branch"] == .string("main"))
        #expect(o["view"]?["kind"] == .string("base"))
        #expect(o["allChanges"] == .null)  // on the default branch
        #expect(o["commits"] == .array([]))  // nothing beyond the branch point
        let files = o["files"]!.arrayValue!
        #expect(files.map { $0["path"].stringValue! } == ["docs/gone.txt", "docs/new.txt", "img.bin", "src/main.swift", "untracked.txt"])
        let byPath = Dictionary(uniqueKeysWithValues: files.map { ($0["path"].stringValue!, $0) })
        #expect(byPath["docs/gone.txt"]?["status"] == .string("deleted"))
        #expect(byPath["docs/gone.txt"]?["stagedState"] == .string("full"))
        #expect(byPath["docs/new.txt"]?["status"] == .string("renamed"))
        #expect(byPath["docs/new.txt"]?["oldPath"] == .string("docs/old.txt"))
        #expect(byPath["img.bin"]?["binary"] == .bool(true))
        #expect(byPath["src/main.swift"]?["stagedState"] == .string("partial"))
        #expect(byPath["src/main.swift"]?["newTotal"] == .int(14))
        #expect(byPath["untracked.txt"]?["untracked"] == .bool(true))
        #expect(byPath["untracked.txt"]?["stagedState"] == .string("none"))
        let hunks = byPath["src/main.swift"]!["hunks"].arrayValue!
        #expect(hunks.count == 2)
        #expect(hunks[0]["staged"] == .bool(true) && hunks[1]["staged"] == .bool(false))
        #expect(byPath["src/main.swift"]?["viewed"] == .bool(false))
        #expect(byPath["src/main.swift"]?["viewedKey"] == .string("src/main.swift"))

        let status = router.get("/api/status").json
        #expect(status["fingerprint"] == o["fingerprint"])
        #expect(status["head"] == o["head"])
    }

    @Test func whitespaceModeAndFileEndpoint() throws {
        let (repo, router) = try makeRepo()
        defer { withExtendedLifetime(repo) {} }
        try repo.write("ws.txt", "a\n")
        _ = try repo.commit("ws")
        try repo.write("ws.txt", "a  \n")
        let plain = router.get("/api/review").json
        #expect(plain["files"].arrayValue!.contains { $0["path"] == .string("ws.txt") })
        let ws = router.get("/api/review?ws=1").json
        #expect(!ws["files"].arrayValue!.contains { $0["path"] == .string("ws.txt") })
        #expect(ws["ignoreWhitespace"] == .bool(true))
        #expect(ws["fingerprint"] != plain["fingerprint"])

        let file = router.get("/api/file?path=src%2Fmain.swift").json
        #expect(file["lines"].arrayValue?.count == 14)
        #expect(router.get("/api/file").text == #"{"error":"missing ?path="}"#)
        #expect(router.get("/api/file?path=missing.txt").status == 404)
        #expect(router.get("/api/file?path=../x").status == 500)
        #expect(router.get("/api/file?path=src/main.swift&rev=zz").status == 400)
        let initial = try repo.git(["rev-parse", "HEAD~1"]).trimmed
        let atInitial = router.get("/api/file?path=src/main.swift&rev=\(initial)").json
        #expect(atInitial["lines"].arrayValue?[3] == .string("    print(\"hi\")"))
    }

    @Test func draftsViewedAndReanchoring() throws {
        let (repo, router) = try makeRepo()
        defer { withExtendedLifetime(repo) {} }
        let drafts = try JSON.parse(#"""
        [{"id": "d1", "file": "src/main.swift", "side": "new", "startLine": 4, "endLine": 4,
          "excerpt": ["+    print(\"hello\")"], "text": "say hi"},
         {"id": "d2", "file": "src/main.swift", "side": "new", "startLine": 1, "endLine": 1,
          "excerpt": [" nope"], "text": "detached"}]
        """#)
        let body: [String: JSON] = ["drafts": drafts]
        let saved = router.post("/api/drafts", .object(body))
        #expect(saved.text == #"{"count":2,"ok":true}"#)
        #expect(router.post("/api/drafts", .object(["drafts": .string("x")])).status == 400)

        // Insert a line above: the first draft follows, the second detaches.
        try repo.write("src/main.swift", "// new\n" + Self.bothEdits)
        let r = router.get("/api/review").json
        let d = r["drafts"].arrayValue!
        #expect(d[0]["startLine"] == .int(5) && d[0]["detached"] == .bool(false))
        #expect(d[1]["detached"] == .bool(true))
        // ...and the moved anchor was persisted.
        let state = State.read(router.cfg.stateRoot, "main")
        #expect(state["drafts"]?.arrayValue?[0]["startLine"] == .int(5))

        let file = r["files"].arrayValue!.first { $0["path"] == .string("src/main.swift") }!
        let viewed: [String: JSON] = ["path": .string("src/main.swift"), "sig": file["sig"], "viewed": .bool(true)]
        #expect(router.post("/api/viewed", .object(viewed)).text == #"{"ok":true}"#)
        let again = router.get("/api/review").json["files"].arrayValue!.first { $0["path"] == .string("src/main.swift") }!
        #expect(again["viewed"] == .bool(true))
        // Any change to the file clears the mark.
        try repo.write("src/main.swift", "// changed\nimport Foundation\n")
        let cleared = router.get("/api/review").json["files"].arrayValue!.first { $0["path"] == .string("src/main.swift") }!
        #expect(cleared["viewed"] == .bool(false))
        #expect(router.post("/api/viewed", .object(["path": .int(1)])).status == 400)
    }

    @Test func submitSinceAndWipe() throws {
        let (repo, router) = try makeRepo()
        defer { withExtendedLifetime(repo) {} }
        let comments = try JSON.parse(#"""
        [{"id": "c1", "file": "src/main.swift", "side": "new", "startLine": 4, "endLine": 4,
          "excerpt": ["+    print(\"hello\")"], "text": "say hi"},
         {"id": "o", "reviewLevel": true, "file": null, "text": "overall"}]
        """#)
        let body: [String: JSON] = ["comments": comments, "view": .object([:])]
        let sub = router.post("/api/submit", .object(body)).json
        #expect(sub["ok"] == .bool(true) && sub["revision"] == .int(1))
        let md = sub["markdown"].stringValue!
        #expect(md.hasPrefix("# Code review — please address each comment\n"))
        #expect(md.contains("## Overall\n\noverall\n") && md.contains("## src/main.swift\n\n**Line 4**\n\n> +    print(\"hello\")\n\nsay hi\n"))
        #expect(try Paths.readText(Paths.join(router.cfg.stateRoot, "pending-review.md")) == md)
        let revs = sub["revisions"].arrayValue!
        #expect(revs.count == 1 && revs[0]["commentCount"] == .int(2) && revs[0]["tree"].stringValue?.count == 40)

        // Drafts were consumed; the since view is empty until something changes.
        let after = router.get("/api/review").json
        #expect(after["drafts"] == .array([]))
        let since = router.get("/api/review?since=1").json
        #expect(since["view"]["kind"] == .string("since") && since["view"]["since"] == .int(1))
        #expect(router.get("/api/review?since=01").status == 200)
        #expect(since["files"] == .array([]))
        try repo.write("untracked.txt", "u1\nu2\nu3\n")
        let sinceChanged = router.get("/api/review?since=1").json["files"].arrayValue!
        #expect(sinceChanged.map { $0["path"].stringValue! } == ["untracked.txt"])
        #expect(sinceChanged[0]["additions"] == .int(1))
        #expect(sinceChanged[0]["stagedState"] == .null)
        #expect(router.get("/api/review?since=2").text == #"{"error":"no snapshot for review r2"}"#)

        #expect(router.get("/api/revision?n=1").json["comments"] == comments)
        #expect(router.get("/api/revision-md?n=1").json["markdown"] == .string(md))
        #expect(router.get("/api/revision?n=x").status == 400)
        #expect(router.get("/api/revision?n=5").status == 404)

        // An empty review is an approval and still checkpoints.
        let empty: [String: JSON] = ["comments": .array([]), "view": .object(["since": .string("1")])]
        let approval = router.post("/api/submit", .object(empty)).json
        #expect(approval["revision"] == .int(2))
        #expect(approval["markdown"].stringValue!.hasPrefix("# Code review — approved"))
        #expect(router.get("/api/revision?n=2").json["view"]["kind"] == .string("since"))

        let wipe = router.post("/api/reset-history", .object(["scope": .string("branch")])).json
        #expect(wipe == .object(["ok": .bool(true), "reviews": .int(2), "branches": .int(1)]))
        #expect(router.get("/api/review?since=1").status == 404)
        #expect(!Paths.exists(Paths.join(router.cfg.stateRoot, "pending-review.md")))
        #expect(router.post("/api/reset-history", .object(["scope": .string("nope")])).status == 400)
    }

    @Test func commitViewsAndPinnedComments() throws {
        let (repo, router) = try makeRepo()
        defer { withExtendedLifetime(repo) {} }
        try repo.git(["checkout", "-q", "-b", "feature"])
        try repo.write("feature.txt", "f1\n")
        let sha = try repo.commit("Add feature", paths: ["feature.txt"])
        let r = router.get("/api/review").json
        #expect(r["allChanges"] == .string("main"))
        let commits = r["commits"].arrayValue!
        #expect(commits.count == 1 && commits[0]["sha"] == .string(sha) && commits[0]["subject"] == .string("Add feature"))

        let view = router.get("/api/review?commit=\(sha)").json
        #expect(view["view"]["kind"] == .string("commit") && view["fingerprint"] == .null)
        let files = view["files"].arrayValue!
        #expect(files.map { $0["path"].stringValue! } == ["feature.txt"])
        #expect(files[0]["viewedKey"] == .string("\(sha):feature.txt"))
        #expect(files[0]["stagedState"] == .null)
        #expect(router.get("/api/review?commit=\(String(sha.prefix(7)))").status == 200)
        #expect(router.get("/api/review?commit=zz").text == #"{"error":"no such commit zz"}"#)
        #expect(router.get("/api/review?commit=abcdef").status == 404)

        let all = router.get("/api/review?all=1").json
        #expect(all["view"]["all"] == .string("main"))
        #expect(all["files"].arrayValue!.contains { $0["path"] == .string("feature.txt") })
        #expect(all["files"].arrayValue!.allSatisfy { $0["stagedState"] == .null })

        // A comment pinned to a lost commit shows up in lostCommits.
        let drafts = try JSON.parse(#"""
        [{"id": "p", "file": "feature.txt", "side": "new", "startLine": 1, "endLine": 1, "excerpt": ["+f1"],
          "text": "pinned", "commit": "\#(sha)"},
         {"id": "l", "file": "x", "fileLevel": true, "text": "lost", "commit": "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"}]
        """#)
        _ = router.post("/api/drafts", .object(["drafts": drafts]))
        let withLost = router.get("/api/review").json
        #expect(withLost["lostCommits"] == .array([.string("deadbeefdeadbeefdeadbeefdeadbeefdeadbeef")]))

        let body: [String: JSON] = ["comments": drafts, "view": .object(["commit": .string(sha)])]
        let md = router.post("/api/submit", .object(body)).json["markdown"].stringValue!
        #expect(md.contains("## Commit `\(sha.prefix(7))` — Add feature\n\n### feature.txt\n"))
        #expect(md.contains("## Commit `deadbee` (no longer in history)\n"))
        #expect(router.get("/api/revision?n=1").json["view"]["commit"] == .string(sha))
    }

    @Test func stagingRoundTrip() throws {
        let (repo, router) = try makeRepo()
        defer { withExtendedLifetime(repo) {} }
        let before = router.get("/api/review").json["files"].arrayValue!.first { $0["path"] == .string("src/main.swift") }!
        let unstagedHunk = before["hunks"].arrayValue![1]
        var stage: [String: JSON] = ["action": .string("stage-hunk"), "path": .string("src/main.swift"), "hunk": unstagedHunk]
        #expect(router.post("/api/stage", .object(stage)).text == #"{"ok":true}"#)
        let staged = router.get("/api/review").json["files"].arrayValue!.first { $0["path"] == .string("src/main.swift") }!
        #expect(staged["stagedState"] == .string("full"))
        stage["action"] = .string("unstage-hunk")
        #expect(router.post("/api/stage", .object(stage)).status == 200)
        let partial = router.get("/api/review").json["files"].arrayValue!.first { $0["path"] == .string("src/main.swift") }!
        #expect(partial["stagedState"] == .string("partial"))

        var file: [String: JSON] = ["action": .string("unstage-file"), "path": .string("src/main.swift")]
        #expect(router.post("/api/stage", .object(file)).status == 200)
        let none = router.get("/api/review").json["files"].arrayValue!.first { $0["path"] == .string("src/main.swift") }!
        #expect(none["stagedState"] == .string("none"))
        file["action"] = .string("stage-file")
        #expect(router.post("/api/stage", .object(file)).status == 200)

        #expect(router.post("/api/stage", .object(["action": .string("stage-file")])).text == #"{"error":"missing path"}"#)
        #expect(router.post("/api/stage", .object(["action": .string("stage-file"), "path": .string("../x")])).text == #"{"error":"path outside repository"}"#)
        #expect(router.post("/api/stage", .object(["action": .string("zap"), "path": .string("x")])).text == #"{"error":"unknown action"}"#)
        #expect(router.post("/api/stage", .object(["action": .string("stage-hunk"), "path": .string("x")])).text == #"{"error":"missing hunk"}"#)
    }

    @Test func gitFailuresSurfaceAsErrors() throws {
        let repo = try FixtureRepo()  // no commits yet
        try repo.write("x.txt", "x\n")
        let router = Router(repo.config())
        let r = router.get("/api/review")
        #expect(r.status == 500)
        #expect(r.json["error"].stringValue!.hasPrefix("git: "))
        let bad = Router(repo.config(base: "nosuchref"))
        _ = try repo.commit("one")
        #expect(bad.get("/api/review").text == #"{"error":"git: unknown base ref 'nosuchref'"}"#)
        let badBody = router.handle(Request(method: "POST", uri: "/api/drafts", headers: ["host": "localhost"], body: Data("nope".utf8)))
        #expect(badBody.text == #"{"error":"invalid JSON: expected a value at offset 0"}"#)
    }

    @Test func detachedHeadBranchName() throws {
        let (repo, router) = try makeRepo()
        defer { withExtendedLifetime(repo) {} }
        let sha = try repo.git(["rev-parse", "--short", "HEAD"]).trimmed
        try repo.git(["checkout", "-q", "--detach"])
        #expect(router.get("/api/review").json["branch"] == .string("detached-\(sha)"))
    }

    @Test func stateDirInsideRepoIsExcluded() throws {
        let repo = try FixtureRepo()
        try repo.write("a.txt", "a\n")
        _ = try repo.commit("one")
        let stateRoot = Paths.join(Paths.resolve(repo.path), "custom/state")
        let cfg = ReviewConfig(repo: Paths.resolve(repo.path), base: "HEAD", stateRoot: stateRoot, publicDir: repo.path)
        #expect(cfg.excludes == [":(exclude).gandalf", ":(exclude)custom/state"])
        #expect(cfg.skipPrefixes == ["custom/state"])
        #expect(cfg.statePaths == [".gandalf", "custom/state"])
        let router = Router(cfg)
        _ = router.post("/api/drafts", .object(["drafts": .array([])]))
        #expect(Paths.exists(Paths.join(stateRoot, "branches/main/state.json")))
        #expect(router.get("/api/review").json["files"] == .array([]))
        let outside = ReviewConfig(repo: Paths.resolve(repo.path), base: "HEAD", stateRoot: "/tmp/elsewhere", publicDir: repo.path)
        #expect(outside.excludes == [":(exclude).gandalf"] && outside.skipPrefixes.isEmpty)
    }
}

@Suite struct AppTests {
    @Test func configureFindsRepoFromOptions() throws {
        let repo = try FixtureRepo()
        try repo.write("a.txt", "a\n")
        _ = try repo.commit("one")
        var options = Options()
        options.repo = repo.path
        options.base = "main"
        let cfg = try App.configure(options, publicDir: "/tmp/public")
        #expect(cfg.repo == Paths.resolve(repo.path))
        #expect(cfg.base == "main")
        #expect(cfg.stateRoot == Paths.join(Paths.resolve(repo.path), ".gandalf"))
        options.stateDir = Paths.join(repo.path, "custom")
        #expect(try App.configure(options, publicDir: "/tmp/public").skipPrefixes == ["custom"])
        options.repo = Paths.join(repo.path, "nope")
        #expect(throws: ExitError.self) { try App.configure(options, publicDir: "/tmp/public") }
    }
}
