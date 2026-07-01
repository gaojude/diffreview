import Foundation

/// One immediate child of a directory. Pure value type, no UI dependencies.
public struct DirectoryEntry: Equatable, Hashable {
    public let url: URL
    public let name: String
    public let isDirectory: Bool

    public init(url: URL, name: String, isDirectory: Bool) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
    }
}

/// Foundation-only file-system helpers. Deliberately free of SwiftUI/AppKit so the
/// logic can be unit-checked by `MyIDESelfTest` under Command Line Tools (no XCTest).
public enum FileSystem {

    /// Largest file we will load into the read-only viewer. Anything bigger shows a
    /// placeholder instead of being read into memory.
    public static let maxFileSize: Int = 5 * 1024 * 1024 // 5 MB

    /// Bytes sampled from the head of a file for the binary/text heuristic.
    public static let binarySampleSize: Int = 8192

    // MARK: - Directory listing

    /// Lists the immediate children of `url`, directories first then case-insensitive by name.
    /// Skips `.DS_Store`. Returns `[]` on error (e.g. permission denied) so callers never throw
    /// mid-tree. Resource keys are prefetched in the single enumeration call for speed.
    public static func listDirectory(_ url: URL, includeHidden: Bool = true) -> [DirectoryEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .nameKey, .isSymbolicLinkKey]
        let options: FileManager.DirectoryEnumerationOptions = includeHidden ? [] : [.skipsHiddenFiles]
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: options
        ) else {
            return []
        }

        var entries: [DirectoryEntry] = []
        entries.reserveCapacity(children.count)
        for child in children {
            let name = child.lastPathComponent
            if name == ".DS_Store" { continue }
            entries.append(DirectoryEntry(url: child, name: name, isDirectory: isDirectory(child)))
        }
        return sortEntries(entries)
    }

    /// Whether `url` is a directory, *following symlinks* — a symlink pointing at a folder is
    /// treated as a folder (so it gets a disclosure triangle and can be expanded).
    /// `.isDirectoryKey` alone does not follow links. The resource values are already
    /// prefetched by the enclosing enumeration, so the non-symlink path adds no extra I/O.
    private static func isDirectory(_ url: URL) -> Bool {
        let vals = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        if vals?.isSymbolicLink == true {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
                return isDir.boolValue
            }
        }
        return vals?.isDirectory ?? false
    }

    /// Directories before files, then case-insensitive lexical order. Pure — testable without I/O.
    public static func sortEntries(_ entries: [DirectoryEntry]) -> [DirectoryEntry] {
        entries.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory && !b.isDirectory }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    // MARK: - File content

    /// Heuristic for whether `data` is binary (and therefore not worth showing as text).
    /// Scans the *entire* buffer for a NUL byte — a strong binary signal — so a file that is
    /// text-like in its first few KB but binary later is still caught. The scan is a cheap
    /// bytewise pass and we would decode the whole buffer anyway if it were text. UTF-8
    /// invalidity is only trusted for a fully-sampled small buffer, to avoid false positives
    /// from a multibyte character split across the `sampleSize` boundary.
    public static func isProbablyBinary(_ data: Data, sampleSize: Int = binarySampleSize) -> Bool {
        if data.contains(0) { return true }
        if data.count <= sampleSize, String(data: data, encoding: .utf8) == nil { return true }
        return false
    }

    /// Decodes file bytes for display: UTF-8 when valid, otherwise a lossy decode that
    /// substitutes U+FFFD for invalid sequences (so non-UTF-8 text still renders).
    public static func decodeText(_ data: Data) -> String {
        if let s = String(data: data, encoding: .utf8) { return s }
        return String(decoding: data, as: UTF8.self)
    }

    /// Outcome of loading a file for the read-only viewer.
    public enum FileLoad: Equatable, Sendable {
        case text(String)
        case tooLarge(bytes: Int)
        case binary
        case isDirectory
        case unreadable(String)
    }

    /// Reads a file for display, applying the size cap and binary check. This lives in
    /// `MyIDECore` (not main-actor isolated) specifically so callers can run it off the main
    /// thread — every `stat`/read here must stay off the UI thread. The directory check is
    /// included so callers don't need a separate on-main `stat`.
    public static func loadForDisplay(_ url: URL, maxSize: Int = maxFileSize) -> FileLoad {
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        } catch {
            return .unreadable(error.localizedDescription)
        }
        if values.isDirectory == true { return .isDirectory }
        if let size = values.fileSize, size > maxSize { return .tooLarge(bytes: size) }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return .unreadable("Can’t read file.")
        }
        if isProbablyBinary(data) { return .binary }
        return .text(decodeText(data))
    }

    // MARK: - Root resolution

    /// Resolves the directory to open from process arguments.
    /// - Parameters:
    ///   - arguments: full `CommandLine.arguments` (argv[0] is the program path).
    ///   - currentDirectory: fallback + base for resolving relative paths (e.g. ".").
    /// - Returns: an absolute, symlink-resolved directory URL, or `nil` if the path is missing
    ///   or is not a directory.
    public static func resolveRootDirectory(arguments: [String], currentDirectory: String) -> URL? {
        let pathArg = arguments.dropFirst().first { !$0.hasPrefix("-") }
        let raw = pathArg ?? currentDirectory
        let expanded = (raw as NSString).expandingTildeInPath
        let base = URL(fileURLWithPath: currentDirectory, isDirectory: true)
        let url = URL(fileURLWithPath: expanded, relativeTo: base)
            .standardizedFileURL
            .resolvingSymlinksInPath()

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        return url
    }
}
