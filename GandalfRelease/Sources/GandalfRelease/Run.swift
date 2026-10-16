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

/// Runs `command`, showing its output as it runs. Throws if it fails. Its
/// first element is the executable, as `executable(command:)` finds it.
func runShowingOutput(
    _ command: [String],
    directory: URL? = nil,
) async throws {
    let result = try await Subprocess.run(
        executable(command: command),
        arguments: Arguments(Array(command.dropFirst())),
        workingDirectory: directory.map { FilePath($0.path) },
        output: .currentStandardOutput,
        error: .currentStandardError,
    )
    guard result.terminationStatus.isSuccess else {
        throw CommandFailedError(
            command: command,
            status: result.terminationStatus,
        )
    }
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
