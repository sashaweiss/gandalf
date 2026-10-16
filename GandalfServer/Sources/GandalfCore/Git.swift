import Foundation

public struct GitError: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// The requested view can't be shown (e.g. its snapshot is gone).
public struct ViewError: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// Any other failure surfaced to the UI as a 500 with its message.
public struct ServerError: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

public enum Git {
    /// Every git call goes through here: read-only by default thanks to
    /// `--no-optional-locks`, so a read-only `.git` mount works.
    @discardableResult
    public static func run(
        _ repo: String, _ args: [String], input: Data? = nil, env: [String: String]? = nil
    ) throws -> Data {
        let result = try Subprocess.run(
            executable: "git",
            arguments: ["--no-optional-locks", "-C", repo] + args,
            input: input,
            extraEnvironment: env
        )
        if result.status != 0 {
            let stderr = String(decoding: result.stderr, as: UTF8.self).trimmed
            throw GitError(stderr.isEmpty ? "git \(args.first ?? "") failed" : stderr)
        }
        return result.stdout
    }

    public static func runText(
        _ repo: String, _ args: [String], env: [String: String]? = nil
    ) throws -> String {
        String(decoding: try run(repo, args, env: env), as: UTF8.self)
    }

    /// Guards anything client-supplied before it reaches git's argv.
    public static func isSha(_ s: String?) -> Bool {
        guard let s, (4...64).contains(s.utf8.count) else { return false }
        return s.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }

    public static func isSha(_ value: JSON) -> Bool {
        isSha(value.stringValue)
    }

    /// Full object name of a commit, or nil.
    public static func revParse(_ repo: String, _ ref: String) -> String? {
        try? runText(repo, ["rev-parse", "--verify", "-q", "\(ref)^{commit}"]).trimmed
    }

    public static func isAncestor(_ repo: String, _ sha: String, of: String = "HEAD") -> Bool {
        (try? run(repo, ["merge-base", "--is-ancestor", sha, of])) != nil
    }
}

// MARK: - Subprocess

enum Subprocess {
    struct Result {
        let status: Int32
        let stdout: Data
        let stderr: Data
    }

    static func run(
        executable: String, arguments: [String], input: Data? = nil,
        extraEnvironment: [String: String]? = nil
    ) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
        if let extraEnvironment {
            var env = ProcessInfo.processInfo.environment
            for (k, v) in extraEnvironment { env[k] = v }
            process.environment = env
        }
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe
        do {
            try process.run()
        } catch {
            throw ServerError("cannot run \(executable): \(error)")
        }
        // Drain stdout on its own thread so a chatty process can't deadlock
        // against a full stderr pipe (or vice versa). Only the descriptor
        // crosses into the thread; Pipe itself is not Sendable.
        let stdoutBox = DataBox()
        let stdoutFd = stdoutPipe.fileHandleForReading.fileDescriptor
        let reader = Thread {
            stdoutBox.data = FileHandle(fileDescriptor: stdoutFd, closeOnDealloc: false).readDataToEndOfFile()
            stdoutBox.done.signal()
        }
        reader.start()
        if let input, !input.isEmpty {
            stdinPipe.fileHandleForWriting.write(input)
        }
        try? stdinPipe.fileHandleForWriting.close()
        let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        stdoutBox.done.wait()
        process.waitUntilExit()
        return Result(status: process.terminationStatus, stdout: stdoutBox.data, stderr: stderr)
    }

    private final class DataBox: @unchecked Sendable {
        var data = Data()
        let done = DispatchSemaphore(value: 0)
    }
}
