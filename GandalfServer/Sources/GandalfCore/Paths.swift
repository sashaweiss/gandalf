import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// File-system helpers with `pathlib`-like semantics, on plain string paths.
enum Paths {
    static var fm: FileManager { .default }

    static func join(_ base: String, _ rel: String) -> String {
        if rel.hasPrefix("/") { return rel }
        if base.hasSuffix("/") { return base + rel }
        return base + "/" + rel
    }

    static func name(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    static func parent(_ path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }

    /// `Path.resolve()`: absolute, symlinks followed, `.`/`..` collapsed, and
    /// a non-existent tail kept as-is.
    static func resolve(_ path: String) -> String {
        var abs = path
        if !abs.hasPrefix("/") { abs = join(fm.currentDirectoryPath, abs) }
        if let real = realpath(abs, nil) {
            defer { free(real) }
            return String(cString: real)
        }
        // Resolve the longest existing prefix, then append the rest lexically.
        let components = (abs as NSString).pathComponents.filter { $0 != "/" }
        var resolved = "/"
        var i = 0
        while i < components.count {
            let candidate = join(resolved, components[i])
            guard let real = realpath(candidate, nil) else { break }
            resolved = String(cString: real)
            free(real)
            i += 1
        }
        var out = (resolved as NSString).pathComponents.filter { $0 != "/" }
        for c in components[i...] {
            if c == "." { continue }
            if c == ".." { if !out.isEmpty { out.removeLast() }; continue }
            out.append(c)
        }
        return "/" + out.joined(separator: "/")
    }

    static func isInside(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    static func exists(_ path: String) -> Bool { fm.fileExists(atPath: path) }

    static func isFile(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue
    }

    static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    struct Stat: Equatable {
        let size: Int
        let mtimeNs: Int
    }

    /// `os.stat` for the two fields the server uses; nil on any error.
    static func fileStat(_ path: String) -> Stat? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        #if os(Linux)
        let ns = Int(st.st_mtim.tv_sec) * 1_000_000_000 + Int(st.st_mtim.tv_nsec)
        #else
        let ns = Int(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int(st.st_mtimespec.tv_nsec)
        #endif
        return Stat(size: Int(st.st_size), mtimeNs: ns)
    }

    static func readData(_ path: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: path))
    }

    static func readText(_ path: String) throws -> String {
        try readData(path).decodedLossy
    }

    static func mkdirs(_ path: String) throws {
        try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    /// `write_text_atomic`: tmp file beside the target, then rename.
    static func writeTextAtomic(_ path: String, _ text: String) throws {
        try mkdirs(parent(path))
        let tmp = path + ".tmp"
        try Data(text.utf8).write(to: URL(fileURLWithPath: tmp))
        guard rename(tmp, path) == 0 else {
            throw ServerError("cannot replace \(path): \(String(cString: strerror(errno)))")
        }
    }

    static func removeTree(_ path: String) {
        try? fm.removeItem(atPath: path)
    }

    static func unlink(_ path: String) {
        if exists(path) { try? fm.removeItem(atPath: path) }
    }

    /// Directory entries in Python's `sorted(iterdir())` order.
    static func listDirectory(_ path: String) -> [String] {
        guard let names = try? fm.contentsOfDirectory(atPath: path) else { return [] }
        return names.sorted().map { join(path, $0) }
    }

    static func temporaryDirectory(prefix: String) throws -> String {
        let base = NSTemporaryDirectory()
        let path = join(base, prefix + UUID().uuidString.lowercased().prefix(8))
        try mkdirs(path)
        return path
    }
}
