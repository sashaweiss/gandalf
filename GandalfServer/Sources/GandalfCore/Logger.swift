import Foundation

/// Logging, as timestamped lines on stderr. Everything goes through here, so
/// the backend can change without touching call sites.
public enum Logger {
    /// Whether debug lines (routine traffic) are shown. Set once, before the
    /// server starts.
    nonisolated(unsafe) public static var verbose = false

    /// Routine traffic: requests, git calls. Shown only when verbose.
    public static func debug(_ message: String) {
        if verbose {
            write("", message)
        }
    }

    public static func info(_ message: String) {
        write("", message)
    }

    public static func warn(_ message: String) {
        write("warning: ", message)
    }

    public static func error(_ message: String) {
        write("error: ", message)
    }

    private static func write(_ prefix: String, _ message: String) {
        let line = "\(timestamp()) gandalf: \(prefix)\(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    /// Local wall-clock time, to the millisecond.
    private static func timestamp() -> String {
        var now = timeval()
        gettimeofday(&now, nil)
        var seconds = now.tv_sec
        var local = tm()
        localtime_r(&seconds, &local)
        return String(
            format: "%02d:%02d:%02d.%03d",
            local.tm_hour, local.tm_min, local.tm_sec,
            Int32(now.tv_usec / 1000)
        )
    }
}
