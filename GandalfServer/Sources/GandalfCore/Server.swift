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
            pool.runIfActive(eventLoop: context.eventLoop) {
                router.handle(request)
            }.whenComplete { result in
                let response: Response
                switch result {
                case .success(let r): response = r
                case .failure(let e): response = .error("\(e)", status: 500)
                }
                let (handler, context) = bound.value
                handler.write(response, version: version, keepAlive: keepAlive, context: context)
            }
        }
    }

    private func write(_ response: Response, version: HTTPVersion, keepAlive: Bool, context: ChannelHandlerContext) {
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
        if !keepAlive {
            let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
            promise.futureResult.whenComplete { _ in bound.value.close(promise: nil) }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}
