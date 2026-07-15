import Foundation

/// A resolved selection inside the reviewed text: exact UTF-16 offsets (NSRange
/// coordinates, so AppKit selections map 1:1), 1-based line/column endpoints for labels,
/// and the selected text verbatim — the ground truth an agent greps for when revising.
public struct ProseSelection: Equatable, Sendable {
    public let startOffset: Int
    /// Exclusive, like `NSMaxRange`.
    public let endOffset: Int
    public let startLine: Int
    public let startColumn: Int
    public let endLine: Int
    public let endColumn: Int
    public let text: String

    public init(
        startOffset: Int,
        endOffset: Int,
        startLine: Int,
        startColumn: Int,
        endLine: Int,
        endColumn: Int,
        text: String
    ) {
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.startLine = startLine
        self.startColumn = startColumn
        self.endLine = endLine
        self.endColumn = endColumn
        self.text = text
    }

    public var lineLabel: String {
        startLine == endLine ? "line \(startLine)" : "lines \(startLine)–\(endLine)"
    }
}

/// Pure text geometry for prose reviews. All offsets are UTF-16 code units so they can be
/// used directly as `NSRange` locations against the same string in AppKit.
public enum ProseGeometry {
    /// UTF-16 offsets at which each line starts. Always contains at least offset 0.
    public static func lineStarts(of text: String) -> [Int] {
        let ns = text as NSString
        var starts: [Int] = [0]
        var location = 0
        while location < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(lineRange)
            if location < ns.length {
                starts.append(location)
            }
        }
        return starts
    }

    /// 1-based line/column of a UTF-16 offset. Column counts UTF-16 units from the line
    /// start — stable against the same string the selection was made in.
    public static func position(ofUTF16Offset offset: Int, lineStarts: [Int]) -> (line: Int, column: Int) {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= offset {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return (line: low + 1, column: offset - lineStarts[low] + 1)
    }

    /// Resolves an AppKit selection range against the text: clamps to bounds, rejects
    /// empty/whitespace-only selections, and returns offsets + line/column endpoints + the
    /// selected text verbatim.
    public static func selection(in text: String, utf16Range: NSRange) -> ProseSelection? {
        let ns = text as NSString
        guard ns.length > 0, utf16Range.location != NSNotFound else { return nil }
        let start = max(0, min(utf16Range.location, ns.length))
        let end = max(start, min(NSMaxRange(utf16Range), ns.length))
        guard end > start else { return nil }
        // Never split a surrogate pair or composed character: expand to full characters.
        let composedStart = ns.rangeOfComposedCharacterSequence(at: start).location
        let composedEndRange = ns.rangeOfComposedCharacterSequence(at: end - 1)
        let composedEnd = NSMaxRange(composedEndRange)
        let range = NSRange(location: composedStart, length: composedEnd - composedStart)
        let selected = ns.substring(with: range)
        guard !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let starts = lineStarts(of: text)
        let startPosition = position(ofUTF16Offset: range.location, lineStarts: starts)
        let endPosition = position(ofUTF16Offset: NSMaxRange(range) - 1, lineStarts: starts)
        return ProseSelection(
            startOffset: range.location,
            endOffset: NSMaxRange(range),
            startLine: startPosition.line,
            startColumn: startPosition.column,
            endLine: endPosition.line,
            endColumn: endPosition.column,
            text: selected
        )
    }
}

/// One prose review comment: the exact selected characters of the reviewed reply plus what
/// the reviewer said about them. Offsets anchor the highlight; the quoted text is included
/// verbatim in the exported prompt because quotes, not offsets, are what an agent can
/// reliably locate after the fact.
public struct ProseComment: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let startOffset: Int
    public let endOffset: Int
    public let startLine: Int
    public let startColumn: Int
    public let endLine: Int
    public let endColumn: Int
    public let quotedText: String
    public var body: String
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        selection: ProseSelection,
        body: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.startOffset = selection.startOffset
        self.endOffset = selection.endOffset
        self.startLine = selection.startLine
        self.startColumn = selection.startColumn
        self.endLine = selection.endLine
        self.endColumn = selection.endColumn
        self.quotedText = selection.text
        self.body = body
        self.createdAt = createdAt
    }

    public var lineLabel: String {
        startLine == endLine ? "line \(startLine)" : "lines \(startLine)–\(endLine)"
    }

    /// The highlight range in NSRange coordinates, clamped to the given text length so a
    /// comment loaded against edited content can never paint out of bounds.
    public func utf16Range(clampedToLength length: Int) -> NSRange? {
        let start = max(0, min(startOffset, length))
        let end = max(start, min(endOffset, length))
        guard end > start else { return nil }
        return NSRange(location: start, length: end - start)
    }
}

