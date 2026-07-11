import Foundation

/// The branch change set as an editor-style side-by-side diff: two parallel texts with the
/// same number of rows, old version on the left, new version on the right. Deletions occupy a
/// left row with a blank filler on the right; additions the reverse; context lines appear on
/// both sides. Equal row counts are what make the two panes scroll in exact lockstep.
///
/// Rows carry real file line numbers (`rightFileLines` for the new version), so
/// go-to-definition and comments on the right side resolve directly against files on disk —
/// no patch-coordinate math. Pure value type, exercised by `MyIDESelfTest`.
public struct SideBySideDocument: Equatable, Sendable {
    public enum RowKind: Equatable, Sendable {
        case fileHeader
        case hunkBreak   // the "···" row between hunks
        case context
        case addition    // right side has new code (left is filler)
        case deletion    // left side has removed code (right is filler)
        case filler      // blank slot keeping this side aligned with the other
        case placeholder // message body (binary / too large / error)
        case blank       // separator between file sections
    }

    public struct Section: Equatable, Sendable {
        public let file: GitChangedFile
        /// 1-based first row of the header block (`headerRowCount` empty rows that the UI
        /// covers with a real header control).
        public let headerLine: Int
        /// Last row belonging to this section (inclusive of the trailing separator).
        public let endLine: Int
        public let isCollapsed: Bool
        public let isPlaceholder: Bool
        /// highlight.js language for the file, resolved once at build time.
        public let language: String?
        /// Added / removed line counts for the header control's `+N −M` stats.
        public let additions: Int
        public let deletions: Int
        /// Diff line count hidden while collapsed.
        public let hiddenLineCount: Int

        public var headerRowRange: ClosedRange<Int> {
            headerLine...(headerLine + SideBySideDocument.headerRowCount - 1)
        }
    }

    /// A run of rows that should be syntax-highlighted as one language.
    public struct HighlightSpan: Equatable, Sendable {
        public let startLine: Int
        public let endLine: Int
        public let language: String

        public init(startLine: Int, endLine: Int, language: String) {
            self.startLine = startLine
            self.endLine = endLine
            self.language = language
        }
    }

    public static let hunkBreakMarker = "···"

    /// Empty rows reserved at the top of each section; the UI overlays a real, clickable
    /// header control (file name, stats, collapse chevron) on top of them.
    public static let headerRowCount = 2

    /// How this document was built; the view renders one pane or two accordingly.
    public let layout: DiffLayoutMode
    public let leftText: String
    public let rightText: String
    /// Per-row metadata; each array's count equals the row count of both texts.
    public let leftKinds: [RowKind]
    public let rightKinds: [RowKind]
    /// Real line numbers in the old file for left rows (nil for headers/fillers/etc.).
    public let leftFileLines: [Int?]
    /// Real line numbers in the new (working tree) file for right rows.
    public let rightFileLines: [Int?]
    public let sections: [Section]

    public var rowCount: Int { rightKinds.count }

    // MARK: - Build

    /// `.split` fills both sides with paired rows; `.unified` puts everything in the right
    /// pane (deletions inline, in patch order) — the left arrays still carry old-file line
    /// numbers per row so deletion rows can be highlighted from the base version.
    public static func build(
        entries: [ChangeSetDocument.Entry],
        collapsedPaths: Set<String> = [],
        layout: DiffLayoutMode = .split
    ) -> SideBySideDocument {
        var builder = Builder(layout: layout)
        for (index, entry) in entries.enumerated() {
            builder.appendSection(entry: entry, isCollapsed: collapsedPaths.contains(entry.file.path))
            if index < entries.count - 1 {
                builder.appendRow(left: "", right: "", kinds: (.blank, .blank))
            }
            builder.closeSection()
        }
        return builder.finish()
    }

    // MARK: - Lookup

