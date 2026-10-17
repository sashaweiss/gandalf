import Foundation
import Testing
@testable import GandalfCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite(.serialized) struct ServerTests {
    func fetch(
        _ url: String, method: String = "GET", body: Data? = nil,
        headers: [String: String] = [:]
    ) async throws -> (Int, [String: String], Data) {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = method
        req.httpBody = body
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await URLSession.shared.data(for: req)
        let http = try #require(response as? HTTPURLResponse)
        var fields: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            fields[String(describing: k).lowercased()] = String(describing: v)
        }
        return (http.statusCode, fields, data)
    }

    /// Runs `body`, then shuts `servers` down whether or not it threw.
    func shuttingDown(
        _ servers: [Server], _ body: () async throws -> Void
    ) async throws {
        do {
            try await body()
        } catch {
            for server in servers { await server.shutdown() }
            throw error
        }
        for server in servers { await server.shutdown() }
    }

    @Test func servesOverLoopbackAndProbesPorts() async throws {
        let repo = try await FixtureRepo()
        try repo.write("a.txt", "a\n")
        _ = try await repo.commit("one")
        try repo.write("a.txt", "b\n")
        let router = Router(repo.config())
        let first = try #require(await Server.bindingNextFree(router: router, from: 14633))
        let second = try #require(await Server.bindingNextFree(router: router, from: 14633))
        try await shuttingDown([first, second]) {
            #expect(first.port == 14633)
            #expect(second.port == 14634)
            // The explicit-port form refuses a taken port; the probing form
            // moves on.
            await #expect(throws: Server.BindError.self) {
                try await Server(router: router, port: 14633)
            }

            let (status, headers, body) = try await fetch("http://127.0.0.1:\(first.port)/")
            #expect(status == 200)
            #expect(headers["content-type"] == "text/html; charset=utf-8")
            #expect(headers["cache-control"] == "no-store")
            #expect(headers["content-length"] == String(uiFiles["index.html"]!.count))
            #expect(body == uiFiles["index.html"])

            let (rs, rh, rb) = try await fetch("http://127.0.0.1:\(first.port)/api/review?ws=1")
            #expect(rs == 200 && rh["content-type"] == "application/json; charset=utf-8")
            let review = try JSON.parse(rb)
            #expect(review["ignoreWhitespace"] == .bool(true))
            #expect(review["files"].arrayValue?.first?["path"] == .string("a.txt"))

            let (ps, _, pb) = try await fetch(
                "http://127.0.0.1:\(first.port)/api/drafts", method: "POST",
                body: Data(#"{"drafts": [{"id": "x"}]}"#.utf8), headers: ["Content-Type": "application/json"]
            )
            #expect(ps == 200 && String(decoding: pb, as: UTF8.self) == #"{"count":1,"ok":true}"#)

            let (fs, _, fb) = try await fetch(
                "http://localhost:\(first.port)/api/status", headers: ["Origin": "http://evil.example"]
            )
            #expect(fs == 403 && String(decoding: fb, as: UTF8.self) == #"{"error":"forbidden: cross-origin request"}"#)
            let (ns, _, _) = try await fetch("http://127.0.0.1:\(first.port)/missing")
            #expect(ns == 404)
        }
    }

    @Test func handlesConcurrentRequests() async throws {
        let repo = try await FixtureRepo()
        try repo.write("a.txt", "a\n")
        _ = try await repo.commit("one")
        let server = try #require(
            await Server.bindingNextFree(router: Router(repo.config()), from: 14700)
        )
        try await shuttingDown([server]) {
            let ok = await withTaskGroup(of: Bool.self) { group in
                for _ in 0..<12 {
                    group.addTask {
                        let result = try? await fetch("http://127.0.0.1:\(server.port)/api/review")
                        return result?.0 == 200
                    }
                }
                var ok = 0
                for await success in group where success {
                    ok += 1
                }
                return ok
            }
            #expect(ok == 12)
        }
    }
}
