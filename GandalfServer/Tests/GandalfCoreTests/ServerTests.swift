import Foundation
import Testing
@testable import GandalfCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite(.serialized) struct ServerTests {
    func fetch(_ url: String, method: String = "GET", body: Data? = nil, headers: [String: String] = [:]) throws -> (Int, [String: String], Data) {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = method
        req.httpBody = body
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let sem = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable {
            var result: (Int, [String: String], Data)?
            var error: Error?
        }
        let box = Box()
        URLSession.shared.dataTask(with: req) { data, response, error in
            if let http = response as? HTTPURLResponse {
                var headers: [String: String] = [:]
                for (k, v) in http.allHeaderFields {
                    headers[String(describing: k).lowercased()] = String(describing: v)
                }
                box.result = (http.statusCode, headers, data ?? Data())
            }
            box.error = error
            sem.signal()
        }.resume()
        sem.wait()
        if let e = box.error { throw e }
        return box.result!
    }

    @Test func servesOverLoopbackAndProbesPorts() throws {
        let repo = try FixtureRepo()
        try repo.write("a.txt", "a\n")
        _ = try repo.commit("one")
        try repo.write("a.txt", "b\n")
        try repo.write("public/index.html", "<p>ui</p>")
        let router = Router(repo.config())
        let first = try #require(Server.bindingNextFree(router: router, from: 14633))
        defer { first.shutdown() }
        #expect(first.port == 14633)
        // The explicit-port form refuses a taken port; the probing form moves on.
        #expect(throws: Server.BindError.self) { try Server(router: router, port: 14633) }
        let second = try #require(Server.bindingNextFree(router: router, from: 14633))
        defer { second.shutdown() }
        #expect(second.port == 14634)

        let (status, headers, body) = try fetch("http://127.0.0.1:\(first.port)/")
        #expect(status == 200)
        #expect(headers["content-type"] == "text/html; charset=utf-8")
        #expect(headers["cache-control"] == "no-store")
        #expect(headers["content-length"] == "9")
        #expect(String(decoding: body, as: UTF8.self) == "<p>ui</p>")

        let (rs, rh, rb) = try fetch("http://127.0.0.1:\(first.port)/api/review?ws=1")
        #expect(rs == 200 && rh["content-type"] == "application/json; charset=utf-8")
        let review = try JSON.parse(rb)
        #expect(review["ignoreWhitespace"] == .bool(true))
        #expect(review["files"].arrayValue?.first?["path"] == .string("a.txt"))

        let (ps, _, pb) = try fetch(
            "http://127.0.0.1:\(first.port)/api/drafts", method: "POST",
            body: Data(#"{"drafts": [{"id": "x"}]}"#.utf8), headers: ["Content-Type": "application/json"]
        )
        #expect(ps == 200 && String(decoding: pb, as: UTF8.self) == #"{"count":1,"ok":true}"#)

        let (fs, _, fb) = try fetch("http://localhost:\(first.port)/api/status", headers: ["Origin": "http://evil.example"])
        #expect(fs == 403 && String(decoding: fb, as: UTF8.self) == #"{"error":"forbidden: cross-origin request"}"#)
        let (ns, _, _) = try fetch("http://127.0.0.1:\(first.port)/missing")
        #expect(ns == 404)
    }

    @Test func handlesConcurrentRequests() throws {
        let repo = try FixtureRepo()
        try repo.write("a.txt", "a\n")
        _ = try repo.commit("one")
        try repo.write("public/index.html", "ui")
        let server = try #require(Server.bindingNextFree(router: Router(repo.config()), from: 14700))
        defer { server.shutdown() }
        let group = DispatchGroup()
        final class Counter: @unchecked Sendable {
            var ok = 0
            let lock = NSLock()
        }
        let counter = Counter()
        for _ in 0..<12 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                if let (s, _, _) = try? self.fetch("http://127.0.0.1:\(server.port)/api/review"), s == 200 {
                    counter.lock.lock()
                    counter.ok += 1
                    counter.lock.unlock()
                }
            }
        }
        group.wait()
        #expect(counter.ok == 12)
    }
}
