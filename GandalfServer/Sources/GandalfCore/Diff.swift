import Crypto
import Foundation

public let stateDirName = ".gandalf"
/// Beyond this, skip content/expansion support.
public let maxFileBytes = 5 * 1024 * 1024

// MARK: - Model

public struct DiffLine: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case add, del, ctx
    }

    public var kind: Kind
    public var old: Int?
    public var new: Int?
    public var text: String
    /// "\ No newline at end of file" followed this line.
    public var noNewline = false

    public var json: JSON {
        var o: [String: JSON] = [
            "t": .string(kind.rawValue),
            "old": old.map { .int($0) } ?? .null,
            "new": new.map { .int($0) } ?? .null,
            "text": .string(text),
        ]
        if noNewline { o["nne"] = .bool(true) }
        return .object(o)
    }
}

public struct Hunk: Equatable, Sendable {
    public var oldStart: Int
    public var oldCount: Int
    public var newStart: Int
    public var newCount: Int
    public var section: String
    public let lines: [DiffLine]
    /// An identical hunk is already in the index.
    public var staged = false
    /// Content signature, independent of line numbers, used to spot hunks
    /// that are already present in the index (i.e. staged).
    public let signature: String

    public init(
        oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, section: String, lines: [DiffLine]
    ) {
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.section = section
        self.lines = lines
        var bytes: [UInt8] = []
        for l in lines {
            bytes.append(contentsOf: l.kind.rawValue.utf8)
            bytes.append(contentsOf: l.text.utf8)
            bytes.append(0x0A)
        }
        signature = Insecure.SHA1.hash(data: bytes).hexString
    }

    public var json: JSON {
        .object([
            "oldStart": .int(oldStart),
            "oldCount": .int(oldCount),
            "newStart": .int(newStart),
            "newCount": .int(newCount),
            "section": .string(section),
            "lines": .array(lines.map { $0.json }),
            "staged": .bool(staged),
        ])
    }

}

public struct DiffFile: Equatable, Sendable {
    public var path: String?
    public var oldPath: String?
    public var status: String = "modified"
    public var binary = false
    public var additions = 0
    public var deletions = 0
    public var hunks: [Hunk] = []
    public var newTotal: Int?
    public var untracked = false
    public var tooLarge = false
    /// "none", "partial" or "full"; nil where staging doesn't apply.
    public var stagedState: String?
    public var sig: String?
    public var viewedKey: String?
    public var viewed: Bool?

    public var pathOrEmpty: String { path ?? "" }

    public var json: JSON {
        var o: [String: JSON] = [
            "path": path.map { .string($0) } ?? .null,
            "oldPath": oldPath.map { .string($0) } ?? .null,
            "status": .string(status),
            "binary": .bool(binary),
            "additions": .int(additions),
            "deletions": .int(deletions),
            "hunks": .array(hunks.map { $0.json }),
            "newTotal": newTotal.map { .int($0) } ?? .null,
            "untracked": .bool(untracked),
            "tooLarge": .bool(tooLarge),
            "stagedState": stagedState.map { .string($0) } ?? .null,
        ]
        if let sig { o["sig"] = .string(sig) }
        if let viewedKey { o["viewedKey"] = .string(viewedKey) }
        if let viewed { o["viewed"] = .bool(viewed) }
        return .object(o)
    }
}

// MARK: - Parsing

