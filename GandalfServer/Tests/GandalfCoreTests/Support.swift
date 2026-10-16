import Foundation
import Testing
@testable import GandalfCore

enum Fixtures {
    static func url(_ name: String) -> URL {
        Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!
    }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: url(name))
    }

    static func text(_ name: String) throws -> String {
        String(decoding: try data(name), as: UTF8.self)
    }

    static func json(_ name: String) throws -> JSON {
        try JSON.parse(try data(name))
    }
}

/// A throwaway directory, removed when the value goes away.
final class TempDir {
    let path: String

    init(prefix: String = "gandalf-test-") throws {
        path = try Paths.temporaryDirectory(prefix: prefix)
    }

    deinit {
        Paths.removeTree(path)
    }

    func write(_ rel: String, _ text: String) throws {
        let p = Paths.join(path, rel)
        try Paths.mkdirs(Paths.parent(p))
        try Data(text.utf8).write(to: URL(fileURLWithPath: p))
    }

    func read(_ rel: String) throws -> String {
        try Paths.readText(Paths.join(path, rel))
    }

    func exists(_ rel: String) -> Bool {
        Paths.exists(Paths.join(path, rel))
    }
}

/// A scripted git repository for end-to-end router tests.
final class FixtureRepo {
    let dir: TempDir
    var path: String { dir.path }

    init() throws {
        dir = try TempDir(prefix: "gandalf-repo-")
        try git(["init", "-q", "-b", "main"])
        try git(["config", "user.email", "t@example.com"])
        try git(["config", "user.name", "Test"])
        try git(["config", "commit.gpgsign", "false"])
    }

    @discardableResult
    func git(_ args: [String]) throws -> String {
        try Git.runText(path, args, env: [
            "GIT_AUTHOR_DATE": "2026-01-01T00:00:00Z",
            "GIT_COMMITTER_DATE": "2026-01-01T00:00:00Z",
        ])
    }

    func write(_ rel: String, _ text: String) throws {
        try dir.write(rel, text)
    }

    func commit(_ message: String, paths: [String]? = nil) throws -> String {
        try git(paths.map { ["add", "--"] + $0 } ?? ["add", "-A"])
        try git(["commit", "-q", "-m", message] + (paths.map { ["--only", "--"] + $0 } ?? []))
        return try git(["rev-parse", "HEAD"]).trimmed
    }

    func config(base: String = "HEAD") -> ReviewConfig {
        ReviewConfig(
            repo: Paths.resolve(path), base: base,
            stateRoot: Paths.join(Paths.resolve(path), stateDirName)
        )
    }
}

extension Router {
    func get(_ uri: String, headers: [String: String] = [:]) -> Response {
        var h = ["host": "127.0.0.1:4633"]
        for (k, v) in headers { h[k] = v }
        return handle(Request(method: "GET", uri: uri, headers: h))
    }

    func post(_ uri: String, _ body: JSON, headers: [String: String] = [:]) -> Response {
        var h = ["host": "127.0.0.1:4633"]
        for (k, v) in headers { h[k] = v }
        return handle(Request(method: "POST", uri: uri, headers: h, body: Data(body.serialized().utf8)))
    }
}

extension Response {
    var json: JSON {
        (try? JSON.parse(body)) ?? .null
    }

    var text: String {
        String(decoding: body, as: UTF8.self)
    }
}
