import Foundation
import Subprocess

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
    ) async throws -> Data {
        let started = DispatchTime.now()
        let arguments = ["--no-optional-locks", "-C", repo] + args
        var overrides: [Environment.Key: String?] = [:]
        for (key, value) in env ?? [:] {
            if let key = Environment.Key(rawValue: key) {
                overrides[key] = value
            }
        }
        let environment = Environment.inherit.updating(overrides)
        let input = input ?? Data()
        let result: Output
        do {
            let execution = try await Subprocess.run(
                .name("git"),
                arguments: Arguments(arguments),
                environment: environment,
                input: .data(input),
                output: .data(limit: .max),
                error: .data(limit: .max)
            )
            let status: Int32
            switch execution.terminationStatus {
            case .exited(let code):
                status = code
            case .signaled(let signal):
                status = 128 + signal
            }
            result = Output(
                status: status, stdout: execution.standardOutput,
                stderr: execution.standardError
            )
        } catch {
            Logger.error("git \(args.joined(separator: " ")): \(error)")
            throw ServerError("cannot run git: \(error)")
        }
        let elapsed =
            (DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds)
            / 1_000_000
        // Some calls fail by design (e.g. probing a ref), so a failure alone
        // isn't worth more than debug; slowness is.
        let line = "git \(args.joined(separator: " ")) → \(result.status), "
            + "\(elapsed) ms"
        if elapsed >= 1000 {
            Logger.warn(line)
        } else {
            Logger.debug(line)
        }
        if result.status != 0 {
            let stderr = String(decoding: result.stderr, as: UTF8.self).trimmed
            throw GitError(stderr.isEmpty ? "git \(args.first ?? "") failed" : stderr)
        }
        return result.stdout
    }

    private struct Output: Sendable {
        let status: Int32
        let stdout: Data
        let stderr: Data
    }

    public static func runText(
        _ repo: String, _ args: [String], env: [String: String]? = nil
    ) async throws -> String {
        String(decoding: try await run(repo, args, env: env), as: UTF8.self)
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
    public static func revParse(_ repo: String, _ ref: String) async -> String? {
        try? await runText(repo, ["rev-parse", "--verify", "-q", "\(ref)^{commit}"]).trimmed
    }

    public static func isAncestor(_ repo: String, _ sha: String, of: String = "HEAD") async -> Bool {
        (try? await run(repo, ["merge-base", "--is-ancestor", sha, of])) != nil
    }
}
