import Foundation

public enum Markdown {
    /// The agent-facing form of a submitted review: plain markdown whose
    /// preamble carries everything needed to act on it, so the reviewer
    /// never has to explain this tool to an agent. Works both pasted into a
    /// chat and read from .gandalf/pending-review.md.
    public static func render(_ snapshot: JSON) -> String {
        let baseRef = snapshot["base"].stringValue ?? "HEAD"
        let baseDesc = baseRef == "HEAD" ? "the last commit (HEAD)" : "the base ref `\(baseRef)`"
        let comments = snapshot["comments"].arrayValue ?? []
        let commits = snapshot["commits"]
        let intro = "Review r\(snapshot["revision"]) of the changes in this repository "
            + "(branch `\(snapshot["branch"])`, HEAD \(snapshot["head"]), "
            + "submitted \(snapshot["submittedAt"]))"
        if comments.isEmpty {
            // A commentless review is an approval: the reviewer checkpointed
            // the changes as good. Say so plainly — an agent reading the
            // handoff file should know there is nothing to act on.
            return "# Code review — approved, nothing to address\n"
                + "\n"
                + "\(intro) was finished with no comments: the reviewer approved "
                + "these changes as-is. No action is needed.\n"
        }
        let onCommits = comments.contains { commitOf($0) != nil }
        var lines = [
            "# Code review — please address each comment",
            "",
            "\(intro).",
            "",
            "How to read the comments:",
            "",
            "- \"Line N\" refers to the file as it exists in the working tree right now"
                + (onCommits ? ", except under a \"Commit\" heading." : "."),
            "- Comments marked \"on deleted code\" are about removed lines; those line "
                + "numbers refer to the file as of \(baseDesc), unless noted otherwise.",
            "- Each comment quotes the lines it targets (`+`/`-`/space = added/removed/"
                + "unchanged). If line numbers have drifted since submission, locate the "
                + "quoted code instead.",
            "- Comments marked \"detached\" quote code that has since changed; apply "
                + "their intent to the closest current code.",
            "- A \"File comment\" applies to its whole file; an \"Overall\" section "
                + "applies to the entire change.",
        ]
        if onCommits {
            lines += [
                "- Comments under a \"Commit\" heading were left on that single commit. "
                    + "Their line numbers refer to the file as of that commit (or its parent, "
                    + "for deleted lines). The code may have changed since: address them in "
                    + "the current code, and don't rewrite history unless asked.",
                "- A commit marked \"no longer in history\" was rewritten (e.g. by a "
                    + "rebase); locate the quoted code instead.",
            ]
        }
        lines.append("")
        let overall = comments.filter { $0["reviewLevel"].isTrue }
        if !overall.isEmpty {
            lines.append("## Overall")
            lines.append("")
            for c in overall {
                lines.append(textOf(c))
                lines.append("")
            }
        }
        // Replies render as additional paragraphs of their thread root's entry.
        var replies: [String: [JSON]] = [:]
        for c in comments {
            if let parent = c["parentId"].stringValue {
                replies[parent, default: []].append(c)
            }
        }
        for key in replies.keys {
            replies[key]!.sort { $0["createdAt"].description < $1["createdAt"].description }
        }

        func textOf(_ c: JSON) -> String {
            (c["text"].stringValue ?? "").trimmingTrailingWhitespace
        }

        func entryText(_ c: JSON) -> String {
            let texts = [textOf(c)] + (replies[c["id"].description] ?? []).map { textOf($0) }
            return texts.filter { !$0.isEmpty }.joined(separator: "\n\n")
        }

        func fileSections(_ byFile: [String: [JSON]], heading: String) {
            for path in byFile.keys.sorted() {
                lines.append("\(heading) \(path)")
                lines.append("")
                // File-level comments first, then by line.
                let sorted = byFile[path]!.sorted {
                    ($0["startLine"].intValue ?? 0) < ($1["startLine"].intValue ?? 0)
                }
                for c in sorted {
                    if c["fileLevel"].isTrue {
                        lines.append("**File comment**")
                        lines.append("")
                        lines.append(entryText(c))
                        lines.append("")
                        continue
                    }
                    let start = c["startLine"]
                    let end = c["endLine"]
                    let rng = start == end ? "Line \(start)" : "Lines \(start)–\(end)"
                    var notes: [String] = []
                    if c["side"].stringValue == "old" {
                        // A baseline marks a comment made in the "changes since
                        // review rN" view: its deleted lines came from that
                        // review's snapshot, not from the base ref.
                        if let baseline = c["baseline"].intValue {
                            notes.append("on code removed since review r\(baseline)")
                        } else if let base = c["base"].stringValue, !base.isEmpty,
                                  base != snapshot["baseSha"].stringValue, commitOf(c) == nil {
                            notes.append("on deleted code, as of commit \(base.prefix(7))")
                        } else {
                            notes.append("on deleted code")
                        }
                    }
                    if c["detached"].isTrue {
                        notes.append("detached")
                    }
                    let suffix = notes.isEmpty ? "" : " (\(notes.joined(separator: ", ")))"
                    lines.append("**\(rng)\(suffix)**")
                    lines.append("")
                    let excerpt = c["excerpt"].arrayValue ?? []
                    for ex in excerpt {
                        lines.append("> \(ex)")
                    }
                    if !excerpt.isEmpty {
                        lines.append("")
                    }
                    lines.append(entryText(c))
                    lines.append("")
                }
            }
        }

        var worktree: [String: [JSON]] = [:]
        var byCommit: [String: [String: [JSON]]] = [:]
        for c in comments {
            if c["reviewLevel"].isTrue || c["parentId"].stringValue != nil { continue }
            let file = c["file"].stringValue ?? "(unknown file)"
            if let sha = commitOf(c) {
                byCommit[sha, default: [:]][file, default: []].append(c)
            } else {
                worktree[file, default: []].append(c)
            }
        }
        fileSections(worktree, heading: "##")
        // Commits in history order; rewritten ones last.
        let order = byCommit.keys.sorted { a, b in
            let ka = (commits[a]["gone"].isTrue, commits[a]["time"].intValue ?? 0, a)
            let kb = (commits[b]["gone"].isTrue, commits[b]["time"].intValue ?? 0, b)
            if ka.0 != kb.0 { return !ka.0 }
            if ka.1 != kb.1 { return ka.1 < kb.1 }
            return ka.2 < kb.2
        }
        for sha in order {
            let meta = commits[sha]
            var title = "## Commit `\(meta["short"].stringValue ?? String(sha.prefix(7)))`"
            if let subject = meta["subject"].stringValue, !subject.isEmpty {
                title += " — \(subject)"
            }
            if meta["gone"].isTrue {
                title += " (no longer in history)"
            }
            lines.append(title)
            lines.append("")
            fileSections(byCommit[sha]!, heading: "###")
        }
        return lines.joined(separator: "\n").trimmingTrailingWhitespace + "\n"
    }

    static func commitOf(_ c: JSON) -> String? {
        guard let sha = c["commit"].stringValue, !sha.isEmpty else { return nil }
        return sha
    }
}
