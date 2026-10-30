import Foundation
import Subprocess
import System

/// A command that exited unsuccessfully.
struct CommandFailedError: Error, CustomStringConvertible {
    var command: [String]
    var status: TerminationStatus

    var description: String {
        "`\(command.joined(separator: " "))` failed: \(status)"
    }
}

/// Runs `command`, and throws if it fails. Its output is shown as it runs if
/// `verbose`, or else hidden behind progress dots and shown only if it fails.
/// Its first element is the executable, as `executable(command:)` finds it.
func runCommand(
    _ command: [String],
    directory: URL? = nil,
    verbose: Bool,
) async throws {
    let executable = executable(command: command)
    let arguments = Arguments(Array(command.dropFirst()))
    let workingDirectory = directory.map { FilePath($0.path) }
    let status: TerminationStatus
    if verbose {
        status = try await Subprocess.run(
            executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            output: .currentStandardOutput,
            error: .currentStandardError,
        ).terminationStatus
    } else {
        let result = try await withProgressDots {
            try await Subprocess.run(
                executable,
                arguments: arguments,
                workingDirectory: workingDirectory,
                output: .string(limit: 1 << 24),
                error: .string(limit: 1 << 24),
            )
        }
        status = result.terminationStatus
        if !status.isSuccess {
            print(result.standardOutput, terminator: "")
            print(result.standardError, terminator: "")
        }
    }
    guard status.isSuccess else {
        throw CommandFailedError(command: command, status: status)
    }
}

/// Runs `body`, printing a dot for each second it takes.
func withProgressDots<T>(_ body: () async throws -> T) async throws -> T {
    let dots = Task {
        var count = 0
        while (try? await Task.sleep(for: .seconds(1))) != nil {
            print(".", terminator: "")
            fflush(nil)
            count += 1
        }
        return count
    }
    let result: Result<T, any Error>
    do {
        result = .success(try await body())
    } catch {
        result = .failure(error)
    }
    dots.cancel()
    if await dots.value > 0 {
        print()
    }
    return try result.get()
}

/// Runs `command`, and returns its output, trimmed. Its errors are shown as it
/// runs. Throws if it fails. Its first element is the executable, as
/// `executable(command:)` finds it.
func outputOf(command: [String], directory: URL? = nil) async throws
    -> String
{
    let result = try await Subprocess.run(
        executable(command: command),
        arguments: Arguments(Array(command.dropFirst())),
        workingDirectory: directory.map { FilePath($0.path) },
        output: .string(limit: 4096),
        error: .currentStandardError,
    )
    guard result.terminationStatus.isSuccess else {
        throw CommandFailedError(
            command: command,
            status: result.terminationStatus,
        )
    }
    return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// The executable for `command`: the one at `command[0]`, if that's a path
/// (e.g., gandalf's own build), or else the one named `command[0]` on `PATH`.
private func executable(command: [String]) -> Executable {
    if command[0].contains("/") {
        return .path(FilePath(command[0]))
    }
    return .name(command[0])
}

/// Prints the name of the step about to run.
func log(_ name: String) {
    print("==> \(name)")
}
