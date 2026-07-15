import Foundation

/// A reply attached to a review comment after the fact — typically a coding agent answering
/// the reviewer's question, pushing back, or reporting what it did. Arrives through
/// `diffreview respond <id> <text>` rather than the app's UI.
public struct ReviewCommentReply: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let body: String
    public let createdAt: Date

    public init(id: UUID = UUID(), body: String, createdAt: Date = Date()) {
        self.id = id
        self.body = body
        self.createdAt = createdAt
    }
}

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
    /// 1-based column of the first selected character within `startLine`. Present (with
    /// `endColumn`) when the comment targets the exact selected characters rather than
    /// whole lines; absent on comments made before precision existed.
    public let startColumn: Int?
    /// 1-based column of the last selected character within `endLine` (inclusive).
    public let endColumn: Int?
    /// The selected code, verbatim — the ground truth an agent greps for when applying
    /// changes. For precise comments this is the exact selection, which can start and end
    /// mid-line.
    public let codeText: String
    public var body: String
    public let createdAt: Date
    /// Replies delivered from outside the app (see `ReviewCommentReply`), oldest first.
    public var replies: [ReviewCommentReply]

    public init(
        id: UUID = UUID(),
        filePath: String,
        origin: Origin,
        startLine: Int,
        endLine: Int,
        startColumn: Int? = nil,
        endColumn: Int? = nil,
        codeText: String,
        body: String,
        createdAt: Date = Date(),
        replies: [ReviewCommentReply] = []
    ) {
        self.id = id
        self.filePath = filePath
        self.origin = origin
        self.startLine = startLine
        self.endLine = endLine
        self.startColumn = startColumn
        self.endColumn = endColumn
        self.codeText = codeText
        self.body = body
        self.createdAt = createdAt
        self.replies = replies
    }

    /// Manual decoding only so comments persisted before replies existed still load
    /// (their JSON has no `replies` key). Encoding stays synthesized.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.filePath = try container.decode(String.self, forKey: .filePath)
        self.origin = try container.decode(Origin.self, forKey: .origin)
        self.startLine = try container.decode(Int.self, forKey: .startLine)
        self.endLine = try container.decode(Int.self, forKey: .endLine)
        self.startColumn = try container.decodeIfPresent(Int.self, forKey: .startColumn)
        self.endColumn = try container.decodeIfPresent(Int.self, forKey: .endColumn)
        self.codeText = try container.decode(String.self, forKey: .codeText)
        self.body = try container.decode(String.self, forKey: .body)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.replies = try container.decodeIfPresent([ReviewCommentReply].self, forKey: .replies) ?? []
    }

    /// Whether the comment targets exact characters (both columns known) or whole lines.
    public var isPrecise: Bool { startColumn != nil && endColumn != nil }

    /// The first UUID group, lowercased — the handle an agent quotes back to
    /// `diffreview respond`. Eight hex characters: short enough to type, and collisions
    /// within one review are resolved by prefix matching (see `ReviewCommentReplyService`).
    public var shortID: String {
        String(id.uuidString.prefix(8)).lowercased()
    }

    public var lineLabel: String {
        guard isPrecise, let startColumn, let endColumn else {
            return startLine == endLine ? "line \(startLine)" : "lines \(startLine)–\(endLine)"
        }
        return startLine == endLine
            ? "line \(startLine), chars \(startColumn)–\(endColumn)"
            : "lines \(startLine):\(startColumn)–\(endLine):\(endColumn)"
    }
}

/// Renders all comments as one prompt-ready block for the clipboard, so a coding agent can
/// apply every requested change in one pass. The selected code is included verbatim (fenced)
/// because snippets, not line numbers, are what an agent can reliably locate. Each item
/// carries the comment's short id and the block ends with instructions for replying through
/// `diffreview respond`, so the review is a two-way channel: the reviewer's asks go out, the
/// agent's answers come back under the same comment.
public enum ReviewCommentFormatter {
    public static func format(comments: [ReviewComment]) -> String {
        guard !comments.isEmpty else { return "" }
        var blocks: [String] = [
            "Apply the following \(comments.count == 1 ? "code review comment" : "\(comments.count) code review comments"):",
        ]
        for (index, comment) in comments.enumerated() {
            let scope = comment.origin == .diff ? "diff \(comment.lineLabel)" : comment.lineLabel
            blocks.append("""
            \(index + 1). [\(comment.shortID)] \(comment.filePath) (\(scope))
            ```
            \(comment.codeText)
            ```
            \(comment.body)
            """)
        }
        blocks.append("""
        For each comment, reply with what you did, or with your answer when the comment asks \
        a question. Reply using the bracketed id:

          diffreview respond \(comments[0].shortID) "your reply"

        Replies appear under the comment in the DiffReview window.
        """)
        return blocks.joined(separator: "\n\n")
    }
}

public extension Notification.Name {
    /// Posted through `DistributedNotificationCenter` after an external process (the
    /// `diffreview respond` CLI) mutates a persisted review, so a running DiffReview
    /// reloads its comment list and shows the new reply.
    static let reviewCommentsChangedExternally =
        Notification.Name("com.judegao.diffreview.review-comments-changed")
}

/// Applies a reply arriving from the CLI to the persisted review that contains the target
/// comment. The CLI runs in a separate process with only a comment id in hand, so the
/// service scans every persisted review under the storage root for a comment whose UUID
/// starts with the given prefix (case-insensitive; surrounding brackets tolerated because
/// agents paste the id as it appears in the copied block).
public enum ReviewCommentReplyService {
    public enum Outcome: Equatable {
        case applied(comment: ReviewComment, storeFileURL: URL)
        case notFound
        /// More than one comment matches the prefix — the caller should re-run with more
        /// characters. Carries the full ids of the contenders.
        case ambiguous([String])
        case emptyReply
        case writeFailed(String)
    }

    public static func applyReply(
        idPrefix rawPrefix: String,
        body rawBody: String,
        storageRoot: URL? = nil
    ) -> Outcome {
        let prefix = rawPrefix
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
        let body = rawBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return .emptyReply }
        guard !prefix.isEmpty else { return .notFound }

        let root = storageRoot ?? ReviewCommentStore.defaultStorageRoot()
        let fileManager = FileManager.default
        let storeFiles = ((try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        )) ?? []).filter { $0.pathExtension == "json" }

        struct Match {
            let fileURL: URL
            var comments: [ReviewComment]
            let index: Int
        }
        var matches: [Match] = []
        for fileURL in storeFiles {
            guard let data = try? Data(contentsOf: fileURL),
                  let comments = try? JSONDecoder().decode([ReviewComment].self, from: data) else {
                continue
            }
            for (index, comment) in comments.enumerated()
            where comment.id.uuidString.lowercased().hasPrefix(prefix) {
                matches.append(Match(fileURL: fileURL, comments: comments, index: index))
            }
        }

        guard var match = matches.first else { return .notFound }
        guard matches.count == 1 else {
            return .ambiguous(matches.map { $0.comments[$0.index].id.uuidString.lowercased() })
        }

        match.comments[match.index].replies.append(ReviewCommentReply(body: body))
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(match.comments)
            try data.write(to: match.fileURL, options: [.atomic])
        } catch {
            return .writeFailed(String(describing: error))
        }
        return .applied(comment: match.comments[match.index], storeFileURL: match.fileURL)
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

    /// Public so the CLI reply path (`ReviewCommentReplyService`) can scan the same
    /// directory the app persists into.
    public static func defaultStorageRoot() -> URL {
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
