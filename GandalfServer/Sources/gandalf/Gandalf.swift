import ArgumentParser
import Foundation
import GandalfCore

@main
struct Gandalf: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gandalf",
        abstract: "Gandalf — local review UI",
        version: version
    )

    @Option(help: "repository to review (default: the git repo containing the cwd)")
    var repo: String?

    @Option(help: "ref to diff the working tree against")
    var base = "HEAD"

    @Option(name: .customLong("state-dir"), help: "where review state lives (default: <repo root>/.gandalf)")
    var stateDir: String?

    @Option(help: "port to bind (default: 4633, or the next free port after it so parallel sessions just work)")
    var port: Int?

    @Flag(name: .customLong("no-open"), help: "don't open the review UI in a browser on startup")
    var noOpen = false

    @Flag(help: "log every request and git call to stderr, not just problems")
    var verbose = false

    func run() throws {
        var options = Options()
        options.repo = repo
        options.base = base
        options.stateDir = stateDir
        options.port = port
        options.noOpen = noOpen
        options.verbose = verbose
        do {
            try App.run(options)
        } catch let e as ExitError {
            FileHandle.standardError.write(Data((e.description + "\n").utf8))
            throw ExitCode(e.code)
        }
    }
}
