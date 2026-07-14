import Foundation

/// A block of code the branch moved: the same lines deleted in one place and added in
/// another (possibly a different file). Endpoints are real file line numbers — old-file
/// lines for where the block left, new-file lines for where it landed — the same
/// rebuild-stable coordinates review comments use, so links survive collapse/layout
/// changes that renumber document rows.
public struct MovedBlock: Equatable, Sendable {
    public struct Endpoint: Equatable, Sendable {
        /// Display path (relative to the opened root) of the file section.
        public let path: String
        /// Old-file lines for a source, new-file lines for a destination.
        public let lines: ClosedRange<Int>

        public init(path: String, lines: ClosedRange<Int>) {
            self.path = path
            self.lines = lines
        }
    }

    /// Where the block was removed.
    public let source: Endpoint
    /// Where the block was added.
    public let destination: Endpoint

    public init(source: Endpoint, destination: Endpoint) {
        self.source = source
        self.destination = destination
    }

    public var lineCount: Int { destination.lines.count }
    public var isWithinOneFile: Bool { source.path == destination.path }
}

/// Finds moved blocks across a change set by matching runs of removed lines against runs of
/// added lines (the approach behind `git diff --color-moved`, simplified). Lines are compared
/// with surrounding whitespace stripped, so a block that moved into deeper nesting still
/// matches. Pure and git-free — input is the raw per-file patches already loaded for the
/// document — so `MyIDESelfTest` can pin the behavior down directly.
public enum MovedBlockDetector {
    /// A match must span at least this many lines: 1–2 line echoes (a lone `return`, a
    /// closing brace pair) are coincidence, not movement.
    public static let minimumLines = 3
    /// …and carry at least this many alphanumeric characters, so runs of braces/blank lines
    /// can never qualify on length alone.
    public static let minimumAlphanumerics = 30
    /// Lines whose text recurs more often than this among removals are too generic to anchor
    /// a match (and would make the scan quadratic on pathological diffs).
    static let maximumAnchorOccurrences = 64

    /// One removed or added patch line, positioned by real file line number. `cluster`
    /// identifies the contiguous `-`/`+` block the line came from: a deletion and an addition
    /// in the *same* cluster are the two halves of an in-place edit (e.g. re-indentation),
    /// which must not read as a move.
    struct ScanLine {
        let path: String
        let fileLine: Int
        let normalized: String
        let alphanumerics: Int
        let cluster: Int
    }

    public static func detect(entries: [ChangeSetDocument.Entry]) -> [MovedBlock] {
        var removed: [ScanLine] = []
        var added: [ScanLine] = []
        scan(entries: entries, removed: &removed, added: &added)
        return match(removed: removed, added: added)
    }

    // MARK: - Patch scan

    private static func scan(
        entries: [ChangeSetDocument.Entry],
        removed: inout [ScanLine],
        added: inout [ScanLine]
    ) {
        var cluster = 0
        for entry in entries where !entry.isPlaceholder && !Self.isRenameArtifact(entry) {
            let body = entry.body.hasSuffix("\n") ? String(entry.body.dropLast()) : entry.body
            var oldNext = 0
            var newNext = 0
            var inHunk = false
            var inChangeBlock = false

            for line in body.components(separatedBy: "\n") {
                if let hunk = SideBySideDocument.parseHunkHeader(line) {
                    inHunk = true
                    inChangeBlock = false
                    oldNext = hunk.oldStart
                    newNext = hunk.newStart
                    continue
                }
                guard inHunk else { continue } // metadata before the first hunk

                switch line.first {
                case "-":
                    if !inChangeBlock {
                        cluster += 1
                        inChangeBlock = true
                    }
                    removed.append(scanLine(line, path: entry.file.path, fileLine: oldNext, cluster: cluster))
                    oldNext += 1
                case "+":
                    if !inChangeBlock {
                        cluster += 1
                        inChangeBlock = true
                    }
                    added.append(scanLine(line, path: entry.file.path, fileLine: newNext, cluster: cluster))
                    newNext += 1
                case " ", nil:
                    inChangeBlock = false
                    oldNext += 1
                    newNext += 1
                default:
                    break // "\ No newline at end of file"
                }
            }
        }
    }

