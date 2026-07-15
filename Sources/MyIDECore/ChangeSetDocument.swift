import Foundation

/// The whole branch change set rendered as one continuous text document: every changed file's
/// patch in sidebar order, each preceded by a `◆ path` header line. The section table maps
/// between document line numbers and files, so the sidebar can jump to a file and a selection
/// anywhere in the scroll can be attributed back to the file it landed in.
///
/// Pure value type (no AppKit/SwiftUI) so `MyIDESelfTest` can exercise it directly.
public struct ChangeSetDocument: Equatable, Sendable {
    public struct Section: Equatable, Sendable {
        public let file: GitChangedFile
        /// 1-based line of the `▾ path` header in the combined text.
        public let headerLine: Int
        /// First line of the patch (or placeholder message) — one past the header.
        /// Equals `headerLine` when the section is collapsed to just its header.
        public let bodyStartLine: Int
        /// Last line belonging to this section, inclusive of the separator blank line.
        public let endLine: Int
        /// True when the body is a message (binary / too large / error) rather than a patch.
        public let isPlaceholder: Bool
        /// True when the body is hidden (file marked reviewed/collapsed).
        public let isCollapsed: Bool
    }

    /// One file's contribution before assembly.
    public struct Entry: Equatable, Sendable {
        public let file: GitChangedFile
        public let body: String
        public let isPlaceholder: Bool
        /// Complete base-version file content, for line-mapped syntax highlighting. Diff
        /// fragments start mid-construct and mislead lexers; whole files highlight correctly.
        public let oldText: String?
        /// Complete working-tree file content, same purpose.
        public let newText: String?

        public init(
            file: GitChangedFile,
            body: String,
            isPlaceholder: Bool,
            oldText: String? = nil,
            newText: String? = nil
        ) {
            self.file = file
            self.body = body
            self.isPlaceholder = isPlaceholder
            self.oldText = oldText
            self.newText = newText
        }
    }

    /// Marks expanded file-header lines. Diff body lines always start with `+`, `-`, a space,
    /// `@@`, or a known metadata keyword, so these prefixes at column 0 are unambiguous
    /// within the document.
    public static let expandedHeaderPrefix = "▾ "
    /// Marks collapsed (reviewed) file-header lines.
    public static let collapsedHeaderPrefix = "▸ "

    public static func isHeaderLine(_ line: some StringProtocol) -> Bool {
        line.hasPrefix(expandedHeaderPrefix) || line.hasPrefix(collapsedHeaderPrefix)
    }

    /// Upper bound on the combined text; patches past the budget collapse to a placeholder so
    /// one giant file can't make the whole scroll unresponsive.
    public static let maxDocumentSize = 8 * 1024 * 1024

    public let text: String
    public let sections: [Section]

    public static func build(entries: [Entry], collapsedPaths: Set<String> = []) -> ChangeSetDocument {
        var lines: [String] = []
        var sections: [Section] = []
        sections.reserveCapacity(entries.count)

        for (index, entry) in entries.enumerated() {
            let isCollapsed = collapsedPaths.contains(entry.file.path)
            let headerLine = lines.count + 1
            let body = entry.body.hasSuffix("\n") ? String(entry.body.dropLast()) : entry.body
            let bodyLines = body.components(separatedBy: "\n")

            var bodyStartLine = headerLine
            if isCollapsed {
                lines.append(
                    collapsedHeaderPrefix + headerTitle(for: entry.file)
                        + "  ·  \(bodyLines.count) hidden line\(bodyLines.count == 1 ? "" : "s")"
                )
            } else {
                lines.append(expandedHeaderPrefix + headerTitle(for: entry.file))
                bodyStartLine = lines.count + 1
                lines.append(contentsOf: bodyLines)
            }

            let isLast = index == entries.count - 1
            if !isLast {
                lines.append("") // breathing room between files
            }

            sections.append(Section(
                file: entry.file,
                headerLine: headerLine,
                bodyStartLine: bodyStartLine,
                endLine: lines.count,
                isPlaceholder: entry.isPlaceholder,
                isCollapsed: isCollapsed
            ))
        }

        return ChangeSetDocument(text: lines.joined(separator: "\n"), sections: sections)
    }

    /// The section whose lines include `line` (1-based). Sections tile the document, so this is
    /// a binary search over header lines.
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

    /// Shared by the unified and side-by-side builders so headers read identically.
    public static func headerTitle(for file: GitChangedFile) -> String {
        if let suffix = statusSuffix(for: file) {
            return "\(file.path)  ·  \(suffix)"
        }
        return file.path
    }

    private static func statusSuffix(for file: GitChangedFile) -> String? {
        switch file.status {
        case .added: return "added"
        case .deleted: return "deleted"
        case .untracked: return "new"
        case .renamed: return file.oldPath.map { "renamed from \($0)" } ?? "renamed"
        case .copied: return file.oldPath.map { "copied from \($0)" } ?? "copied"
        case .conflicted: return "conflicted"
        case .modified, .typeChanged, .unknown: return nil
        }
    }
}