public enum Diff {
    /// Undo git's C-style quoting of unusual paths (octal escapes are UTF-8
    /// bytes).
    public static func unquoteGitPath(_ p: String) -> String {
        guard p.utf8.count >= 2, p.hasPrefix("\""), p.hasSuffix("\"") else { return p }
        let body = Array(p.utf8.dropFirst().dropLast())
        var out: [UInt8] = []
        var i = 0
        let escapes: [UInt8: UInt8] = [
            UInt8(ascii: "n"): 0x0A, UInt8(ascii: "t"): 0x09, UInt8(ascii: "r"): 0x0D,
            UInt8(ascii: "\""): UInt8(ascii: "\""), UInt8(ascii: "\\"): UInt8(ascii: "\\"),
        ]
        while i < body.count {
            let c = body[i]
            if c == UInt8(ascii: "\\"), i + 1 < body.count {
                if let e = escapes[body[i + 1]] {
                    out.append(e)
                    i += 2
                    continue
                }
                if i + 3 < body.count,
                   let v = UInt8(String(decoding: body[(i + 1)...(i + 3)], as: UTF8.self), radix: 8) {
                    out.append(v)
                    i += 4
                    continue
                }
            }
            out.append(c)
            i += 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    static func stripPrefix(_ p: String) -> String? {
        let p = unquoteGitPath(p.trimmed)
        if p == "/dev/null" { return nil }
        if p.hasPrefix("a/") || p.hasPrefix("b/") { return String(p.dropFirst(2)) }
        return p
    }

    /// `@@ -a[,b] +c[,d] @@[ section]`. Hand-parsed: there is one per hunk,
    /// and a Regex match costs more than the rest of the hunk.
    static func parseHunkHeader(_ line: String) -> (Int, Int?, Int, Int?, String)? {
        var bytes = Array(line.utf8)[...]
        func take(_ prefix: String) -> Bool {
            guard bytes.starts(with: prefix.utf8) else { return false }
            bytes = bytes.dropFirst(prefix.utf8.count)
            return true
        }
        func number() -> Int? {
            var n = 0
            var any = false
            while let b = bytes.first, b >= 0x30, b <= 0x39 {
                n = n * 10 + Int(b - 0x30)
                any = true
                bytes = bytes.dropFirst()
            }
            return any ? n : nil
        }
        guard take("@@ -"), let oldStart = number() else { return nil }
        var oldCount: Int?
        if take(",") { guard let n = number() else { return nil }; oldCount = n }
        guard take(" +"), let newStart = number() else { return nil }
        var newCount: Int?
        if take(",") { guard let n = number() else { return nil }; newCount = n }
        guard take(" @@") else { return nil }
        _ = take(" ")
        return (oldStart, oldCount, newStart, newCount, String(decoding: bytes, as: UTF8.self))
    }

    static var diffHeader: Regex<(Substring, Substring, Substring)> { /^diff --git "?a\/(.*?)"? "?b\/(.*?)"?$/ }

    public static func parseUnifiedDiff(_ raw: String) -> [DiffFile] {
        var files: [DiffFile] = []
        let lines = raw.lines
        var i = 0
        let n = lines.count
        while i < n {
            if !lines[i].hasPrefix("diff --git ") {
                i += 1
                continue
            }
            let header = lines[i]
            i += 1
            var f = DiffFile()
            var isNew = false
            var isDeleted = false
            var renameFrom: String?
            var renameTo: String?
            // nil inside the optional = "/dev/null"; outer nil = header absent.
            var oldP: String?? = .none
            var newP: String?? = .none
            while i < n, !lines[i].hasPrefix("diff --git "), !lines[i].hasPrefix("@@") {
                let l = lines[i]
                if l.hasPrefix("new file mode") {
                    isNew = true
                } else if l.hasPrefix("deleted file mode") {
                    isDeleted = true
                } else if l.hasPrefix("rename from ") {
                    renameFrom = unquoteGitPath(String(l.dropFirst("rename from ".count)))
                } else if l.hasPrefix("rename to ") {
                    renameTo = unquoteGitPath(String(l.dropFirst("rename to ".count)))
                } else if l.hasPrefix("Binary files ") || l.hasPrefix("GIT binary patch") {
                    f.binary = true
                } else if l.hasPrefix("--- ") {
                    oldP = .some(stripPrefix(String(l.dropFirst(4))))
                } else if l.hasPrefix("+++ ") {
                    newP = .some(stripPrefix(String(l.dropFirst(4))))
                }
                i += 1
            }

            if let renameTo {
                f.path = renameTo
                f.oldPath = renameFrom
                f.status = "renamed"
            } else {
                // Prefer ---/+++ headers; fall back to the "diff --git a/X b/Y" line.
                switch (newP, oldP) {
                case (.none, .none):
                    f.path = (try? diffHeader.wholeMatch(in: header)).map { unquoteGitPath(String($0.2)) } ?? header
                case (.some(.some(let p)), _):
                    f.path = p
                case (_, .some(let old)):
                    f.path = old
                case (.some(.none), .none):
                    f.path = nil
                }
                if isNew {
                    f.status = "added"
                } else if isDeleted {
                    f.status = "deleted"
                }
            }

            while i < n, lines[i].hasPrefix("@@") {
                guard let (oldStart, oldCountOpt, newStart, newCountOpt, section) =
                    parseHunkHeader(lines[i])
                else { break }
                i += 1
                let oldCount = oldCountOpt ?? 1
                let newCount = newCountOpt ?? 1
                var hunkLines: [DiffLine] = []
                var oldNum = oldStart
                var newNum = newStart
                var oldRem = oldCount
                var newRem = newCount
                while i < n, oldRem > 0 || newRem > 0 {
                    let l = lines[i]
                    if l.hasPrefix("\\") {  // "\ No newline at end of file"
                        if !hunkLines.isEmpty { hunkLines[hunkLines.count - 1].noNewline = true }
                        i += 1
                        continue
                    }
                    let text = l.droppingFirstByte
                    switch l.firstByte {
                    case UInt8(ascii: "+"):
                        hunkLines.append(DiffLine(kind: .add, old: nil, new: newNum, text: text))
                        newNum += 1
                        newRem -= 1
                        f.additions += 1
                    case UInt8(ascii: "-"):
                        hunkLines.append(DiffLine(kind: .del, old: oldNum, new: nil, text: text))
                        oldNum += 1
                        oldRem -= 1
                        f.deletions += 1
                    default:
                        hunkLines.append(DiffLine(kind: .ctx, old: oldNum, new: newNum, text: text))
                        oldNum += 1
                        newNum += 1
                        oldRem -= 1
                        newRem -= 1
                    }
                    i += 1
                }
                f.hunks.append(Hunk(
                    oldStart: oldStart, oldCount: oldCount, newStart: newStart,
                    newCount: newCount, section: section, lines: hunkLines
                ))
            }
            files.append(f)
        }
        return files
    }

    /// The file's lines; a trailing newline does not start an empty line.
    public static func splitLines(_ data: Data) -> [String] {
        if data.isEmpty { return [] }
        let text = data.decodedLossy
        var lines = text.lines
        if text.endsWithNewline { lines.removeLast() }
        return lines
    }

    public static func countLines(_ data: Data) -> Int {
        if data.isEmpty { return 0 }
        let newlines = data.withUnsafeBytes { $0.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) } }
        return newlines + (data.last == 0x0A ? 0 : 1)
    }

