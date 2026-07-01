import Foundation

struct CodeReference: Equatable, Hashable, Identifiable, Sendable {
    let path: String
    let startLine: Int?
    let endLine: Int?

    var id: String {
        "\(path):\(startLine ?? 0)-\(endLine ?? 0)"
    }

    var lineRange: ClosedRange<Int>? {
        guard let startLine else { return nil }
        return startLine...max(endLine ?? startLine, startLine)
    }

    var displayText: String {
        guard let startLine else { return path }
        if let endLine, endLine != startLine {
            return "\(path):\(startLine)-\(endLine)"
        }
        return "\(path):\(startLine)"
    }

    var url: URL {
        var components = URLComponents()
        components.scheme = "myide-code-ref"
        components.host = "open"
        components.queryItems = [
            URLQueryItem(name: "path", value: path),
            URLQueryItem(name: "start", value: startLine.map(String.init)),
            URLQueryItem(name: "end", value: endLine.map(String.init)),
        ].filter { $0.value != nil }
        return components.url!
    }

    init(path: String, startLine: Int? = nil, endLine: Int? = nil) {
        self.path = path
        self.startLine = startLine
        self.endLine = endLine
    }

    init?(url: URL) {
        guard url.scheme == "myide-code-ref" else { return nil }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let items = components.queryItems ?? []
        guard let path = items.first(where: { $0.name == "path" })?.value, !path.isEmpty else {
            return nil
        }
        self.path = path
        self.startLine = items.first(where: { $0.name == "start" })?.value.flatMap(Int.init)
        self.endLine = items.first(where: { $0.name == "end" })?.value.flatMap(Int.init)
    }
}

struct CodeReferenceRequest: Equatable, Identifiable {
    let id = UUID()
    let reference: CodeReference
}

struct CodeReferenceSegment: Equatable {
    let text: String
    let reference: CodeReference?
}

enum CodeReferenceParser {
    private static let regex = try! NSRegularExpression(
        pattern: #"(?<![\w./-])([A-Za-z0-9_@+./-]+\.(?:c|cc|cpp|cs|css|go|h|hpp|html|java|js|jsx|kt|m|mm|md|mjs|php|py|rb|rs|scss|sh|sql|swift|toml|ts|tsx|txt|vue|xml|yaml|yml))(?:\:(\d{1,6})(?:-(\d{1,6}))?)?|:(\d{1,6})(?:-(\d{1,6}))?"#,
        options: []
    )

    static func segments(in text: String) -> [CodeReferenceSegment] {
        let nsString = text as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)
        var cursor = 0
        var lastPath: String?
        var segments: [CodeReferenceSegment] = []

        for match in regex.matches(in: text, options: [], range: fullRange) {
            guard match.range.location >= cursor else { continue }

            let pathRange = match.range(at: 1)
            let startRange = match.range(at: 2)
            let endRange = match.range(at: 3)
            let bareStartRange = match.range(at: 4)
            let bareEndRange = match.range(at: 5)

            let reference: CodeReference?
            if pathRange.location != NSNotFound {
                let path = nsString.substring(with: pathRange)
                lastPath = path
                reference = CodeReference(
                    path: path,
                    startLine: int(in: nsString, range: startRange),
                    endLine: int(in: nsString, range: endRange)
                )
            } else if bareStartRange.location != NSNotFound, let path = lastPath {
                reference = CodeReference(
                    path: path,
                    startLine: int(in: nsString, range: bareStartRange),
                    endLine: int(in: nsString, range: bareEndRange)
                )
            } else {
                reference = nil
            }

            guard let reference else { continue }

            if match.range.location > cursor {
                let prefixRange = NSRange(location: cursor, length: match.range.location - cursor)
                segments.append(CodeReferenceSegment(text: nsString.substring(with: prefixRange), reference: nil))
            }

            segments.append(CodeReferenceSegment(text: nsString.substring(with: match.range), reference: reference))
            cursor = NSMaxRange(match.range)
        }

        if cursor < nsString.length {
            let suffixRange = NSRange(location: cursor, length: nsString.length - cursor)
            segments.append(CodeReferenceSegment(text: nsString.substring(with: suffixRange), reference: nil))
        }

        return segments.isEmpty ? [CodeReferenceSegment(text: text, reference: nil)] : segments
    }

    static func references(in text: String) -> [CodeReference] {
        segments(in: text).compactMap(\.reference)
    }

    private static func int(in string: NSString, range: NSRange) -> Int? {
        guard range.location != NSNotFound else { return nil }
        return Int(string.substring(with: range))
    }
}
