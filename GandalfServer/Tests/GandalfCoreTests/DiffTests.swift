import Foundation
import Testing
@testable import GandalfCore

@Suite struct DiffTests {
    /// The expected parse was captured from the original implementation,
    /// which omitted the fields this one always emits.
    static func normalized(_ expected: JSON) -> JSON {
        .array((expected.arrayValue ?? []).map { file in
            var f = file.objectValue!
            f["untracked"] = f["untracked"] ?? .bool(false)
            f["tooLarge"] = f["tooLarge"] ?? .bool(false)
            f["stagedState"] = f["stagedState"] ?? .null
            f["hunks"] = .array((f["hunks"]?.arrayValue ?? []).map { hunk in
                var h = hunk.objectValue!
                h["staged"] = h["staged"] ?? .bool(false)
                return .object(h)
            })
            return .object(f)
        })
    }

    @Test func parsesSampleDiff() throws {
        let files = Diff.parseUnifiedDiff(try Fixtures.text("sample.diff"))
        let expected = Self.normalized(try Fixtures.json("sample.diff.json"))
        #expect(JSON.array(files.map { $0.json }) == expected)
    }

    @Test func hunkSignaturesAreStable() throws {
        let files = Diff.parseUnifiedDiff(try Fixtures.text("sample.diff"))
        let expected = try Fixtures.json("sample.sigs.json")
        for f in files {
            let sigs = f.hunks.map { JSON.string($0.signature) }
            #expect(expected[f.path!] == .array(sigs), Comment(rawValue: f.path!))
        }
    }

    @Test func unquotesGitPaths() {
        #expect(Diff.unquoteGitPath("plain/path.txt") == "plain/path.txt")
        #expect(Diff.unquoteGitPath(#""a\tb""#) == "a\tb")
        #expect(Diff.unquoteGitPath(#""q\"uote""#) == "q\"uote")
        #expect(Diff.unquoteGitPath(#""back\\slash""#) == "back\\slash")
        #expect(Diff.unquoteGitPath(#""\303\274n\303\257""#) == "ünï")
        #expect(Diff.unquoteGitPath(#""\z""#) == "\\z")
        #expect(Diff.unquoteGitPath("\"") == "\"")
    }

    @Test func headerFallbackForQuotedPaths() {
        let files = Diff.parseUnifiedDiff("diff --git \"a/quoted mode.sh\" \"b/quoted mode.sh\"\nold mode 100644\nnew mode 100755\n")
        #expect(files[0].path == "quoted mode.sh")
        let plain = Diff.parseUnifiedDiff("diff --git a/x/y b/x/y\nold mode 100644\nnew mode 100755\n")
        #expect(plain[0].path == "x/y")
    }

    @Test func hunkHeaderVariants() {
        let one = Diff.parseUnifiedDiff("diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n")
        #expect(one[0].hunks[0].oldCount == 1 && one[0].hunks[0].newCount == 1)
        #expect(one[0].hunks[0].section == "")
        let bad = Diff.parseUnifiedDiff("diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ garbage @@\n-a\n")
        #expect(bad[0].hunks.isEmpty)
        let sect = Diff.parseUnifiedDiff("diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1,2 +1,2 @@ func f() {\n a\n-b\n+c\n")
        #expect(sect[0].hunks[0].section == "func f() {")
    }

    @Test func crlfLinesStayIntact() {
        let files = Diff.parseUnifiedDiff("diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\r\n+b\r\n")
        #expect(files[0].hunks[0].lines.map { $0.text } == ["a\r", "b\r"])
    }

    @Test func countsAndSplitsLines() {
        #expect(Diff.countLines(Data()) == 0)
        #expect(Diff.countLines(Data("a\n".utf8)) == 1)
        #expect(Diff.countLines(Data("a\nb".utf8)) == 2)
        #expect(Diff.countLines(Data("a\r\nb\r\n".utf8)) == 2)
        #expect(Diff.splitLines(Data("a\nb\n".utf8)) == ["a", "b"])
        #expect(Diff.splitLines(Data("a\nb".utf8)) == ["a", "b"])
        #expect(Diff.splitLines(Data("\n".utf8)) == [""])
        #expect(Diff.splitLines(Data("a\r\n".utf8)) == ["a\r"])
    }

    @Test func synthesizesUntrackedFiles() throws {
        let tmp = try TempDir()
        try tmp.write("t.txt", "one\ntwo\n")
        try tmp.write("b.bin", "x\u{0}y")
        try tmp.write("empty", "")
        let t = Diff.synthesizeUntracked(repo: tmp.path, rel: "t.txt")!
        #expect(t.status == "added" && t.untracked && t.newTotal == 2 && t.additions == 2)
        #expect(t.hunks[0].lines.map { $0.new } == [1, 2])
        let b = Diff.synthesizeUntracked(repo: tmp.path, rel: "b.bin")!
        #expect(b.binary && b.hunks.isEmpty && b.newTotal == nil)
        let e = Diff.synthesizeUntracked(repo: tmp.path, rel: "empty")!
        #expect(!e.binary && e.hunks.isEmpty && e.newTotal == 0)
        #expect(Diff.synthesizeUntracked(repo: tmp.path, rel: "missing") == nil)
    }

    @Test func skipsStateDirUntracked() {
        #expect(Diff.skipUntracked(".gandalf/x", skipPrefixes: []))
        #expect(Diff.skipUntracked("a/.gandalf/x", skipPrefixes: []))
        #expect(!Diff.skipUntracked("a/.gandalfx", skipPrefixes: []))
        #expect(Diff.skipUntracked("state/x", skipPrefixes: ["state"]))
        #expect(Diff.skipUntracked("state", skipPrefixes: ["state"]))
        #expect(!Diff.skipUntracked("statex", skipPrefixes: ["state"]))
    }

    @Test func fileJSONShape() {
        var f = DiffFile()
        f.path = "p"
        f.stagedState = "none"
        f.sig = "s"
        f.viewedKey = "p"
        f.viewed = false
        #expect(f.json.objectValue!.keys.sorted() == [
            "additions", "binary", "deletions", "hunks", "newTotal", "oldPath", "path",
            "sig", "stagedState", "status", "tooLarge", "untracked", "viewed", "viewedKey",
        ])
        f.stagedState = nil
        #expect(f.json["stagedState"] == .null)
    }
}
