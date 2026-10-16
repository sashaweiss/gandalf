import Crypto
import Foundation

/// The raw git output behind the default view, plus the staleness fingerprint.
public struct Raws: Sendable {
    public var raw: String
    public var cachedRaw: String
    public var unstagedNames: Set<String>
    public var untracked: [String]
    public var head: String
    public var fingerprint: String
}

/// What the server reviews: the repository, its base ref, and where state
/// lives. Everything that was module-level configuration in the Python
/// server hangs off this.
public struct ReviewConfig: Sendable {
    public var repo: String
    public var base: String
    public var stateRoot: String
    /// `:(exclude)` pathspecs keeping gandalf's own state out of the diff.
    public var excludes: [String]
    /// Repo-relative prefixes of untracked files to skip.
    public var skipPrefixes: [String]
    public var publicDir: String

    public init(repo: String, base: String, stateRoot: String, publicDir: String) {
        self.repo = repo
        self.base = base
        self.stateRoot = stateRoot
        // Resolved so the static-file guard compares like with like (macOS
        // temp dirs, for one, sit behind a symlink).
        self.publicDir = Paths.resolve(publicDir)
        // Keep the state directory itself out of the review: exclude it from
        // the diff / untracked scan when it lives inside the reviewed repo.
        excludes = [":(exclude)\(stateDirName)"]
        skipPrefixes = []
        if Paths.isInside(stateRoot, root: repo) {
            let rel = stateRoot == repo
                ? "." : String(stateRoot.dropFirst(repo.count + (repo.hasSuffix("/") ? 0 : 1)))
            if rel != "." && rel != stateDirName {
                excludes.append(":(exclude)\(rel)")
                skipPrefixes.append(rel)
            }
        }
    }

    /// gandalf's own state, as repo-relative paths kept out of snapshots.
    public var statePaths: [String] { [stateDirName] + skipPrefixes }
}

public enum Review {
    /// Run the (read-only) git commands once and derive a change fingerprint.
    /// The fingerprint is view-scoped: with ignoreWs, whitespace-only edits
    /// neither show nor count as staleness — the rendered view is unchanged.
    public static func gatherRaws(_ cfg: ReviewConfig, base: String, ignoreWs: Bool) throws -> Raws {
        let repo = cfg.repo
        let ws = ignoreWs ? ["-w"] : []
        let raw = try Git.runText(
            repo, ["diff", "--no-color", "--find-renames", "-U3"] + ws + [base, "--", "."] + cfg.excludes
        )
        let cachedRaw = try Git.runText(
            repo, ["diff", "--cached", "--no-color", "--find-renames"] + ws + [base, "--", "."] + cfg.excludes
        )
        let unstagedNames = Set(
            try Git.run(repo, ["diff", "--name-only", "-z"]).decodedLossy
                .split(separator: "\0").map(String.init)
        )
        let untracked = try Git.run(repo, ["ls-files", "--others", "--exclude-standard", "-z"])
            .decodedLossy.split(separator: "\0").map(String.init)
            .filter { !Diff.skipUntracked($0, skipPrefixes: cfg.skipPrefixes) }
        let head = try Git.runText(repo, ["rev-parse", "--short", "HEAD"]).trimmed
        var fp = SHA256()
        for part in [raw, untracked.joined(separator: "\0"), cachedRaw, head] {
            fp.update(data: Data(part.utf8))
            fp.update(data: Data([0]))
        }
        return Raws(
            raw: raw, cachedRaw: cachedRaw, unstagedNames: unstagedNames,
            untracked: untracked, head: head,
            fingerprint: String(fp.finalize().hexString.prefix(16))
        )
    }

    public static func collectReview(
        _ cfg: ReviewConfig, base: String, raws: Raws? = nil, ignoreWs: Bool
    ) throws -> ([DiffFile], Raws) {
        let raws = try raws ?? gatherRaws(cfg, base: base, ignoreWs: ignoreWs)
        var files = Diff.parseUnifiedDiff(raws.raw)
        for rel in raws.untracked {
            if let f = Diff.synthesizeUntracked(repo: cfg.repo, rel: rel) {
                files.append(f)
            }
        }

        // Staged state: which files/hunks are already in the index.
        let cachedFiles = Diff.parseUnifiedDiff(raws.cachedRaw)
        var cachedNames = Set<String>()
        var cachedSigs: [String?: Set<String>] = [:]
        for cf in cachedFiles {
            for name in [cf.path, cf.oldPath] {
                if let name { cachedNames.insert(name) }
            }
            var sigs = cachedSigs[cf.path] ?? []
            for h in cf.hunks { sigs.insert(h.signature) }
            cachedSigs[cf.path] = sigs
        }
        for idx in files.indices {
            if files[idx].untracked {
                files[idx].stagedState = "none"
                continue
            }
            let names = Set([files[idx].path, files[idx].oldPath].compactMap { $0 })
            let inCached = !names.isDisjoint(with: cachedNames)
            let inUnstaged = !names.isDisjoint(with: raws.unstagedNames)
            files[idx].stagedState = inCached && !inUnstaged ? "full" : (inCached ? "partial" : "none")
            var sigs = Set<String>()
            for n in names { sigs.formUnion(cachedSigs[n] ?? []) }
            for h in files[idx].hunks.indices {
                files[idx].hunks[h].staged = sigs.contains(files[idx].hunks[h].signature)
            }
        }

        finalizeFiles(cfg, &files)
        return (files, raws)
    }

