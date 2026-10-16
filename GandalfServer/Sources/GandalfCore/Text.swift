import Foundation

// Diffs and git output are byte-oriented: lines end at "\n" (so a "\r"
// before it stays on the line) and the diff marker is the first byte.

extension String {
    /// Every "\n"-separated piece, including a trailing empty one.
    var lines: [String] {
        utf8.split(separator: 0x0A, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
    }

    /// Newline-terminated output as a list of lines.
    var outputLines: [String] {
        var out = lines
        if out.last == "" { out.removeLast() }
        return out
    }

    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmingTrailingWhitespace: String {
        var scalars = unicodeScalars
        while let last = scalars.last, CharacterSet.whitespacesAndNewlines.contains(last) {
            scalars.removeLast()
        }
        return String(scalars)
    }

    var endsWithNewline: Bool { utf8.last == 0x0A }

    var firstByte: UInt8? { utf8.first }

    /// The string without its first byte (the diff marker column).
    var droppingFirstByte: String {
        String(decoding: utf8.dropFirst(), as: UTF8.self)
    }
}

extension Data {
    var decodedLossy: String { String(decoding: self, as: UTF8.self) }
}
