import Foundation

// Branch-scoped state under <repo>/.gandalf/

public enum State {
    public static func currentBranch(_ repo: String) async throws -> String {
        let name = try await Git.runText(repo, ["rev-parse", "--abbrev-ref", "HEAD"]).trimmed
        if name == "HEAD" {  // detached
            let sha = try await Git.runText(repo, ["rev-parse", "--short", "HEAD"]).trimmed
            return "detached-\(sha)"
        }
        return name
    }

    public static func branchSlug(_ branch: String) -> String {
        branch.replacing(/[^A-Za-z0-9._-]+/, with: "__")
    }

    public static func branchDir(_ stateRoot: String, _ branch: String) -> String {
        Paths.join(Paths.join(stateRoot, "branches"), branchSlug(branch))
    }

    public static func writeJSONAtomic(_ path: String, _ value: JSON) throws {
        try Paths.writeTextAtomic(path, value.serialized(pretty: true) + "\n")
    }

    static func readJSONFile(_ path: String) -> JSON? {
        guard let data = try? Paths.readData(path) else { return nil }
        return try? JSON.parse(data)
    }

    public static func read(_ stateRoot: String, _ branch: String) -> [String: JSON] {
        let p = Paths.join(branchDir(stateRoot, branch), "state.json")
        if let obj = readJSONFile(p)?.objectValue {
            return obj
        }
        return ["branch": .string(branch), "drafts": .array([]), "revisions": .array([])]
    }

    public static func write(_ stateRoot: String, _ branch: String, _ state: [String: JSON]) throws {
        try writeJSONAtomic(Paths.join(branchDir(stateRoot, branch), "state.json"), .object(state))
    }

    /// Delete submitted reviews and their content snapshots — for when git
    /// surgery (rebase, reset, re-created branch) makes the "since review rN"
    /// baselines meaningless. Drafts and Viewed marks are deliberately kept:
    /// they are the review in progress, not history. Returns what was removed.
    public static func wipeHistory(
        _ stateRoot: String, _ branch: String, allBranches: Bool
    ) throws -> (reviews: Int, branches: Int) {
        let root = Paths.join(stateRoot, "branches")
        let dirs: [String]
        if allBranches {
            dirs = Paths.listDirectory(root).filter { Paths.isDirectory($0) }
        } else {
            let d = branchDir(stateRoot, branch)
            dirs = Paths.isDirectory(d) ? [d] : []
        }
        var reviews = 0
        var branches = 0
        for d in dirs {
            let sp = Paths.join(d, "state.json")
            // Unreadable state still has its revisions dropped.
            var state = readJSONFile(sp)?.objectValue
            let n = state?["revisions"]?.arrayValue?.count ?? 0
            let revdir = Paths.join(d, "revisions")
            let hadDir = Paths.isDirectory(revdir)
            if !hadDir && n == 0 { continue }
            if hadDir { Paths.removeTree(revdir) }
            if state != nil {
                state!["revisions"] = .array([])
                try writeJSONAtomic(sp, .object(state!))
            }
            reviews += n
            branches += 1
        }
        // Snapshot trees are shared across branches, so only a full wipe can
        // drop the store; a branch wipe just leaves its trees unreferenced.
        if allBranches {
            Paths.removeTree(Paths.join(stateRoot, "objects"))
        }
        // The handoff file describes the latest submitted review; once that
        // review is gone, an agent must not still be able to act on it.
        Paths.unlink(Paths.join(stateRoot, "pending-review.md"))
        Paths.unlink(Paths.join(stateRoot, "pending-review.json"))
        return (reviews, branches)
    }

    /// Local time with offset, to the second.
    public static func nowISO(_ date: Date = Date(), timeZone: TimeZone = .current) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = timeZone
        return f.string(from: date)
    }
}