    public func section(containingLine line: Int) -> Section? {
        guard let first = sections.first, line >= first.headerLine else { return nil }
        var low = 0
        var high = sections.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if sections[mid].headerLine <= line {
                low = mid
            } else {
                high = mid - 1
            }
        }
        let candidate = sections[low]
        return line <= candidate.endLine ? candidate : nil
    }

    public func section(for url: URL) -> Section? {
        let path = url.standardizedFileURL.path
        return sections.first { $0.file.url.standardizedFileURL.path == path }
    }

    /// 1-based document lines of the "jump to next/previous change" stops: the first changed
    /// row of each hunk. This is GitHub's granularity — git already merges edits separated by
    /// only a few context lines into one `@@` hunk, so a hunk is one reviewable change.
    /// Stopping per edited row instead would produce hundreds of stops a few rows apart on a
    /// real branch, which reads as the buttons doing nothing.
    public func changeJumpTargets() -> [Int] {
        var targets: [Int] = []
        var hunkAlreadyStopped = false
        for index in 0..<min(leftKinds.count, rightKinds.count) {
            let left = leftKinds[index]
            let right = rightKinds[index]
            if Self.isHunkBoundary(left) || Self.isHunkBoundary(right) {
                hunkAlreadyStopped = false
                continue
            }
            let isChange = Self.isChangeKind(left) || Self.isChangeKind(right)
            if isChange && !hunkAlreadyStopped {
                targets.append(index + 1)
                hunkAlreadyStopped = true
            }
        }
        return targets
    }

    private static func isChangeKind(_ kind: RowKind) -> Bool {
        kind == .addition || kind == .deletion
    }

    /// Rows that end one hunk's cluster of edits (context rows inside a hunk do not).
    private static func isHunkBoundary(_ kind: RowKind) -> Bool {
        kind == .fileHeader || kind == .hunkBreak || kind == .blank
    }

    public func section(forPath path: String) -> Section? {
        sections.first { $0.file.path == path }
    }

    /// The rows displaying new-file lines `fileLines` of `path` — how a comment (stored with
    /// real file lines) finds its way back to rows on screen.
    public func rowRange(forNewFileLines fileLines: ClosedRange<Int>, inSectionPath path: String) -> ClosedRange<Int>? {
        guard let section = section(forPath: path), !section.isCollapsed else { return nil }
        var first: Int?
        var last: Int?
        for row in section.headerLine...section.endLine {
            guard let fileLine = rightFileLines[row - 1], fileLines.contains(fileLine) else { continue }
            if first == nil { first = row }
            last = row
        }
        guard let first, let last else { return nil }
        return first...last
    }

    /// Highlight spans for the expanded, non-placeholder section bodies (same rows both sides).
    public var highlightSpans: [HighlightSpan] {
        sections.compactMap { section in
            let bodyStart = section.headerLine + Self.headerRowCount
            guard !section.isCollapsed, !section.isPlaceholder, let language = section.language,
                  section.endLine >= bodyStart else { return nil }
            return HighlightSpan(
                startLine: bodyStart,
                endLine: section.endLine,
                language: language
            )
        }
    }

    // MARK: - Builder

    private struct Builder {
        let layout: DiffLayoutMode
        var leftLines: [String] = []
        var rightLines: [String] = []
        var leftKinds: [RowKind] = []
        var rightKinds: [RowKind] = []
        var leftFileLines: [Int?] = []
        var rightFileLines: [Int?] = []
        var sections: [Section] = []
        var sectionStartRow = 1
        var pendingSection: (
            file: GitChangedFile,
            isCollapsed: Bool,
            isPlaceholder: Bool,
            stats: (additions: Int, deletions: Int, lineCount: Int)
        )?

        mutating func appendRow(
            left: String,
            right: String,
            kinds: (RowKind, RowKind),
            leftFileLine: Int? = nil,
            rightFileLine: Int? = nil
        ) {
            leftLines.append(left)
            rightLines.append(right)
            leftKinds.append(kinds.0)
            rightKinds.append(kinds.1)
            leftFileLines.append(leftFileLine)
            rightFileLines.append(rightFileLine)
        }

        mutating func appendSection(entry: ChangeSetDocument.Entry, isCollapsed: Bool) {
            sectionStartRow = leftLines.count + 1
            let stats = Self.changeStats(of: entry.body)
            pendingSection = (entry.file, isCollapsed, entry.isPlaceholder, stats)

            // The header block is empty text — a real control is drawn over these rows.
            for _ in 0..<SideBySideDocument.headerRowCount {
                appendRow(left: "", right: "", kinds: (.fileHeader, .fileHeader))
            }
            if isCollapsed {
                return
            }

            if entry.isPlaceholder {
                for line in entry.body.components(separatedBy: "\n") where !line.isEmpty {
                    appendRow(left: "", right: line, kinds: (.filler, .placeholder))
                }
                return
            }

            switch layout {
            case .split:
                appendPatchRows(entry.body)
            case .unified:
                appendUnifiedPatchRows(entry.body)
            }
        }

        mutating func closeSection() {
            guard let pending = pendingSection else { return }
            pendingSection = nil
            sections.append(Section(
                file: pending.file,
                headerLine: sectionStartRow,
                endLine: leftLines.count,
                isCollapsed: pending.isCollapsed,
                isPlaceholder: pending.isPlaceholder,
                language: SyntaxLanguageResolver.languageName(for: pending.file.url),
                additions: pending.stats.additions,
                deletions: pending.stats.deletions,
                hiddenLineCount: pending.stats.lineCount
            ))
        }

        /// Cheap patch scan for header stats — counts `+`/`-` lines inside hunks.
        static func changeStats(of body: String) -> (additions: Int, deletions: Int, lineCount: Int) {
            var additions = 0
            var deletions = 0
            var lineCount = 0
            var inHunk = false
            let trimmed = body.hasSuffix("\n") ? String(body.dropLast()) : body
            for line in trimmed.components(separatedBy: "\n") {
                lineCount += 1
                if line.hasPrefix("@@ -") {
                    inHunk = true
                    continue
                }
                guard inHunk else { continue }
                if line.hasPrefix("+") {
                    additions += 1
                } else if line.hasPrefix("-") {
                    deletions += 1
                }
            }
            return (additions, deletions, lineCount)
        }

        /// Replays a unified patch into aligned rows. Deletion runs pair with the addition run
        /// that follows them (a "change block"); the longer run gets fillers on the other side.
        mutating func appendPatchRows(_ patch: String) {
            let body = patch.hasSuffix("\n") ? String(patch.dropLast()) : patch
            var oldNext = 0
            var newNext = 0
            var inHunk = false
            var deletions: [(line: String, number: Int)] = []
            var additions: [(line: String, number: Int)] = []

            func flushChangeBlock() {
                let rows = max(deletions.count, additions.count)
                guard rows > 0 else { return }
                for index in 0..<rows {
                    let deletion = index < deletions.count ? deletions[index] : nil
                    let addition = index < additions.count ? additions[index] : nil
                    appendRow(
                        left: deletion?.line ?? "",
                        right: addition?.line ?? "",
                        kinds: (deletion == nil ? .filler : .deletion, addition == nil ? .filler : .addition),
                        leftFileLine: deletion?.number,
                        rightFileLine: addition?.number
                    )
                }
                deletions = []
                additions = []
            }

            for line in body.components(separatedBy: "\n") {
                if let hunk = Self.parseHunkHeader(line) {
                    flushChangeBlock()
                    if inHunk {
                        appendRow(
                            left: SideBySideDocument.hunkBreakMarker,
                            right: SideBySideDocument.hunkBreakMarker,
                            kinds: (.hunkBreak, .hunkBreak)
                        )
                    }
                    inHunk = true
                    oldNext = hunk.oldStart
                    newNext = hunk.newStart
                    continue
                }
                guard inHunk else { continue } // metadata before the first hunk

                switch line.first {
                case "-":
                    deletions.append((String(line.dropFirst()), oldNext))
                    oldNext += 1
                case "+":
                    additions.append((String(line.dropFirst()), newNext))
                    newNext += 1
                case " ", nil:
                    flushChangeBlock()
                    let content = String(line.dropFirst())
                    appendRow(
                        left: content,
                        right: content,
                        kinds: (.context, .context),
                        leftFileLine: oldNext,
                        rightFileLine: newNext
                    )
                    oldNext += 1
                    newNext += 1
                default:
                    break // "\ No newline at end of file"
                }
            }
            flushChangeBlock()
        }

        /// Unified layout: one column (the "right" pane) in patch order — deletions appear
        /// inline instead of side by side. Deletion rows carry their old-file line numbers in
        /// the left map so they can still be syntax-highlighted from the base version.
        mutating func appendUnifiedPatchRows(_ patch: String) {
            let body = patch.hasSuffix("\n") ? String(patch.dropLast()) : patch
            var oldNext = 0
            var newNext = 0
            var inHunk = false

            for line in body.components(separatedBy: "\n") {
                if let hunk = Self.parseHunkHeader(line) {
                    if inHunk {
                        appendRow(
                            left: "",
                            right: SideBySideDocument.hunkBreakMarker,
                            kinds: (.hunkBreak, .hunkBreak)
                        )
                    }
                    inHunk = true
                    oldNext = hunk.oldStart
                    newNext = hunk.newStart
                    continue
                }
                guard inHunk else { continue }

                switch line.first {
                case "-":
                    appendRow(
                        left: "",
                        right: String(line.dropFirst()),
                        kinds: (.deletion, .deletion),
                        leftFileLine: oldNext
                    )
                    oldNext += 1
                case "+":
                    appendRow(
                        left: "",
                        right: String(line.dropFirst()),
                        kinds: (.addition, .addition),
                        rightFileLine: newNext
                    )
                    newNext += 1
                case " ", nil:
                    appendRow(
                        left: "",
                        right: String(line.dropFirst()),
                        kinds: (.context, .context),
                        leftFileLine: oldNext,
                        rightFileLine: newNext
                    )
                    oldNext += 1
                    newNext += 1
                default:
                    break // "\ No newline at end of file"
                }
            }
        }

        static func parseHunkHeader(_ line: String) -> (oldStart: Int, newStart: Int)? {
            guard line.hasPrefix("@@ -") else { return nil }
            let afterMarker = line.dropFirst("@@ -".count)
            guard let plusIndex = afterMarker.firstIndex(of: "+") else { return nil }
            let oldStartText = afterMarker.prefix(while: \.isNumber)
            let newStartText = afterMarker[afterMarker.index(after: plusIndex)...].prefix(while: \.isNumber)
            guard let oldStart = Int(oldStartText), let newStart = Int(newStartText) else { return nil }
            return (oldStart, newStart)
        }

        func finish() -> SideBySideDocument {
            SideBySideDocument(
                layout: layout,
                leftText: leftLines.joined(separator: "\n"),
                rightText: rightLines.joined(separator: "\n"),
                leftKinds: leftKinds,
                rightKinds: rightKinds,
                leftFileLines: leftFileLines,
                rightFileLines: rightFileLines,
                sections: sections
            )
        }
    }
}
