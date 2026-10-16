import Foundation
import Testing
@testable import GandalfCore

@Suite struct MarkdownTests {
    @Test(arguments: ["full", "empty", "head"])
    func rendersSnapshots(name: String) throws {
        let snapshot = try Fixtures.json("snapshot-\(name).json")
        let expected = try Fixtures.text("snapshot-\(name).md")
        #expect(Markdown.render(snapshot) == expected)
    }

    @Test func approvalMentionsNoAction() throws {
        let md = Markdown.render(try Fixtures.json("snapshot-empty.json"))
        #expect(md.hasPrefix("# Code review — approved, nothing to address\n"))
        #expect(md.contains("No action is needed."))
    }

    @Test func fileSectionsAreSorted() throws {
        var snap = try Fixtures.json("snapshot-empty.json").objectValue!
        func comment(_ file: String) -> JSON {
            .object([
                "id": .string(file), "file": .string(file), "side": .string("new"),
                "startLine": .int(1), "endLine": .int(1), "excerpt": .array([]), "text": .string("t"),
            ])
        }
        snap["comments"] = .array([comment("b.swift"), comment("B.swift"), comment("a/x.swift"), comment("a.swift")])
        let md = Markdown.render(.object(snap))
        let order = md.components(separatedBy: "\n").filter { $0.hasPrefix("## ") }
        #expect(order == ["## B.swift", "## a.swift", "## a/x.swift", "## b.swift"])
    }
}
