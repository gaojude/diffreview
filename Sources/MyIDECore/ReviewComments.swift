import Foundation

/// One review comment: a few selected lines of code plus what the reviewer said about them.
/// The comment remembers enough to jump back to the exact code it was made on — the file's
/// display path, which view it was made in (diff vs. source file), and the line range in that
/// view's coordinates (patch-relative for diff comments, real file lines for source comments).
public struct ReviewComment: Codable, Equatable, Identifiable, Sendable {
    public enum Origin: String, Codable, Sendable {
        /// Made on the combined branch diff; lines are patch-relative within the file's section.
        case diff
        /// Made on a real file (Explorer); lines are actual file lines.
        case source
    }

    public let id: UUID
    /// Path relative to the opened root.
    public let filePath: String
    public let origin: Origin
    public let startLine: Int
    public let endLine: Int
    /// The selected code, verbatim — the ground truth an agent greps for when applying changes.
    public let codeText: String
    public var body: String
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        filePath: String,
        origin: Origin,
        startLine: Int,
        endLine: Int,
        codeText: String,
        body: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.filePath = filePath
        self.origin = origin
        self.startLine = startLine
        self.endLine = endLine
        self.codeText = codeText
        self.body = body
        self.createdAt = createdAt
    }

    public var lineLabel: String {
        startLine == endLine ? "line \(startLine)" : "lines \(startLine)–\(endLine)"
    }
}

/// Renders all comments as one prompt-ready block for the clipboard, so a coding agent can
/// apply every requested change in one pass. The selected code is included verbatim (fenced)
/// because snippets, not line numbers, are what an agent can reliably locate.
public enum ReviewCommentFormatter {
    public static func format(comments: [ReviewComment]) -> String {
        guard !comments.isEmpty else { return "" }
        var blocks: [String] = [
            "Apply the following \(comments.count == 1 ? "code review comment" : "\(comments.count) code review comments"):",
        ]
        for (index, comment) in comments.enumerated() {
            let scope = comment.origin == .diff ? "diff \(comment.lineLabel)" : comment.lineLabel
            blocks.append("""
            \(index + 1). \(comment.filePath) (\(scope))
            ```
            \(comment.codeText)
            ```
            \(comment.body)
            """)
        }
        return blocks.joined(separator: "\n\n")
    }
}

/// Disk-backed store for review comments, keyed by repo root + branch (same scoping as
/// `ChangeSetViewStateStore`, separate directory) so a review survives app restarts.
public struct ReviewCommentStore: Equatable {
    public let id: String
    private let fileURL: URL

    public init(rootURL: URL, branchName: String, storageRoot: URL? = nil) {
        let resolvedRoot = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let scope = "\(resolvedRoot.path)#\(branchName)"
        self.id = Self.stableHexID(for: scope)

        let baseURL = storageRoot ?? Self.defaultStorageRoot()
        self.fileURL = baseURL
            .appendingPathComponent(id, isDirectory: false)
            .appendingPathExtension("json")
    }

    public func load() -> [ReviewComment] {
        guard let data = try? Data(contentsOf: fileURL) else {
            return []
        }
        return (try? JSONDecoder().decode([ReviewComment].self, from: data)) ?? []
    }

    public func save(_ comments: [ReviewComment]) {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(comments)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            #if DEBUG
            fputs("MyIDE review comment persistence failed: \(error)\n", stderr)
            #endif
        }
    }

    private static func defaultStorageRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("MyIDE/ReviewComments", isDirectory: true)
    }

    private static func stableHexID(for text: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