    /// A file's contents in the working tree (rev nil) or at a commit; nil
    /// when it doesn't exist there or is over maxFileBytes.
    public static func fileBytes(_ cfg: ReviewConfig, rel: String, rev: String? = nil) throws -> Data? {
        guard let rev else {
            let p = try safeRepoPath(cfg.repo, rel)
            guard Paths.isFile(p), let st = Paths.fileStat(p), st.size <= maxFileBytes else { return nil }
            return try Paths.readData(p)
        }
        let spec = "\(rev):\(rel)"
        guard let sizeText = try? Git.runText(cfg.repo, ["cat-file", "-s", spec]),
              let size = Int(sizeText.trimmed), size <= maxFileBytes,
              let data = try? Git.run(cfg.repo, ["cat-file", "blob", spec])
        else { return nil }
        return data
    }

    /// `rev` names the commit a commit view's new side comes from; nil means
    /// the working tree.
    public static func finalizeFiles(_ cfg: ReviewConfig, _ files: inout [DiffFile], rev: String? = nil) {
        // Per-file content signature, used to persist "viewed" checkmarks: a
        // file stays viewed only while its diff is byte-identical to when it
        // was marked. Binary diffs carry no hunk content, so fall back to
        // size + mtime there (a commit never changes, so its sha is enough).
        for idx in files.indices {
            let f = files[idx]
            var h = Insecure.SHA1()
            for part in [f.status, f.path ?? "", f.oldPath ?? ""] {
                h.update(data: Data(part.utf8))
                h.update(data: Data([0]))
            }
            for hk in f.hunks { h.update(data: Data(hk.signature.utf8)) }
            if f.binary, let rev {
                h.update(data: Data(rev.utf8))
            } else if f.binary {
                if let st = Paths.fileStat(Paths.join(cfg.repo, f.path ?? "")) {
                    h.update(data: Data("\(st.size):\(st.mtimeNs)".utf8))
                }
            }
            files[idx].sig = String(h.finalize().hexString.prefix(16))
        }

        // Total line count of the new-side file, needed for "expand down"
        // past the last hunk. Deleted/binary files have nothing to expand into.
        for idx in files.indices {
            let f = files[idx]
            if f.status == "deleted" || f.binary || f.newTotal != nil { continue }
            let data = try? fileBytes(cfg, rel: f.path ?? "", rev: rev)
            if let data {
                files[idx].newTotal = Diff.countLines(data)
            }
        }
        files.sort { $0.pathOrEmpty < $1.pathOrEmpty }
    }

    // MARK: - Review snapshots & the other views
    //
    // Finishing a review snapshots the whole working tree as a git tree
    // object. The objects go to a private store (<state>/objects) that
    // borrows the repo's own objects as an alternate: only uncommitted
    // content is stored, and .git is never written to. "Since review rN" is
    // then a plain tree-to-tree `git diff`, unaffected by commits, rebases or
    // a moving base.

    public static func snapshotEnv(_ cfg: ReviewConfig) throws -> [String: String] {
        let objects = Paths.join(cfg.stateRoot, "objects")
        try Paths.mkdirs(objects)
        let repoObjects = try Git.runText(cfg.repo, ["rev-parse", "--git-path", "objects"]).trimmed
        return [
            "GIT_OBJECT_DIRECTORY": objects,
            "GIT_ALTERNATE_OBJECT_DIRECTORIES": Paths.resolve(Paths.join(cfg.repo, repoObjects)),
        ]
    }

    /// Tree object for the working tree as it is now (tracked + untracked,
    /// minus ignored files and gandalf's own state at `statePaths`).
    public static func snapshotTree(_ cfg: ReviewConfig) throws -> String {
        var env = try snapshotEnv(cfg)
        let td = try Paths.temporaryDirectory(prefix: "gandalf-index-")
        defer { Paths.removeTree(td) }
        env["GIT_INDEX_FILE"] = Paths.join(td, "index")
        // Starting from a copy of the repo's index lets `add` trust its stat
        // cache and hash only what changed.
        let real = Paths.join(
            cfg.repo, try Git.runText(cfg.repo, ["rev-parse", "--git-path", "index"]).trimmed
        )
        if Paths.isFile(real) {
            try Paths.readData(real).write(to: URL(fileURLWithPath: env["GIT_INDEX_FILE"]!))
        } else {
            try Git.run(cfg.repo, ["read-tree", "HEAD"], env: env)
        }
        // Not an exclude pathspec: `add` rejects one naming an ignored path,
        // and the state dir is usually gitignored.
        try Git.run(cfg.repo, ["add", "-A"], env: env)
        try Git.run(
            cfg.repo, ["rm", "-r", "-q", "--cached", "--ignore-unmatch", "--"] + cfg.statePaths, env: env
        )
        return try Git.runText(cfg.repo, ["write-tree"], env: env).trimmed
    }

