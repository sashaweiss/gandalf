import Foundation

/// A dynamic JSON value. Drafts and state files are JSON the client owns, so
/// the server keeps them as values rather than typed models. Serialization
/// sorts object keys, which keeps state files and responses deterministic.
public indirect enum JSON: Equatable, Sendable, CustomStringConvertible {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    public struct ParseError: Error, CustomStringConvertible {
        public let message: String
        public let offset: Int

        public var description: String { "invalid JSON: \(message) at offset \(offset)" }
    }

    // MARK: - Accessors

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var intValue: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d) where d == d.rounded() && abs(d) < 9.0e15: return Int(d)
        default: return nil
        }
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    /// True only for the JSON value `true`.
    public var isTrue: Bool { boolValue == true }

    public var arrayValue: [JSON]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var objectValue: [String: JSON]? {
        if case .object(let o) = self { return o }
        return nil
    }

    /// Member lookup on an object; `.null` for anything else or a missing key.
    public subscript(key: String) -> JSON {
        if case .object(let o) = self { return o[key] ?? .null }
        return .null
    }

    /// The value as it reads in a message: strings unquoted, scalars as
    /// written, containers serialized.
    public var description: String {
        switch self {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .string(let s): return s
        case .array, .object: return serialized()
        }
    }

    // MARK: - Serialization

    public func serialized(pretty: Bool = false) -> String {
        var out: [UInt8] = []
        out.reserveCapacity(1024)
        write(to: &out, pretty: pretty, depth: 0)
        return String(decoding: out, as: UTF8.self)
    }

    private func write(to out: inout [UInt8], pretty: Bool, depth: Int) {
        switch self {
        case .null: out.append(contentsOf: "null".utf8)
        case .bool(let b): out.append(contentsOf: (b ? "true" : "false").utf8)
        case .int(let i): out.append(contentsOf: String(i).utf8)
        case .double(let d): out.append(contentsOf: (d.isFinite ? String(d) : "null").utf8)
        case .string(let s): JSON.writeString(s, to: &out)
        case .array(let a):
            if a.isEmpty { out.append(contentsOf: "[]".utf8); return }
            out.append(UInt8(ascii: "["))
            for (i, v) in a.enumerated() {
                if i > 0 { out.append(UInt8(ascii: ",")) }
                JSON.newline(&out, pretty: pretty, depth: depth + 1)
                v.write(to: &out, pretty: pretty, depth: depth + 1)
            }
            JSON.newline(&out, pretty: pretty, depth: depth)
            out.append(UInt8(ascii: "]"))
        case .object(let o):
            if o.isEmpty { out.append(contentsOf: "{}".utf8); return }
            out.append(UInt8(ascii: "{"))
            for (i, key) in o.keys.sorted().enumerated() {
                if i > 0 { out.append(UInt8(ascii: ",")) }
                JSON.newline(&out, pretty: pretty, depth: depth + 1)
                JSON.writeString(key, to: &out)
                out.append(UInt8(ascii: ":"))
                if pretty { out.append(UInt8(ascii: " ")) }
                o[key]!.write(to: &out, pretty: pretty, depth: depth + 1)
            }
            JSON.newline(&out, pretty: pretty, depth: depth)
            out.append(UInt8(ascii: "}"))
        }
    }

    private static func newline(_ out: inout [UInt8], pretty: Bool, depth: Int) {
        guard pretty else { return }
        out.append(0x0A)
        out.append(contentsOf: repeatElement(UInt8(ascii: " "), count: 2 * depth))
    }

    private static let hex = Array("0123456789abcdef".utf8)

    private static func writeString(_ s: String, to out: inout [UInt8]) {
        out.append(UInt8(ascii: "\""))
        for b in s.utf8 {
            switch b {
            case UInt8(ascii: "\""): out.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "\"")])
            case UInt8(ascii: "\\"): out.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "\\")])
            case 0x0A: out.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "n")])
            case 0x0D: out.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "r")])
            case 0x09: out.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "t")])
            case 0..<0x20:
                out.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "u"), UInt8(ascii: "0"), UInt8(ascii: "0")])
                out.append(hex[Int(b >> 4)])
                out.append(hex[Int(b & 0xF)])
            default: out.append(b)
            }
        }
        out.append(UInt8(ascii: "\""))
    }

    // MARK: - Parsing

    public static func parse(_ data: Data) throws -> JSON {
        var parser = Parser(bytes: Array(data))
        return try parser.parseDocument()
    }

    public static func parse(_ text: String) throws -> JSON {
        var parser = Parser(bytes: Array(text.utf8))
        return try parser.parseDocument()
    }

    private struct Parser {
        let bytes: [UInt8]
        var i = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        mutating func parseDocument() throws -> JSON {
            skipWhitespace()
            let v = try parseValue()
            skipWhitespace()
            if i != bytes.count { throw error("trailing data") }
            return v
        }

        func error(_ message: String) -> ParseError {
            ParseError(message: message, offset: i)
        }

        mutating func skipWhitespace() {
            while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 }
        }

        mutating func parseValue() throws -> JSON {
            guard i < bytes.count else { throw error("expected a value") }
            switch bytes[i] {
            case UInt8(ascii: "{"): return try parseObject()
            case UInt8(ascii: "["): return try parseArray()
            case UInt8(ascii: "\""): return .string(try parseString())
            case UInt8(ascii: "t"): try expect("true"); return .bool(true)
            case UInt8(ascii: "f"): try expect("false"); return .bool(false)
            case UInt8(ascii: "n"): try expect("null"); return .null
            default: return try parseNumber()
            }
        }

        mutating func expect(_ word: String) throws {
            let w = Array(word.utf8)
            guard i + w.count <= bytes.count, Array(bytes[i..<i + w.count]) == w else {
                throw error("expected a value")
            }
            i += w.count
        }

        mutating func parseObject() throws -> JSON {
            i += 1
            var obj: [String: JSON] = [:]
            skipWhitespace()
            if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object(obj) }
            while true {
                skipWhitespace()
                guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else {
                    throw error("expected a property name")
                }
                let key = try parseString()
                skipWhitespace()
                guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else {
                    throw error("expected ':'")
                }
                i += 1
                skipWhitespace()
                obj[key] = try parseValue()
                skipWhitespace()
                guard i < bytes.count else { throw error("expected ',' or '}'") }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(obj) }
                throw error("expected ',' or '}'")
            }
        }

        mutating func parseArray() throws -> JSON {
            i += 1
            var arr: [JSON] = []
            skipWhitespace()
            if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array(arr) }
            while true {
                skipWhitespace()
                arr.append(try parseValue())
                skipWhitespace()
                guard i < bytes.count else { throw error("expected ',' or ']'") }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(arr) }
                throw error("expected ',' or ']'")
            }
        }

        mutating func parseString() throws -> String {
            i += 1
            var scalars = String.UnicodeScalarView()
            var raw: [UInt8] = []
            func flushRaw() {
                if !raw.isEmpty {
                    scalars.append(contentsOf: String(decoding: raw, as: UTF8.self).unicodeScalars)
                    raw.removeAll()
                }
            }
            while true {
                guard i < bytes.count else { throw error("unterminated string") }
                let b = bytes[i]
                if b == UInt8(ascii: "\"") { i += 1; break }
                if b == UInt8(ascii: "\\") {
                    flushRaw()
                    i += 1
                    guard i < bytes.count else { throw error("unterminated string") }
                    let e = bytes[i]
                    i += 1
                    switch e {
                    case UInt8(ascii: "\""): scalars.append("\"")
                    case UInt8(ascii: "\\"): scalars.append("\\")
                    case UInt8(ascii: "/"): scalars.append("/")
                    case UInt8(ascii: "b"): scalars.append("\u{08}")
                    case UInt8(ascii: "f"): scalars.append("\u{0C}")
                    case UInt8(ascii: "n"): scalars.append("\n")
                    case UInt8(ascii: "r"): scalars.append("\r")
                    case UInt8(ascii: "t"): scalars.append("\t")
                    case UInt8(ascii: "u"):
                        var code = try parseHex4()
                        if (0xD800...0xDBFF).contains(code),
                           i + 1 < bytes.count, bytes[i] == UInt8(ascii: "\\"),
                           bytes[i + 1] == UInt8(ascii: "u") {
                            let save = i
                            i += 2
                            let low = try parseHex4()
                            if (0xDC00...0xDFFF).contains(low) {
                                code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                            } else {
                                i = save
                            }
                        }
                        scalars.append(Unicode.Scalar(code) ?? "\u{FFFD}")
                    default: throw error("invalid escape")
                    }
                    continue
                }
                if b < 0x20 { throw error("control character in string") }
                raw.append(b)
                i += 1
            }
            flushRaw()
            return String(scalars)
        }

        mutating func parseHex4() throws -> UInt32 {
            guard i + 4 <= bytes.count,
                  let v = UInt32(String(decoding: bytes[i..<i + 4], as: UTF8.self), radix: 16)
            else { throw error("invalid \\u escape") }
            i += 4
            return v
        }

        mutating func parseNumber() throws -> JSON {
            let start = i
            if i < bytes.count, bytes[i] == UInt8(ascii: "-") { i += 1 }
            var isFloat = false
            while i < bytes.count {
                let b = bytes[i]
                if b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9") { i += 1; continue }
                if b == UInt8(ascii: ".") || b == UInt8(ascii: "e") || b == UInt8(ascii: "E")
                    || b == UInt8(ascii: "+") || b == UInt8(ascii: "-") {
                    isFloat = true
                    i += 1
                    continue
                }
                break
            }
            let text = String(decoding: bytes[start..<i], as: UTF8.self)
            if !isFloat, let v = Int(text) { return .int(v) }
            guard let d = Double(text) else { throw error("expected a value") }
            return .double(d)
        }
    }
}
