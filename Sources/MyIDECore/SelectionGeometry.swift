import Foundation

/// Character-level geometry of a text selection: the lines it touches and the 1-based
/// columns (UTF-16 offsets, TextKit's coordinate system) where it starts and ends within
/// them. This is what lets a comment target the exact words the reviewer selected instead
/// of whole lines. Pure — exercised directly by `MyIDESelfTest`.
public struct PreciseSelection: Equatable, Sendable {
    public let startLine: Int
    /// 1-based column of the first selected character within `startLine`.
    public let startColumn: Int
    public let endLine: Int
    /// 1-based column of the last selected character within `endLine` (inclusive).
    public let endColumn: Int
    /// The selected characters, verbatim (trailing newlines dropped).
    public let exactText: String

    public init(startLine: Int, startColumn: Int, endLine: Int, endColumn: Int, exactText: String) {
        self.startLine = startLine
        self.startColumn = startColumn
        self.endLine = endLine
        self.endColumn = endColumn
        self.exactText = exactText
    }
}

public enum SelectionGeometry {
    /// Resolves a UTF-16 selection range against `text`. `lineStarts` are the 0-based
    /// character offsets of every line start (first entry 0) — the same cache the text view
    /// keeps for scroll math. Returns nil for empty/out-of-bounds selections and for
    /// selections that contain only newlines (nothing precise to target).
    public static func preciseSelection(
        in text: String,
        selectedLocation: Int,
        selectedLength: Int,
        lineStarts: [Int]
    ) -> PreciseSelection? {
        let nsString = text as NSString
        guard selectedLength > 0,
              selectedLocation >= 0,
              selectedLocation + selectedLength <= nsString.length,
              !lineStarts.isEmpty else {
            return nil
        }

        // Selecting to the start of the next line (a triple-click, or dragging past the end)
        // includes trailing newlines; pull the end back so the last column points at a real
        // character on the last selected line.
        let startLocation = selectedLocation
        var endLocation = selectedLocation + selectedLength - 1
        while endLocation > startLocation, isNewline(nsString.character(at: endLocation)) {
            endLocation -= 1
        }
        guard !isNewline(nsString.character(at: endLocation)) else { return nil }

        let startLine = lineNumber(at: startLocation, lineStarts: lineStarts)
        let endLine = lineNumber(at: endLocation, lineStarts: lineStarts)
        let exactText = nsString.substring(
            with: NSRange(location: startLocation, length: endLocation - startLocation + 1)
        )
        return PreciseSelection(
            startLine: startLine,
            startColumn: startLocation - lineStarts[startLine - 1] + 1,
            endLine: endLine,
            endColumn: endLocation - lineStarts[endLine - 1] + 1,
            exactText: exactText
        )
    }

    private static func isNewline(_ character: unichar) -> Bool {
        character == 0x0A || character == 0x0D
    }

    private static func lineNumber(at location: Int, lineStarts: [Int]) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= location {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return low + 1
    }
}