public extension GitChangeSet {
    /// Loads every file's diff and assembles the combined scroll document. Runs one `git diff`
    /// per file, so call it off the main thread.
    static func loadDocument(for context: GitChangeContext, collapsedPaths: Set<String> = []) -> ChangeSetDocument {
        ChangeSetDocument.build(entries: loadDocumentEntries(for: context), collapsedPaths: collapsedPaths)
    }

    /// Files above this size skip whole-file text capture (used for line-mapped syntax
    /// highlighting) — the diff still renders, just without highlighting.
    static let maxHighlightableFileSize = 1_500_000

    /// The per-file bodies backing the combined document. Callers keep these around so
    /// collapse toggles can rebuild the document without rerunning every `git diff`.
    ///
    /// Runs 2–3 git commands per file, so a big branch is a long sequential process storm.
    /// The loop checks `Task.isCancelled` between files: when the user switches scope or
    /// closes the project mid-load, the stale load stops spawning instead of racing the
    /// fresh one to completion (its partial result is discarded by the caller's own
    /// cancellation check).
    static func loadDocumentEntries(for context: GitChangeContext) -> [ChangeSetDocument.Entry] {
        var remainingBudget = ChangeSetDocument.maxDocumentSize
        let diffBase = resolvedDiffBase(in: context)
        var entries: [ChangeSetDocument.Entry] = []
        entries.reserveCapacity(context.files.count)
        for file in context.files {
            if Task.isCancelled { return entries }
            entries.append(entry(for: file, in: context, diffBase: diffBase, remainingBudget: &remainingBudget))
        }
        return entries
    }

    private static func entry(
        for file: GitChangedFile,
        in context: GitChangeContext,
        diffBase: String?,
        remainingBudget: inout Int
    ) -> ChangeSetDocument.Entry {
        let (body, isPlaceholder) = entryBody(for: file, in: context, diffBase: diffBase, remainingBudget: remainingBudget)
        if !isPlaceholder {
            remainingBudget -= body.utf8.count
        }
        var oldText: String?
        var newText: String?
        if !isPlaceholder {
            oldText = baseFileText(for: file, diffBase: diffBase, in: context)
            newText = newFileText(for: file, in: context)
        }
        return ChangeSetDocument.Entry(
            file: file,
            body: body,
            isPlaceholder: isPlaceholder,
            oldText: oldText,
            newText: newText
        )
    }

    /// Base-version content via `git show <ref>:<path>`; nil for untracked files or oversized
    /// content.
    private static func baseFileText(
        for file: GitChangedFile,
        diffBase: String?,
        in context: GitChangeContext
    ) -> String? {
        if case .untracked = file.status { return nil }
        guard let result = runGit(
            ["show", "\(diffBase ?? "HEAD"):\(file.repositoryPath)"],
            in: context.repositoryRootURL
        ), result.exitCode == 0 else {
            return nil
        }
        guard result.stdout.count <= maxHighlightableFileSize,
              !FileSystem.isProbablyBinary(result.stdout) else {
            return nil
        }
        return FileSystem.decodeText(result.stdout)
    }

    /// New-side content: the working tree for branch/since scopes, or the pinned commit's
    /// version for commit scope (the disk may have moved past that commit); nil for
    /// deleted/binary/oversized files.
    private static func newFileText(for file: GitChangedFile, in context: GitChangeContext) -> String? {
        if case .deleted = file.status { return nil }
        if case .commit(let sha) = context.scope {
            guard let result = runGit(
                ["show", "\(sha):\(file.repositoryPath)"],
                in: context.repositoryRootURL
            ), result.exitCode == 0 else {
                return nil
            }
            guard result.stdout.count <= maxHighlightableFileSize,
                  !FileSystem.isProbablyBinary(result.stdout) else {
                return nil
            }
            return FileSystem.decodeText(result.stdout)
        }
        guard case .text(let text) = FileSystem.loadForDisplay(file.url, maxSize: maxHighlightableFileSize) else {
            return nil
        }
        return text
    }

    private static func entryBody(
        for file: GitChangedFile,
        in context: GitChangeContext,
        diffBase: String?,
        remainingBudget: Int
    ) -> (body: String, isPlaceholder: Bool) {
        switch loadDiff(file: file, in: context, diffBase: diffBase) {
        case .diff(let diff):
            guard diff.patch.utf8.count <= remainingBudget else {
                return ("Diff omitted — combined preview reached its size limit.", true)
            }
            return (diff.patch, false)
        case .noDiff:
            return ("No diff for this file.", true)
        case .tooLarge(let bytes):
            let formatted = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            return ("Diff is too large to preview (\(formatted)).", true)
        case .fileNotInChangeSet:
            return ("This file is not part of the current change set.", true)
        case .unavailable(let message):
            return ("Can’t load diff: \(message)", true)
        }
    }
}
