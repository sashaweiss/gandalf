import Foundation
import Testing
@testable import GandalfCore

@Suite struct StateTests {
    @Test func branchSlugs() {
        #expect(State.branchSlug("main") == "main")
        #expect(State.branchSlug("feature/foo-bar_1.2") == "feature__foo-bar_1.2")
        #expect(State.branchSlug("a//b  c") == "a__b__c")
        #expect(State.branchSlug("ünï") == "__n__")
        #expect(State.branchSlug("detached-abc1234") == "detached-abc1234")
    }

    @Test func isoTimestampsCarryTheLocalOffset() {
        let date = Date(timeIntervalSince1970: 1_792_000_000)  // 2026-10-14T17:46:40Z
        #expect(State.nowISO(date, timeZone: TimeZone(identifier: "UTC")!) == "2026-10-14T17:46:40Z")
        #expect(State.nowISO(date, timeZone: TimeZone(secondsFromGMT: -7 * 3600)!) == "2026-10-14T10:46:40-07:00")
        #expect(State.nowISO(date, timeZone: TimeZone(secondsFromGMT: 5 * 3600 + 1800)!) == "2026-10-14T23:16:40+05:30")
    }

    @Test func defaultStateAndRoundTrip() throws {
        let tmp = try TempDir()
        let fresh = State.read(tmp.path, "feature/x")
        #expect(fresh == ["branch": .string("feature/x"), "drafts": .array([]), "revisions": .array([])])
        var state = fresh
        state["drafts"] = .array([.string("d")])
        try State.write(tmp.path, "feature/x", state)
        #expect(tmp.exists("branches/feature__x/state.json"))
        let text = try tmp.read("branches/feature__x/state.json")
        #expect(text == "{\n  \"branch\": \"feature/x\",\n  \"drafts\": [\n    \"d\"\n  ],\n  \"revisions\": []\n}\n")
        #expect(State.read(tmp.path, "feature/x") == state)
        // An unreadable file falls back to the default.
        try tmp.write("branches/feature__x/state.json", "{broken")
        #expect(State.read(tmp.path, "feature/x") == fresh)
    }

    @Test func wipeHistoryKeepsDraftsAndViewed() throws {
        let tmp = try TempDir()
        for branch in ["a", "b"] {
            var state = State.read(tmp.path, branch)
            state["drafts"] = .array([.string("keep")])
            state["viewed"] = .object(["p": .string("sig")])
            state["revisions"] = .array([.object(["revision": .int(1)]), .object(["revision": .int(2)])])
            try State.write(tmp.path, branch, state)
            try tmp.write("branches/\(branch)/revisions/1.json", "{}")
        }
        try tmp.write("objects/ab/cdef", "x")
        try tmp.write("pending-review.md", "x")
        try tmp.write("pending-review.json", "x")

        let one = try State.wipeHistory(tmp.path, "a", allBranches: false)
        #expect(one.reviews == 2 && one.branches == 1)
        #expect(!tmp.exists("branches/a/revisions"))
        #expect(tmp.exists("branches/b/revisions/1.json"))
        #expect(tmp.exists("objects/ab/cdef"))
        #expect(!tmp.exists("pending-review.md") && !tmp.exists("pending-review.json"))
        let a = State.read(tmp.path, "a")
        #expect(a["revisions"] == .array([]))
        #expect(a["drafts"] == .array([.string("keep")]))
        #expect(a["viewed"]?["p"] == .string("sig"))

        let again = try State.wipeHistory(tmp.path, "a", allBranches: false)
        #expect(again.reviews == 0 && again.branches == 0)

        let all = try State.wipeHistory(tmp.path, "a", allBranches: true)
        #expect(all.reviews == 2 && all.branches == 1)
        #expect(!tmp.exists("objects"))
        #expect(!tmp.exists("branches/b/revisions"))
    }

    @Test func wipeHistoryOnMissingStateDir() throws {
        let tmp = try TempDir()
        let r = try State.wipeHistory(Paths.join(tmp.path, "nope"), "a", allBranches: true)
        #expect(r.reviews == 0 && r.branches == 0)
    }
}

@Suite struct TextTests {
    @Test func lineSplitting() {
        #expect("a\r\nb\n".lines == ["a\r", "b", ""])
        #expect("a\nb\n".outputLines == ["a", "b"])
        #expect("".outputLines == [])
        #expect("+\r".droppingFirstByte == "\r")
        #expect("+x".firstByte == UInt8(ascii: "+"))
    }

    @Test func trimming() {
        #expect("  a b \n".trimmed == "a b")
        #expect("x \t\n".trimmingTrailingWhitespace == "x")
        #expect("  x".trimmingTrailingWhitespace == "  x")
    }
}

@Suite struct PathTests {
    @Test func resolveFollowsSymlinksAndKeepsMissingTail() throws {
        let tmp = try TempDir()
        let real = Paths.resolve(tmp.path)
        try tmp.write("dir/file.txt", "x")
        try FileManager.default.createSymbolicLink(atPath: Paths.join(tmp.path, "link"), withDestinationPath: "dir")
        #expect(Paths.resolve(Paths.join(tmp.path, "link/file.txt")) == Paths.join(real, "dir/file.txt"))
        #expect(Paths.resolve(Paths.join(tmp.path, "link/../dir/./missing/x")) == Paths.join(real, "dir/missing/x"))
        #expect(Paths.resolve(Paths.join(tmp.path, "dir/missing/../../other")) == Paths.join(real, "other"))
    }

    @Test func safeRepoPathRejectsEscapes() throws {
        let tmp = try TempDir()
        try tmp.write("in.txt", "x")
        // Resolved, as `ReviewConfig` guarantees (macOS temp dirs sit behind
        // a symlink).
        let repo = Paths.resolve(tmp.path)
        _ = try Review.safeRepoPath(repo, "in.txt")
        _ = try Review.safeRepoPath(repo, ".")
        #expect(throws: ServerError.self) { try Review.safeRepoPath(repo, "../x") }
        #expect(throws: ServerError.self) { try Review.safeRepoPath(repo, "/etc/passwd") }
        #expect(throws: ServerError.self) { try Review.safeRepoPath(repo, "a/../../x") }
    }

    @Test func atomicWriteReplaces() throws {
        let tmp = try TempDir()
        let p = Paths.join(tmp.path, "a/b/c.txt")
        try Paths.writeTextAtomic(p, "one")
        try Paths.writeTextAtomic(p, "two")
        #expect(try Paths.readText(p) == "two")
        #expect(!tmp.exists("a/b/c.txt.tmp"))
    }

    @Test func fileStatHasNanosecondMtime() throws {
        let tmp = try TempDir()
        try tmp.write("f", "abc")
        let st = Paths.fileStat(Paths.join(tmp.path, "f"))!
        #expect(st.size == 3)
        #expect(st.mtimeNs > 1_600_000_000_000_000_000)
        #expect(Paths.fileStat(Paths.join(tmp.path, "missing")) == nil)
    }

    @Test func listDirectoryIsSorted() throws {
        let tmp = try TempDir()
        for n in ["b", "a", "c"] { try tmp.write(n, "") }
        #expect(Paths.listDirectory(tmp.path).map { Paths.name($0) } == ["a", "b", "c"])
        #expect(Paths.listDirectory(Paths.join(tmp.path, "nope")) == [])
    }
}