    public static func diffRevs(
        _ cfg: ReviewConfig, _ a: String, _ b: String, ignoreWs: Bool, env: [String: String]? = nil
    ) throws -> [DiffFile] {
        let ws = ignoreWs ? ["-w"] : []
        let raw = try Git.runText(
            cfg.repo, ["diff", "--no-color", "--find-renames", "-U3"] + ws + [a, b, "--"], env: env
        )
        return Diff.parseUnifiedDiff(raw)
    }

    /// What changed between review snapshot `tree` and the working tree.
    public static func collectReviewSince(_ cfg: ReviewConfig, tree: String, ignoreWs: Bool) throws -> [DiffFile] {
        let now = try snapshotTree(cfg)
        var files = try diffRevs(cfg, tree, now, ignoreWs: ignoreWs, env: try snapshotEnv(cfg))
        finalizeFiles(cfg, &files)
        return files
    }

    /// First parent, or the empty tree for a root commit.
    public static func commitParent(_ cfg: ReviewConfig, _ sha: String) throws -> String {
        if let parent = Git.revParse(cfg.repo, "\(sha)^") { return parent }
        return try Git.runText(cfg.repo, ["hash-object", "-t", "tree", "--stdin"]).trimmed
    }

    public static func collectCommit(_ cfg: ReviewConfig, _ sha: String, ignoreWs: Bool) throws -> [DiffFile] {
        var files = try diffRevs(cfg, try commitParent(cfg, sha), sha, ignoreWs: ignoreWs)
        finalizeFiles(cfg, &files, rev: sha)
        return files
    }

    public struct CommitInfo: Sendable {
        public var sha: String
        public var short: String
        public var subject: String
        public var time: Int
    }

    /// {sha, short, subject, time} for a commit object, or nil.
    public static func commitInfo(_ cfg: ReviewConfig, _ sha: String) -> CommitInfo? {
        guard let out = try? Git.runText(cfg.repo, ["log", "-1", "--format=%H%x00%s%x00%ct", sha, "--"])
        else { return nil }
        let parts = out.trimmingTrailingWhitespace.split(separator: "\0", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return nil }
        let full = String(parts[0])
        return CommitInfo(sha: full, short: String(full.prefix(7)), subject: String(parts[1]), time: Int(parts[2]) ?? 0)
    }

    /// (sha, name): HEAD's merge-base with the default branch (HEAD itself
    /// when on it) and that branch's short name; nil when there is no
    /// default branch to compare with.
    public static func branchPoint(_ cfg: ReviewConfig) -> (sha: String, name: String)? {
        for ref in ["refs/remotes/origin/HEAD", "refs/heads/main", "refs/heads/master"] {
            guard let tip = Git.revParse(cfg.repo, ref) else { continue }
            guard let sha = try? Git.runText(cfg.repo, ["merge-base", tip, "HEAD"]).trimmed,
                  let name = try? Git.runText(cfg.repo, ["rev-parse", "--abbrev-ref", ref]).trimmed
            else { return nil }
            return (sha, name)
        }
        return nil
    }

    /// The commits on HEAD's branch: first-parent history back to, but not
    /// including, branch point `point`, newest first. Without a branch
    /// point, just the most recent commits. `new` marks commits made since
    /// `reviewedHead`.
    public static func listCommits(
        _ cfg: ReviewConfig, point: String?, reviewedHead: String?, limit: Int = 100
    ) -> [JSON] {
        guard let out = try? Git.runText(cfg.repo, [
            "log", "--first-parent", "-n\(limit)", "--format=%H%x00%s",
            point.map { "\($0)..HEAD" } ?? "HEAD", "--",
        ]) else { return [] }  // unborn branch
        var new = Set<String>()
        if let reviewedHead,
           let text = try? Git.runText(cfg.repo, ["rev-list", "HEAD", "^\(reviewedHead)", "--"]) {
            new = Set(text.split(whereSeparator: { $0.isWhitespace }).map(String.init))
        }
        return out.outputLines.map { line in
            let parts = line.split(separator: "\0", maxSplits: 1, omittingEmptySubsequences: false)
            let sha = String(parts[0])
            return .object([
                "sha": .string(sha),
                "short": .string(String(sha.prefix(7))),
                "subject": .string(parts.count > 1 ? String(parts[1]) : ""),
                "new": .bool(new.contains(sha)),
            ])
        }
    }

    // MARK: - Paths

    public static func safeRepoPath(_ repo: String, _ rel: String) throws -> String {
        let root = Paths.resolve(repo)
        let p = Paths.resolve(Paths.join(root, rel))
        if !Paths.isInside(p, root: root) {
            throw ServerError("path outside repository")
        }
        return p
    }

    public static func readWorktreeLines(_ cfg: ReviewConfig, rel: String) throws -> [String]? {
        guard let data = try fileBytes(cfg, rel: rel) else { return nil }
        return Diff.splitLines(data)
    }
}
