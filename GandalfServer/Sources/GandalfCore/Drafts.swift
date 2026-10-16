import Foundation

/// Which old side a view's (or a draft's) deleted-line numbers point into.
public enum OldSideKey: Equatable, Sendable {
    case base(String)
    case since(Int)
    case commit(String)
}

/// Which view a payload is for (see `Router.collectView`).
public enum View: Equatable, Sendable {
    /// `--base` (or the branch point, for "all changes") → working tree.
    case base(base: String, all: String?)
    /// Review rN's snapshot → working tree.
    case since(revision: Int)
    /// A commit vs its first parent.
    case commit(sha: String, short: String, subject: String)

    public var kind: String {
        switch self {
        case .base: return "base"
        case .since: return "since"
        case .commit: return "commit"
        }
    }

    public var json: JSON {
        var o: [String: JSON] = ["kind": .string(kind)]
        switch self {
        case .base(let base, let all):
            o["base"] = .string(base)
            o["all"] = all.map { .string($0) } ?? .null
        case .since(let revision):
            o["since"] = .int(revision)
        case .commit(let sha, let short, let subject):
            o["commit"] = .string(sha)
            o["short"] = .string(short)
            o["subject"] = .string(subject)
        }
        return .object(o)
    }

    var oldKey: OldSideKey {
        switch self {
        case .base(let base, _): return .base(base)
        case .since(let revision): return .since(revision)
        case .commit(let sha, _, _): return .commit(sha)
        }
    }
}

// Draft re-anchoring
//
// The rule (kept deliberately simple so it's predictable): a draft follows
// the exact lines it quotes. On every load, "new"-side drafts are re-located
// by searching the working-tree file for their quoted lines verbatim; if
// found, the anchor moves with them (occurrence closest to the previous
// anchor wins). If the quoted lines no longer exist verbatim, the draft is
// marked detached and displays its saved excerpt instead of pointing at the
// wrong code. "old"-side drafts (on deleted lines) never move — their old
// side is fixed — they only detach if the deletion itself is gone from the
// diff. Drafts made in a commit view are pinned to that commit, which never
// changes, so they are never re-anchored at all.

public enum Drafts {
    static func findOccurrences(_ haystack: [String], _ needle: [String]) -> [Int] {
        let n = needle.count
        guard n > 0, n <= haystack.count else { return [] }
        return (0...(haystack.count - n)).filter { i in
            (0..<n).allSatisfy { haystack[i + $0] == needle[$0] }
        }
    }

    static func oldSideKey(_ c: JSON) -> OldSideKey {
        if let commit = c["commit"].stringValue, !commit.isEmpty { return .commit(commit) }
        if let baseline = c["baseline"].intValue { return .since(baseline) }
        return .base(c["base"].stringValue ?? "")
    }

    /// `view` is the view being collected. Old-side drafts belong to the
    /// view they were made in — their line numbers mean nothing against a
    /// different old side — so they are only re-checked when the views
    /// match. New-side drafts anchor to the working tree, which is the new
    /// side of every view but a commit view. Returns whether anything moved.
    public static func reanchor(
        _ cfg: ReviewConfig, files: [DiffFile], drafts: inout [JSON], view: View
    ) throws -> Bool {
        var byPath: [String: DiffFile] = [:]
        for f in files { byPath[f.pathOrEmpty] = f }
        var fileCache: [String: [String]?] = [:]
        var changed = false
        for idx in drafts.indices {
            let d = drafts[idx]
            guard var c = d.objectValue else { continue }
            if d["fileLevel"].isTrue || d["reviewLevel"].isTrue || !d["parentId"].isNull {
                continue  // no lines of their own; replies follow their thread root
            }
            if !d["commit"].isNull { continue }  // pinned to an immutable commit
            if d["side"].stringValue == "old" {
                if oldSideKey(d) != view.oldKey { continue }
                let f = d["file"].stringValue.flatMap { byPath[$0] }
                if let f, !f.binary {
                    var deleted = Set<Int>()
                    for h in f.hunks {
                        for l in h.lines where l.kind == .del {
                            if let old = l.old { deleted.insert(old) }
                        }
                    }
                    guard let start = d["startLine"].intValue, let end = d["endLine"].intValue else {
                        throw ServerError("draft \(d["id"]) has no line range")
                    }
                    let attached = start > end || (start...end).allSatisfy { deleted.contains($0) }
                    c["detached"] = .bool(!attached)
                } else {
                    c["detached"] = .bool(true)
                }
            } else {
                if case .commit = view { continue }
                let texts = (d["excerpt"].arrayValue ?? []).compactMap { e -> String? in
                    guard let s = e.stringValue, s.firstByte == UInt8(ascii: "+") || s.firstByte == 0x20
                    else { return nil }
                    return s.droppingFirstByte
                }
                guard let file = d["file"].stringValue else {
                    throw ServerError("draft \(d["id"]) has no file")
                }
                if fileCache[file] == nil {
                    fileCache[file] = .some((try? Review.readWorktreeLines(cfg, rel: file)) ?? nil)
                }
                let occ = fileCache[file]!.map { findOccurrences($0, texts) } ?? []
                if occ.isEmpty {
                    c["detached"] = .bool(true)
                } else {
                    c["detached"] = .bool(false)
                    let startLine = d["startLine"].intValue ?? 0
                    let best = occ.min { abs($0 + 1 - startLine) < abs($1 + 1 - startLine) }!
                    c["startLine"] = .int(best + 1)
                    c["endLine"] = .int(best + texts.count)
                }
            }
            if JSON.object(c) != d {
                drafts[idx] = .object(c)
                changed = true
            }
        }
        return changed
    }

    /// Reconstruct a minimal unified-diff patch for one hunk (for git apply).
    public static func hunkPatch(path: String, hunk: JSON) throws -> Data {
        var out = [
            "--- a/\(path)",
            "+++ b/\(path)",
            "@@ -\(hunk["oldStart"]),\(hunk["oldCount"]) +\(hunk["newStart"]),\(hunk["newCount"]) @@",
        ]
        let prefixes = ["add": "+", "del": "-", "ctx": " "]
        for l in hunk["lines"].arrayValue ?? [] {
            guard let t = l["t"].stringValue, let prefix = prefixes[t] else {
                throw ServerError("bad hunk line")
            }
            out.append(prefix + (l["text"].stringValue ?? ""))
            if l["nne"].isTrue {
                out.append("\\ No newline at end of file")
            }
        }
        return Data((out.joined(separator: "\n") + "\n").utf8)
    }
}
