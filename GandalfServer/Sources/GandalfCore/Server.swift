import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

/// Loopback-only HTTP/1.1 server in front of a `Router`. Requests run off the
/// event loop because the review logic blocks on git, but one at a time: the
/// only client is a single page, and concurrent Process launches proved
/// unreliable (intermittent EBADF from posix_spawn).
public final class Server: Sendable {
    public let router: Router
    public let port: Int
    private let group: MultiThreadedEventLoopGroup
    private let pool: NIOThreadPool
    private let channel: Channel

    public struct BindError: Error, CustomStringConvertible {
        public let description: String
    }

    /// Binds 127.0.0.1:`port`; throws if that port is taken.
    public init(router: Router, port: Int) throws {
        self.router = router
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let pool = NIOThreadPool(numberOfThreads: 1)
        pool.start()
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline(withErrorHandling: true)
                    try channel.pipeline.syncOperations.addHandler(HTTPHandler(router: router, pool: pool))
                }
            }
        do {
            channel = try bootstrap.bind(host: "127.0.0.1", port: port).wait()
        } catch {
            try? pool.syncShutdownGracefully()
            try? group.syncShutdownGracefully()
            throw BindError(description: "\(error)")
        }
        self.group = group
        self.pool = pool
        self.port = channel.localAddress?.port ?? port
    }

    /// Binds `preferred`, or the next free port after it (up to 50 tries).
    public static func bindingNextFree(router: Router, from preferred: Int) -> Server? {
        for candidate in preferred..<(preferred + 50) {
            if let server = try? Server(router: router, port: candidate) {
                return server
            }
        }
        return nil
    }

    /// Blocks until the listening socket closes.
    public func serveForever() throws {
        try channel.closeFuture.wait()
    }

    public func shutdown() {
        try? channel.close().wait()
        try? pool.syncShutdownGracefully()
        try? group.syncShutdownGracefully()
    }
}

private final class HTTPHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let router: Router
    private let pool: NIOThreadPool
    private var head: HTTPRequestHead?
    private var body = Data()
    /// Requests read but not yet answered on this connection.
    private var pending = 0

    init(router: Router, pool: NIOThreadPool) {
        self.router = router
        self.pool = pool
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            self.head = head
            body = Data()
        case .body(var buffer):
            if let bytes = buffer.readBytes(length: buffer.readableBytes) {
                body.append(contentsOf: bytes)
            }
        case .end:
            guard let head else { return }
            self.head = nil
            var headers: [String: String] = [:]
            for (name, value) in head.headers {
                headers[name.lowercased()] = value
            }
            let request = Request(
                method: head.method.rawValue, uri: head.uri, headers: headers, body: body
            )
            body = Data()
            let keepAlive = head.isKeepAlive
            let version = head.version
            let router = self.router
            let bound = NIOLoopBound((self, context), eventLoop: context.eventLoop)
            let summary = "\(request.method) \(request.uri)"
            let received = DispatchTime.now()
            pending += 1
            pool.runIfActive(eventLoop: context.eventLoop) {
                let started = DispatchTime.now()
                let response = router.handle(request)
                let queued = RequestLog.milliseconds(from: received, to: started)
                let handled = RequestLog.milliseconds(from: started, to: .now())
                RequestLog.log(
                    summary, response: response,
                    timing: "\(handled) ms, \(queued) ms queued"
                )
                return response
            }.whenComplete { result in
                let response: Response
                switch result {
                case .success(let r):
                    response = r
                case .failure(let e):
                    Logger.error("\(summary): not handled: \(e)")
                    response = .error("\(e)", status: 500)
                }
                let (handler, context) = bound.value
                handler.pending -= 1
                handler.write(
                    response, summary: summary, version: version,
                    keepAlive: keepAlive, context: context
                )
            }
        }
    }

    private func write(
        _ response: Response, summary: String, version: HTTPVersion,
        keepAlive: Bool, context: ChannelHandlerContext
    ) {
        guard context.channel.isActive else {
            Logger.warn("\(summary): connection closed before reply")
            return
        }
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: response.contentType)
        headers.add(name: "Content-Length", value: String(response.body.count))
        headers.add(name: "Cache-Control", value: "no-store")
        if !keepAlive {
            headers.add(name: "Connection", value: "close")
        }
        let head = HTTPResponseHead(
            version: version, status: HTTPResponseStatus(statusCode: response.status), headers: headers
        )
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        var buffer = context.channel.allocator.buffer(capacity: response.body.count)
        buffer.writeBytes(response.body)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        let promise = context.eventLoop.makePromise(of: Void.self)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: promise)
        promise.futureResult.whenFailure { error in
            Logger.warn("\(summary): reply not sent: \(error)")
        }
        if !keepAlive {
            let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
            promise.futureResult.whenComplete { _ in bound.value.close(promise: nil) }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        if pending > 0 {
            Logger.warn(
                "connection closed with \(pending) request(s) unanswered"
            )
        }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        // Closing without a reply is what a browser reports as an empty
        // response, so say why.
        Logger.warn("closing connection after error: \(error)")
        context.close(promise: nil)
    }
}

/// One line per request, with how long it waited for the (single) pool
/// thread and how long it took.
private enum RequestLog {
    static func log(
        _ summary: String, response: Response, timing: String
    ) {
        let line = "\(summary) → \(response.status), "
            + "\(response.body.count) bytes, \(timing)"
        switch response.status {
        case 500...:
            let body = String(decoding: response.body.prefix(500), as: UTF8.self)
            Logger.warn("\(line): \(body)")
        default:
            Logger.debug(line)
        }
    }

    static func milliseconds(
        from start: DispatchTime, to end: DispatchTime
    ) -> UInt64 {
        (end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    }
}
