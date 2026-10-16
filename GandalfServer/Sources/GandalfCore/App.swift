import Foundation

/// Command-line options, as the CLI target parses them.
public struct Options: Sendable {
    /// Repository to review (default: the git repo containing the cwd).
    public var repo: String?
    /// Ref to diff the working tree against.
    public var base = "HEAD"
    /// Where review state lives (default: <repo root>/.gandalf).
    public var stateDir: String?
    /// Port to bind (default: 4633, or the next free port after it).
    public var port: Int?
    /// Don't open the review UI in a browser on startup.
    public var noOpen = false

    public init() {}
}

public struct ExitError: Error, CustomStringConvertible {
    public let description: String
    public let code: Int32

    public init(_ description: String, code: Int32 = 1) {
        self.description = description
        self.code = code
    }
}

public enum App {
    public static let defaultPort = 4633

    /// Resolves the options into a configuration: the repository root, the
    /// state directory and the `public/` directory the UI is served from.
    public static func configure(_ options: Options, publicDir: String? = nil) throws -> ReviewConfig {
        let repo: String
        if let given = options.repo {
            repo = Paths.resolve(given)
            if !Paths.exists(Paths.join(repo, ".git")) {
                throw ExitError("error: \(repo) does not look like a git repository")
            }
        } else {
            do {
                let top = try Git.runText(FileManager.default.currentDirectoryPath, ["rev-parse", "--show-toplevel"])
                repo = Paths.resolve(top.trimmed)
            } catch let e as GitError {
                throw ExitError("error: not inside a git repository (\(e))")
            }
        }
        let stateRoot = options.stateDir.map { Paths.resolve($0) } ?? Paths.join(repo, stateDirName)
        guard let publicDir = publicDir ?? locatePublicDir() else {
            throw ExitError("error: cannot find the public/ directory next to the gandalf checkout")
        }
        return ReviewConfig(repo: repo, base: options.base, stateRoot: stateRoot, publicDir: publicDir)
    }

    /// The UI lives in `public/` at the root of the gandalf checkout; the
    /// binary sits somewhere under it (`GandalfServer/.build/...`), possibly
    /// reached through a symlink, so walk up from the real executable.
    public static func locatePublicDir() -> String? {
        var dir = Paths.parent(executablePath())
        while dir != "/" && !dir.isEmpty {
            let candidate = Paths.join(dir, "public")
            if Paths.isFile(Paths.join(candidate, "index.html")) {
                return candidate
            }
            dir = Paths.parent(dir)
        }
        return nil
    }

    static func executablePath() -> String {
        #if os(Linux)
        if let real = try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe") {
            return real
        }
        #endif
        if let url = Bundle.main.executableURL {
            return Paths.resolve(url.path)
        }
        return Paths.resolve(CommandLine.arguments[0])
    }

    /// Starts the server and blocks until it stops.
    public static func run(_ options: Options) throws {
        let cfg = try configure(options)
        let router = Router(cfg)
        let server: Server
        if let port = options.port {
            // An explicit port is a promise: fail loudly rather than move the URL.
            do {
                server = try Server(router: router, port: port)
            } catch {
                throw ExitError("error: cannot bind port \(port): \(error)")
            }
        } else {
            guard let bound = Server.bindingNextFree(router: router, from: defaultPort) else {
                throw ExitError("error: no free port in \(defaultPort)–\(defaultPort + 49); use --port")
            }
            server = bound
        }
        let url = "http://127.0.0.1:\(server.port)"
        let banner = "gandalf: reviewing \(cfg.repo) (base: \(cfg.base))\n"
            + "gandalf: state in   \(cfg.stateRoot)\n"
            + "gandalf: \(url)\n"
        FileHandle.standardOutput.write(Data(banner.utf8))
        if !options.noOpen {
            // The socket is bound, so the page can't beat the server. Failures
            // are silent and the printed URL is the fallback.
            openBrowser(url)
        }
        try server.serveForever()
    }

    static func openBrowser(_ url: String) {
        #if os(macOS)
        let opener = ["open", url]
        #else
        let opener = ["xdg-open", url]
        #endif
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = opener
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}