/// Renders the whole review as one prompt-ready block: each comment quotes the exact
/// selected text (fenced, verbatim) followed by what the reviewer wants changed. Mirrors
/// DiffReview's `ReviewCommentFormatter`, reworded for prose.
public enum ProseReviewFormatter {
    public static func format(comments: [ProseComment], title: String? = nil) -> String {
        guard !comments.isEmpty else { return "" }
        let subject = title.map { " to \"\($0)\"" } ?? ""
        var blocks: [String] = [
            "Revise the reply\(subject) per the following \(comments.count == 1 ? "review comment" : "\(comments.count) review comments"). Each quotes the exact passage it targets:",
        ]
        for (index, comment) in comments.enumerated() {
            blocks.append("""
            \(index + 1). (\(comment.lineLabel))
            ```
            \(comment.quotedText)
            ```
            \(comment.body)
            """)
        }
        return blocks.joined(separator: "\n\n")
    }
}

/// Everything a review persists: enough for the app to restore it, and for an agent to
/// collect it programmatically (`sourcePath` + verbatim quotes) without the clipboard.
public struct ProseReviewFile: Codable, Equatable, Sendable {
    public var contentKey: String
    public var sourcePath: String?
    public var title: String?
    public var savedAt: Date
    public var comments: [ProseComment]

    public init(contentKey: String, sourcePath: String?, title: String?, savedAt: Date, comments: [ProseComment]) {
        self.contentKey = contentKey
        self.sourcePath = sourcePath
        self.title = title
        self.savedAt = savedAt
        self.comments = comments
    }
}

/// Disk-backed store for a prose review, keyed by the reviewed text itself (content hash):
/// reopening the same reply — from any path — restores its comments. Every save also
/// updates a `last-review.json` pointer so an agent can collect the latest review without
/// knowing the key.
public struct ProseReviewStore: Equatable {
    public let contentKey: String
    private let fileURL: URL
    private let pointerURL: URL
    private let sourcePath: String?

    public init(contentText: String, sourcePath: String?, storageRoot: URL? = nil) {
        self.contentKey = Self.contentKey(for: contentText)
        self.sourcePath = sourcePath
        let root = storageRoot ?? Self.defaultStorageRoot()
        self.fileURL = root
            .appendingPathComponent("Reviews", isDirectory: true)
            .appendingPathComponent(contentKey, isDirectory: false)
            .appendingPathExtension("json")
        self.pointerURL = root.appendingPathComponent("last-review.json", isDirectory: false)
    }

    public func load() -> [ProseComment] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode(ProseReviewFile.self, from: data))?.comments ?? []
    }

    public func save(_ comments: [ProseComment], title: String?) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let review = ProseReviewFile(
                contentKey: contentKey,
                sourcePath: sourcePath,
                title: title,
                savedAt: Date(),
                comments: comments
            )
            try encoder.encode(review).write(to: fileURL, options: [.atomic])
            let pointer = ProseReviewPointer(
                reviewFile: fileURL.path,
                sourcePath: sourcePath,
                contentKey: contentKey,
                savedAt: review.savedAt
            )
            try encoder.encode(pointer).write(to: pointerURL, options: [.atomic])
        } catch {
            #if DEBUG
            fputs("Margin review persistence failed: \(error)\n", stderr)
            #endif
        }
    }

    /// FNV-1a, matching the idiom of DiffReview's `ReviewCommentStore` scope IDs.
    public static func contentKey(for text: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    public static func defaultStorageRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Margin", isDirectory: true)
    }
}

/// The `last-review.json` payload: where the newest review lives and what it reviewed.
public struct ProseReviewPointer: Codable, Equatable, Sendable {
    public var reviewFile: String
    public var sourcePath: String?
    public var contentKey: String
    public var savedAt: Date

    public init(reviewFile: String, sourcePath: String?, contentKey: String, savedAt: Date) {
        self.reviewFile = reviewFile
        self.sourcePath = sourcePath
        self.contentKey = contentKey
        self.savedAt = savedAt
    }
}
