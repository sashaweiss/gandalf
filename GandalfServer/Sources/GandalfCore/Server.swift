import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

/// Loopback-only HTTP/1.1 server in front of a `Router`. Each connection is
/// a task that answers its requests in order; connections run concurrently.
public final class Server: Sendable {
    typealias Connection =
        NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>

    public let router: Router
    public let port: Int
    private let channel: any Channel
    /// Accepts connections until `shutdown`.
    private let serving: Task<Void, Never>

    public struct BindError: Error, CustomStringConvertible {
        public let description: String
    }

    /// Binds 127.0.0.1:`port` and starts serving; throws if that port is
    /// taken.
    public init(router: Router, port: Int) async throws {
        let listener: NIOAsyncChannel<Connection, Never>
        do {
            listener = try await ServerBootstrap(
                group: .singletonMultiThreadedEventLoopGroup
            )
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .bind(host: "127.0.0.1", port: port) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations
                        .configureHTTPServerPipeline(withErrorHandling: true)
                    return try Connection(
                        wrappingChannelSynchronously: channel
                    )
                }
            }
        } catch {
            throw BindError(description: "\(error)")
        }
        self.router = router
        self.port = listener.channel.localAddress?.port ?? port
        channel = listener.channel
        serving = Task {
            do {
                try await listener.executeThenClose { inbound in
                    try await withThrowingDiscardingTaskGroup { group in
                        for try await connection in inbound {
                            group.addTask {
                                await Self.serve(connection, router: router)
                            }
                        }
                    }
                }
            } catch is CancellationError {
                // shutdown()
            } catch {
                Logger.error("stopped accepting connections: \(error)")
            }
        }
    }

    /// Binds `preferred`, or the next free port after it (up to 50 tries).
    public static func bindingNextFree(
        router: Router, from preferred: Int
    ) async -> Server? {
        for candidate in preferred..<(preferred + 50) {
            if let server = try? await Server(router: router, port: candidate) {
                return server
            }
        }
        return nil
    }

    /// Returns once the server stops.
    public func serve() async {
        await serving.value
    }

    public func shutdown() async {
        serving.cancel()
        try? await channel.close()
    }

    private static func serve(_ connection: Connection, router: Router) async {
        do {
            try await connection.executeThenClose { inbound, outbound in
                var head: HTTPRequestHead?
                var body = Data()
                for try await part in inbound {
                    switch part {
                    case .head(let next):
                        head = next
                        body = Data()
                    case .body(var buffer):
                        if let bytes = buffer.readBytes(
                            length: buffer.readableBytes
                        ) {
                            body.append(contentsOf: bytes)
                        }
                    case .end:
                        guard let request = head else { continue }
                        head = nil
                        let keepAlive = try await answer(
                            request, body: body, router: router,
                            outbound: outbound
                        )
                        body = Data()
                        if !keepAlive {
                            return
                        }
                    }
                }
            }
        } catch is CancellationError {
            // shutdown() closing an idle keep-alive connection.
        } catch {
            // Closing without a reply is what a browser reports as an empty
            // response, so say why.
            Logger.warn("closed connection after error: \(error)")
        }
    }

    /// Handles one request and writes its response; returns whether the
    /// connection stays open.
    private static func answer(
        _ head: HTTPRequestHead, body: Data, router: Router,
        outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>
    ) async throws -> Bool {
        var headers: [String: String] = [:]
        for (name, value) in head.headers {
            headers[name.lowercased()] = value
        }
        let request = Request(
            method: head.method.rawValue, uri: head.uri, headers: headers,
            body: body
        )
        let summary = "\(request.method) \(request.uri)"
        let started = DispatchTime.now()
        let response = await router.handle(request)
        RequestLog.log(summary, response: response, started: started)

        var responseHeaders = HTTPHeaders()
        responseHeaders.add(name: "Content-Type", value: response.contentType)
        responseHeaders.add(
            name: "Content-Length", value: String(response.body.count)
        )
        responseHeaders.add(name: "Cache-Control", value: "no-store")
        if !head.isKeepAlive {
            responseHeaders.add(name: "Connection", value: "close")
        }
        let responseHead = HTTPResponseHead(
            version: head.version,
            status: HTTPResponseStatus(statusCode: response.status),
            headers: responseHeaders
        )
        do {
            // One write, so the client can't see a complete response (and
            // close) before the last part is written.
            try await outbound.write(contentsOf: [
                .head(responseHead),
                .body(.byteBuffer(ByteBuffer(bytes: response.body))),
                .end(nil),
            ])
        } catch {
            Logger.warn("\(summary): reply not sent: \(error)")
            return false
        }
        return head.isKeepAlive
    }
}

/// One line per request: routine ones only when verbose, failures always.
private enum RequestLog {
    static func log(
        _ summary: String, response: Response, started: DispatchTime
    ) {
        let elapsed =
            (DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds)
            / 1_000_000
        let line = "\(summary) → \(response.status), "
            + "\(response.body.count) bytes, \(elapsed) ms"
        switch response.status {
        case 500...:
            let body = String(decoding: response.body.prefix(500), as: UTF8.self)
            Logger.warn("\(line): \(body)")
        default:
            Logger.debug(line)
        }
    }
}