    static func synthesizeUntracked(repo: String, rel: String) -> DiffFile? {
        let p = Paths.join(repo, rel)
        guard let st = Paths.fileStat(p) else { return nil }
        var f = DiffFile()
        f.path = rel
        f.status = "added"
        f.untracked = true
        if st.size > maxFileBytes {
            f.binary = true  // treat as opaque; too big to render
            f.tooLarge = true
            return f
        }
        guard let data = try? Paths.readData(p) else { return nil }
        if data.contains(0) {
            f.binary = true
            return f
        }
        let fileLines = splitLines(data)
        if !fileLines.isEmpty {
            f.hunks.append(Hunk(
                oldStart: 0, oldCount: 0, newStart: 1, newCount: fileLines.count, section: "",
                lines: fileLines.enumerated().map { DiffLine(kind: .add, old: nil, new: $0 + 1, text: $1) }
            ))
            f.additions = fileLines.count
        }
        f.newTotal = fileLines.count
        return f
    }

    static func skipUntracked(_ rel: String, skipPrefixes: [String]) -> Bool {
        if rel.split(separator: "/").contains(Substring(stateDirName)) { return true }
        return skipPrefixes.contains { rel == $0 || rel.hasPrefix($0 + "/") }
    }
}

// MARK: - Hashing

extension HashFunction {
    mutating func update(string: String) {
        var s = string
        s.withUTF8 { update(bufferPointer: UnsafeRawBufferPointer($0)) }
    }

    mutating func update(bytes: [UInt8]) {
        bytes.withUnsafeBytes { update(bufferPointer: $0) }
    }
}

extension Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
