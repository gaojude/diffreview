import Foundation
import MyIDECore

struct CodebaseContextSnapshot: Sendable {
    let rootURL: URL
    let selection: CodeSelectionContext
    let fileMap: [String]
    let includedFiles: [IncludedFile]
    let searchTerms: [String]

    var promptText: String {
        var sections: [String] = []
        sections.append("""
        Codebase root:
        \(rootURL.path)

        Selection anchor:
        - File: \(relativeSelectedPath)
        - Kind: \(selection.contentKind == .diff ? "diff" : "source")
        - Lines: \(selection.startLine)-\(selection.endLine)

        Selected text:
        ```
        \(selection.text)
        ```
        """)

        if !searchTerms.isEmpty {
            sections.append("""
            Search terms used for local context:
            \(searchTerms.joined(separator: ", "))
            """)
        }

        sections.append("""
        Repository map:
        \(fileMap.prefix(400).joined(separator: "\n"))
        """)

        if fileMap.count > 400 {
            sections.append("[Repository map truncated: \(fileMap.count - 400) more files]")
        }

        if !includedFiles.isEmpty {
            sections.append(includedFiles.map(\.promptText).joined(separator: "\n\n"))
        }

        return sections.joined(separator: "\n\n---\n\n")
    }

    private var relativeSelectedPath: String {
        guard let fileURL = selection.fileURL else { return "Unknown" }
        return Self.relativePath(for: fileURL, rootURL: rootURL) ?? fileURL.path
    }

    static func relativePath(for fileURL: URL, rootURL: URL) -> String? {
        let rootPath = rootURL.standardizedFileURL.resolvingSymlinksInPath().path
        let filePath = fileURL.standardizedFileURL.resolvingSymlinksInPath().path
        guard filePath == rootPath || filePath.hasPrefix(rootPath + "/") else { return nil }
        if filePath == rootPath { return "." }
        return String(filePath.dropFirst(rootPath.count + 1))
    }

    struct IncludedFile: Sendable {
        let path: String
        let reason: String
        let content: String

        var promptText: String {
            """
            File: \(path)
            Reason: \(reason)
            ```
            \(content)
            ```
            """
        }
    }
}

enum CodebaseContextBuilder {
    private static let maxFilesInMap = 1_500
    private static let maxIncludedFiles = 18
    private static let maxSingleFileBytes = 80_000
    private static let maxPromptCharacters = 80_000
    private static let maxFileCharacters = 14_000

    private static let ignoredDirectoryNames: Set<String> = [
        ".build", ".git", ".next", ".turbo", ".venv", ".yarn", "DerivedData",
        "Pods", "build", "coverage", "dist", "node_modules", "out", "target",
        "vendor", "venv",
    ]

    private static let sourceExtensions: Set<String> = [
        "c", "cc", "cpp", "cs", "css", "go", "h", "hpp", "html", "java", "js",
        "json", "jsx", "kt", "m", "mm", "md", "mjs", "php", "py", "rb", "rs",
        "scss", "sh", "sql", "swift", "toml", "ts", "tsx", "txt", "vue", "xml",
        "yaml", "yml",
    ]

    private static let importantNames: Set<String> = [
        "AGENTS.md", "CLAUDE.md", "Codex.md", "Dockerfile", "Gemfile",
        "Makefile", "Package.swift", "README.md", "package.json", "pnpm-lock.yaml",
        "pyproject.toml", "tsconfig.json",
    ]

    static func build(
        rootURL: URL,
        selection: CodeSelectionContext,
        question: String
    ) -> CodebaseContextSnapshot {
        let rootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let entries = fileInventory(rootURL: rootURL)
        let fileMap = entries.prefix(maxFilesInMap).map(\.path)
        let selectedPath = selection.fileURL.flatMap {
            CodebaseContextSnapshot.relativePath(for: $0, rootURL: rootURL)
        }
        let terms = searchTerms(from: "\(question)\n\(selection.text)\n\(selectedPath ?? "")")
        let includedFiles = includedFiles(
            rootURL: rootURL,
            entries: entries,
            selectedPath: selectedPath,
            terms: terms
        )

        return CodebaseContextSnapshot(
            rootURL: rootURL,
            selection: selection,
            fileMap: fileMap,
            includedFiles: includedFiles,
            searchTerms: terms
        )
    }