    /// Renamed/copied entries are excluded from the scan entirely. Their per-file patch is a
    /// full new-file patch (the per-path `git diff` can't pair the rename, so every
    /// carried-over line arrives as `+`), which would make the file's *pre-existing* content
    /// read as freshly added — any matching deletion elsewhere would get a bogus
    /// "moved to <renamed file>" link. The flip side is a known limitation: a block genuinely
    /// moved out of a renamed file has its removals in no entry, so that move goes undetected
    /// until rename diffs are loaded with both paths.
    private static func isRenameArtifact(_ entry: ChangeSetDocument.Entry) -> Bool {
        entry.file.status == .renamed || entry.file.status == .copied
    }

    private static func scanLine(_ patchLine: String, path: String, fileLine: Int, cluster: Int) -> ScanLine {
        let content = patchLine.dropFirst() // strip the +/- marker
        let normalized = content.trimmingCharacters(in: .whitespaces)
        var alphanumerics = 0
        for scalar in normalized.unicodeScalars where CharacterSet.alphanumerics.contains(scalar) {
            alphanumerics += 1
        }
        return ScanLine(
            path: path,
            fileLine: fileLine,
            normalized: normalized,
            alphanumerics: alphanumerics,
            cluster: cluster
        )
    }

    // MARK: - Run matching

    /// Greedy longest-run matching: for each unclaimed added line, try every removal with the
    /// same normalized text as a starting point, extend while both sides stay consecutive and
    /// equal, and keep the longest extension. Claimed lines can't be reused, so blocks never
    /// overlap; a removal only ever links to one addition and vice versa.
    private static func match(removed: [ScanLine], added: [ScanLine]) -> [MovedBlock] {
        guard !removed.isEmpty, !added.isEmpty else { return [] }

        var occurrences: [String: [Int]] = [:]
        for (index, line) in removed.enumerated() where !line.normalized.isEmpty {
            occurrences[line.normalized, default: []].append(index)
        }

        var removedClaimed = [Bool](repeating: false, count: removed.count)
        var addedClaimed = [Bool](repeating: false, count: added.count)
        var blocks: [MovedBlock] = []

        func continues(_ current: ScanLine, after previous: ScanLine) -> Bool {
            current.path == previous.path && current.fileLine == previous.fileLine + 1
        }

        var start = 0
        while start < added.count {
            let anchor = added[start]
            guard !addedClaimed[start],
                  !anchor.normalized.isEmpty, // blank lines can extend a run but not anchor one
                  let candidates = occurrences[anchor.normalized],
                  candidates.count <= maximumAnchorOccurrences else {
                start += 1
                continue
            }

            var best: (removedStart: Int, length: Int)?
            for candidate in candidates {
                // Same cluster = the paired halves of one in-place edit, not a move.
                guard !removedClaimed[candidate], removed[candidate].cluster != anchor.cluster else { continue }
                var length = 1
                while start + length < added.count, candidate + length < removed.count {
                    let nextAdded = added[start + length]
                    let nextRemoved = removed[candidate + length]
                    guard !addedClaimed[start + length], !removedClaimed[candidate + length],
                          continues(nextAdded, after: added[start + length - 1]),
                          continues(nextRemoved, after: removed[candidate + length - 1]),
                          nextAdded.normalized == nextRemoved.normalized else { break }
                    length += 1
                }
                if length > (best?.length ?? 0) {
                    best = (candidate, length)
                }
            }

            guard let best, best.length >= minimumLines,
                  (0..<best.length).reduce(0, { $0 + added[start + $1].alphanumerics }) >= minimumAlphanumerics
            else {
                start += 1
                continue
            }

            for offset in 0..<best.length {
                removedClaimed[best.removedStart + offset] = true
                addedClaimed[start + offset] = true
            }
            let sourceStart = removed[best.removedStart]
            let sourceEnd = removed[best.removedStart + best.length - 1]
            let destinationEnd = added[start + best.length - 1]
            blocks.append(MovedBlock(
                source: MovedBlock.Endpoint(path: sourceStart.path, lines: sourceStart.fileLine...sourceEnd.fileLine),
                destination: MovedBlock.Endpoint(path: anchor.path, lines: anchor.fileLine...destinationEnd.fileLine)
            ))
            start += best.length
        }

        return blocks
    }
}
