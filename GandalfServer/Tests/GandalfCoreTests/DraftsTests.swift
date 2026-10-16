import Foundation
import Testing
@testable import GandalfCore

@Suite struct DraftsTests {
    static func lineComment(
        id: String, file: String, side: String = "new", start: Int, end: Int, excerpt: [String],
        extra: [String: JSON] = [:]
    ) -> JSON {
        var o: [String: JSON] = [
            "id": .string(id), "file": .string(file), "side": .string(side),
            "startLine": .int(start), "endLine": .int(end),
            "excerpt": .array(excerpt.map { .string($0) }), "text": .string("t"),
        ]
        for (k, v) in extra { o[k] = v }
        return .object(o)
    }

    func worktree(_ files: [String: String]) throws -> (TempDir, ReviewConfig) {
        let tmp = try TempDir()
        for (rel, text) in files { try tmp.write(rel, text) }
        let cfg = ReviewConfig(
            repo: Paths.resolve(tmp.path), base: "HEAD", stateRoot: Paths.join(tmp.path, ".gandalf")
        )
        return (tmp, cfg)
    }

    @Test func newSideDraftsFollowQuotedLines() throws {
        let (tmp, cfg) = try worktree(["a.txt": "x\nalpha\nbeta\ngamma\nalpha\nbeta\n"])
        defer { withExtendedLifetime(tmp) {} }
        var drafts = [
            Self.lineComment(id: "moves", file: "a.txt", start: 1, end: 2, excerpt: ["+alpha", " beta"]),
            Self.lineComment(id: "closest", file: "a.txt", start: 6, end: 7, excerpt: ["+alpha", " beta"]),
            Self.lineComment(id: "detaches", file: "a.txt", start: 1, end: 1, excerpt: ["+nope"]),
            Self.lineComment(id: "deleted-only", file: "a.txt", start: 1, end: 1, excerpt: ["-alpha"]),
            Self.lineComment(id: "missing-file", file: "zzz.txt", start: 1, end: 1, excerpt: [" x"]),
            Self.lineComment(id: "outside", file: "../a.txt", start: 1, end: 1, excerpt: [" x"]),
        ]
        let changed = try Drafts.reanchor(cfg, files: [], drafts: &drafts, view: .base(base: "b", all: nil))
        #expect(changed)
        #expect(drafts[0]["startLine"] == .int(2) && drafts[0]["endLine"] == .int(3) && drafts[0]["detached"] == .bool(false))
        #expect(drafts[1]["startLine"] == .int(5) && drafts[1]["endLine"] == .int(6))
        #expect(drafts[2]["detached"] == .bool(true) && drafts[2]["startLine"] == .int(1))
        #expect(drafts[3]["detached"] == .bool(true))
        #expect(drafts[4]["detached"] == .bool(true))
        #expect(drafts[5]["detached"] == .bool(true))
        // A second pass changes nothing.
        #expect(try Drafts.reanchor(cfg, files: [], drafts: &drafts, view: .base(base: "b", all: nil)) == false)
    }

    @Test func skipsRepliesFileLevelReviewLevelAndCommitPinned() throws {
        let (tmp, cfg) = try worktree(["a.txt": "x\n"])
        defer { withExtendedLifetime(tmp) {} }
        let original: [JSON] = [
            .object(["id": .string("r"), "parentId": .string("p"), "file": .string("a.txt"), "excerpt": .array([.string("+nope")])]),
            .object(["id": .string("f"), "fileLevel": .bool(true), "file": .string("a.txt")]),
            .object(["id": .string("o"), "reviewLevel": .bool(true), "file": .null]),
            Self.lineComment(id: "c", file: "a.txt", start: 9, end: 9, excerpt: ["+nope"], extra: ["commit": .string("abcdef")]),
        ]
        var drafts = original
        #expect(try Drafts.reanchor(cfg, files: [], drafts: &drafts, view: .base(base: "b", all: nil)) == false)
        #expect(drafts == original)
    }