    private static func fileInventory(rootURL: URL) -> [FileEntry] {
        let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsPackageDescendants]
        ) else {
            return []
        }

        var entries: [FileEntry] = []

        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            guard let values = try? url.resourceValues(forKeys: resourceKeys) else { continue }

            if values.isDirectory == true {
                if ignoredDirectoryNames.contains(name) || name.hasSuffix(".app") {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard values.isRegularFile == true else { continue }
            guard let path = CodebaseContextSnapshot.relativePath(for: url, rootURL: rootURL) else { continue }
            guard isContextCandidate(url: url) else { continue }

            entries.append(FileEntry(
                url: url,
                path: path,
                size: values.fileSize ?? 0
            ))
        }

        return entries.sorted { lhs, rhs in
            lhs.path.localizedCaseInsensitiveCompare(rhs.path) == .orderedAscending
        }
    }

    private static func includedFiles(
        rootURL: URL,
        entries: [FileEntry],
        selectedPath: String?,
        terms: [String]
    ) -> [CodebaseContextSnapshot.IncludedFile] {
        var usedCharacters = 0
        var results: [CodebaseContextSnapshot.IncludedFile] = []

        for scored in scoredEntries(entries, selectedPath: selectedPath, terms: terms) {
            guard results.count < maxIncludedFiles else { break }
            guard scored.entry.size <= maxSingleFileBytes else { continue }
            guard let data = try? Data(contentsOf: scored.entry.url, options: [.mappedIfSafe]) else { continue }
            guard !FileSystem.isProbablyBinary(data) else { continue }

            let decoded = FileSystem.decodeText(data)
            let clipped = clip(decoded, maxCharacters: maxFileCharacters)
            guard !clipped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            if usedCharacters + clipped.count > maxPromptCharacters, !results.isEmpty {
                break
            }
            usedCharacters += clipped.count
            results.append(CodebaseContextSnapshot.IncludedFile(
                path: scored.entry.path,
                reason: scored.reason,
                content: clipped
            ))
        }

        return results
    }

    private static func scoredEntries(
        _ entries: [FileEntry],
        selectedPath: String?,
        terms: [String]
    ) -> [ScoredEntry] {
        let selectedDirectory = selectedPath.flatMap { path -> String? in
            guard let slash = path.lastIndex(of: "/") else { return nil }
            return String(path[..<slash])
        }

        return entries.compactMap { entry in
            var score = 0
            var reasons: [String] = []
            let pathLower = entry.path.lowercased()
            let name = entry.url.lastPathComponent

            if entry.path == selectedPath {
                score += 1_000
                reasons.append("selected file")
            }

            if importantNames.contains(name) {
                score += 170
                reasons.append("project metadata")
            }

            if let selectedDirectory, entry.path.hasPrefix(selectedDirectory + "/") {
                score += 100
                reasons.append("same folder as selection")
            }

            for term in terms {
                if pathLower.contains(term.lowercased()) {
                    score += 70
                    reasons.append("path matches \(term)")
                }
            }

            if score < 220, let data = try? Data(contentsOf: entry.url, options: [.mappedIfSafe]) {
                guard !FileSystem.isProbablyBinary(data) else { return nil }
                let text = FileSystem.decodeText(data).lowercased()
                var contentMatches = 0
                for term in terms {
                    if text.contains(term.lowercased()) {
                        contentMatches += 1
                    }
                }
                if contentMatches > 0 {
                    score += min(contentMatches * 55, 220)
                    reasons.append("\(contentMatches) local text match\(contentMatches == 1 ? "" : "es")")
                }
            }

            guard score > 0 else { return nil }
            return ScoredEntry(
                entry: entry,
                score: score,
                reason: reasons.uniqued().joined(separator: ", ")
            )
        }
        .sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.entry.path.localizedCaseInsensitiveCompare(rhs.entry.path) == .orderedAscending
        }
    }

    private static func searchTerms(from text: String) -> [String] {
        let candidates = text
            .split { !$0.isLetter && !$0.isNumber && $0 != "_" && $0 != "-" }
            .map(String.init)
            .filter { token in
                token.count >= 4
                    && token.count <= 48
                    && !stopWords.contains(token.lowercased())
                    && token.rangeOfCharacter(from: .letters) != nil
            }

        let identifierPieces = candidates.flatMap(splitIdentifier)
        let terms = (candidates + identifierPieces)
            .map { $0.lowercased() }
            .filter { $0.count >= 4 && !stopWords.contains($0) }
            .uniqued()
        return Array(terms.prefix(28))
    }

    private static func splitIdentifier(_ token: String) -> [String] {
        let normalized = token.replacingOccurrences(of: "-", with: "_")
        let underscorePieces = normalized.split(separator: "_").map(String.init)
        return underscorePieces.flatMap { piece in
            piece.replacingOccurrences(
                of: "([a-z0-9])([A-Z])",
                with: "$1 $2",
                options: .regularExpression
            )
            .split(separator: " ")
            .map(String.init)
        }
    }

    private static func isContextCandidate(url: URL) -> Bool {
        let name = url.lastPathComponent
        if importantNames.contains(name) { return true }
        let ext = url.pathExtension.lowercased()
        return !ext.isEmpty && sourceExtensions.contains(ext)
    }

    private static func clip(_ text: String, maxCharacters: Int) -> String {
        guard text.count > maxCharacters else { return text }
        return "\(text.prefix(maxCharacters))\n\n[File truncated]"
    }

    private struct FileEntry {
        let url: URL
        let path: String
        let size: Int
    }

    private struct ScoredEntry {
        let entry: FileEntry
        let score: Int
        let reason: String
    }

    private static let stopWords: Set<String> = [
        "about", "after", "also", "because", "before", "class", "code", "does",
        "file", "from", "func", "function", "have", "into", "just", "like",
        "line", "lines", "need", "private", "public", "return", "self", "should",
        "some", "static", "struct", "that", "their", "then", "there", "this",
        "type", "var", "what", "when", "where", "with",
    ]
}

private extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}