    @Test func commitViewLeavesNewSideDraftsAlone() throws {
        let (tmp, cfg) = try worktree(["a.txt": "x\n"])
        defer { withExtendedLifetime(tmp) {} }
        var drafts = [Self.lineComment(id: "n", file: "a.txt", start: 1, end: 1, excerpt: ["+nope"])]
        let view = View.commit(sha: "abcdef0", short: "abcdef0", subject: "s")
        #expect(try Drafts.reanchor(cfg, files: [], drafts: &drafts, view: view) == false)
        #expect(drafts[0]["detached"].isNull)
    }

    @Test func oldSideDraftsStayWhileDeletionsRemain() throws {
        let (tmp, cfg) = try worktree([:])
        defer { withExtendedLifetime(tmp) {} }
        var file = DiffFile()
        file.path = "a.txt"
        file.hunks = [Hunk(oldStart: 1, oldCount: 3, newStart: 1, newCount: 1, section: "", lines: [
            DiffLine(kind: .del, old: 1, new: nil, text: "a"),
            DiffLine(kind: .del, old: 2, new: nil, text: "b"),
            DiffLine(kind: .ctx, old: 3, new: 1, text: "c"),
        ])]
        var bin = DiffFile()
        bin.path = "b.bin"
        bin.binary = true
        let base = View.base(base: "basesha", all: nil)
        var drafts = [
            Self.lineComment(id: "kept", file: "a.txt", side: "old", start: 1, end: 2, excerpt: ["-a", "-b"], extra: ["base": .string("basesha")]),
            Self.lineComment(id: "spans-ctx", file: "a.txt", side: "old", start: 2, end: 3, excerpt: ["-b", " c"], extra: ["base": .string("basesha")]),
            Self.lineComment(id: "other-base", file: "a.txt", side: "old", start: 1, end: 1, excerpt: ["-a"], extra: ["base": .string("other")]),
            Self.lineComment(id: "baseline", file: "a.txt", side: "old", start: 1, end: 1, excerpt: ["-a"], extra: ["baseline": .int(2)]),
            Self.lineComment(id: "binary", file: "b.bin", side: "old", start: 1, end: 1, excerpt: [], extra: ["base": .string("basesha")]),
            Self.lineComment(id: "gone-file", file: "c.txt", side: "old", start: 1, end: 1, excerpt: [], extra: ["base": .string("basesha")]),
        ]
        #expect(try Drafts.reanchor(cfg, files: [file, bin], drafts: &drafts, view: base))
        #expect(drafts[0]["detached"] == .bool(false))
        #expect(drafts[1]["detached"] == .bool(true))
        #expect(drafts[2]["detached"].isNull)  // not this view's old side: untouched
        #expect(drafts[3]["detached"].isNull)
        #expect(drafts[4]["detached"] == .bool(true))
        #expect(drafts[5]["detached"] == .bool(true))

        // The baseline draft is checked in its own view, and the base one is not.
        var again = drafts
        #expect(try Drafts.reanchor(cfg, files: [file], drafts: &again, view: .since(revision: 2)))
        #expect(again[3]["detached"] == .bool(false))
        #expect(again[2]["detached"].isNull)
    }

    @Test func hunkPatchRebuildsUnifiedDiff() throws {
        let hunk = try JSON.parse(#"""
        {"oldStart": 3, "oldCount": 2, "newStart": 3, "newCount": 2, "section": "", "lines": [
          {"t": "ctx", "old": 3, "new": 3, "text": "keep"},
          {"t": "del", "old": 4, "new": null, "text": "old"},
          {"t": "add", "old": null, "new": 4, "text": "new", "nne": true}
        ]}
        """#)
        let patch = String(decoding: try Drafts.hunkPatch(path: "dir/f.txt", hunk: hunk), as: UTF8.self)
        #expect(patch == "--- a/dir/f.txt\n+++ b/dir/f.txt\n@@ -3,2 +3,2 @@\n keep\n-old\n+new\n\\ No newline at end of file\n")
        #expect(throws: ServerError.self) {
            try Drafts.hunkPatch(path: "x", hunk: try JSON.parse(#"{"lines": [{"t": "bogus", "text": ""}]}"#))
        }
    }

    @Test func findOccurrences() {
        #expect(Drafts.findOccurrences(["a", "b", "a", "b"], ["a", "b"]) == [0, 2])
        #expect(Drafts.findOccurrences(["a"], ["a", "b"]) == [])
        #expect(Drafts.findOccurrences(["x"], []) == [])
    }
}
