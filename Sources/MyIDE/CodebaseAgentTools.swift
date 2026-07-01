import Foundation
import MyIDECore

struct CodebaseAgentToolbox: Sendable {
    let rootURL: URL
    let selection: CodeSelectionContext

    private let resolvedRootURL: URL
    private let changeContext: GitChangeContext?

    init(rootURL: URL, selection: CodeSelectionContext) {
        self.rootURL = rootURL
        self.selection = selection
        self.resolvedRootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        if case .repository(let context) = GitChangeSet.load(for: rootURL) {
            self.changeContext = context
        } else {
            self.changeContext = nil
        }
    }

    var selectedPath: String {
        selection.fileURL.flatMap { relativePath(for: $0) } ?? "unknown"
    }

    var changedFileSummary: String {
        guard let changeContext else { return "No Git change set is available." }
        if changeContext.files.isEmpty { return "Git change set is empty." }
        return changeContext.files
            .map { "\($0.path) [\(statusLabel($0.status))]" }
            .joined(separator: "\n")
    }

    static var toolDefinitions: [[String: Any]] {
        [
            [
                "type": "function",
                "function": [
                    "name": "get_git_diff",
                    "description": "Read the branch/worktree git diff. Call this first to understand the semantic change before reading arbitrary files.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "path": [
                                "type": "string",
                                "description": "Optional path relative to the opened root. Omit for the selected file plus the broader change set.",
                            ],
                            "max_chars": [
                                "type": "integer",
                                "description": "Maximum characters to return.",
                            ],
                        ],
                        "additionalProperties": false,
                    ],
                ],
            ],
            [
                "type": "function",
                "function": [
                    "name": "list_files",
                    "description": "List source-like files under the opened root. Use this to find nearby or related files without reading them all.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "query": [
                                "type": "string",
                                "description": "Optional case-insensitive substring to match against paths.",
                            ],
                            "limit": [
                                "type": "integer",
                                "description": "Maximum number of paths to return.",
                            ],
                        ],
                        "additionalProperties": false,
                    ],
                ],
            ],
            [
                "type": "function",
                "function": [
                    "name": "read_file",
                    "description": "Read one local text file by path. Use line ranges when possible.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "path": [
                                "type": "string",
                                "description": "Path relative to the opened root.",
                            ],
                            "start_line": [
                                "type": "integer",
                                "description": "Optional 1-based start line.",
                            ],
                            "end_line": [
                                "type": "integer",
                                "description": "Optional 1-based end line.",
                            ],
                            "max_chars": [
                                "type": "integer",
                                "description": "Maximum characters to return.",
                            ],
                        ],
                        "required": ["path"],
                        "additionalProperties": false,
                    ],
                ],
            ],
            [
                "type": "function",
                "function": [
                    "name": "search_text",
                    "description": "Search local text files for a literal string. Use this to follow symbols, imports, filenames, or error text.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "query": [
                                "type": "string",
                                "description": "Literal text to search for.",
                            ],
                            "path_prefix": [
                                "type": "string",
                                "description": "Optional path prefix relative to the opened root.",
                            ],
                            "max_results": [
                                "type": "integer",
                                "description": "Maximum matches to return.",
                            ],
                        ],
                        "required": ["query"],
                        "additionalProperties": false,
                    ],
                ],
            ],
        ]
    }

    func execute(toolName: String, arguments: String) -> String {
        let object = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any] ?? [:]
        switch toolName {
        case "get_git_diff":
            return getGitDiff(
                path: object["path"] as? String,
                maxCharacters: clampedInt(object["max_chars"], defaultValue: 24_000, min: 4_000, max: 60_000)
            )
        case "list_files":
            return listFiles(
                query: object["query"] as? String,
                limit: clampedInt(object["limit"], defaultValue: 160, min: 20, max: 500)
            )
        case "read_file":
            guard let path = object["path"] as? String else {
                return "Missing required argument: path."
            }
            return readFile(
                path: path,
                startLine: object["start_line"] as? Int,
                endLine: object["end_line"] as? Int,
                maxCharacters: clampedInt(object["max_chars"], defaultValue: 18_000, min: 2_000, max: 50_000)
            )
        case "search_text":
            guard let query = object["query"] as? String else {
                return "Missing required argument: query."
            }
            return searchText(
                query: query,
                pathPrefix: object["path_prefix"] as? String,
                maxResults: clampedInt(object["max_results"], defaultValue: 60, min: 10, max: 200)
            )
        default:
            return "Unknown tool: \(toolName)."
        }
    }

    func progressMessage(for toolName: String, arguments: String) -> String {
        let object = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any] ?? [:]
        switch toolName {
        case "get_git_diff":
            if let path = object["path"] as? String, !path.isEmpty {
                return "Let me inspect the diff for \(lastPathComponent(path))."
            }
            return "Let me inspect the git diff first."
        case "list_files":
            return "I’m checking the project shape."
        case "read_file":
            let path = (object["path"] as? String).map(lastPathComponent) ?? "that file"
            return "I’m opening \(path)."
        case "search_text":
            if let query = object["query"] as? String, !query.isEmpty {
                return "I’m searching for \(spokenSearchTerm(query))."
            }
            return "I’m searching the codebase."
        default:
            return "I’m checking one more thing."
        }
    }

    private func getGitDiff(path: String?, maxCharacters: Int) -> String {
        guard let changeContext else {
            return "No Git repository or change set is available for \(resolvedRootURL.path)."
        }

        let changedFiles = prioritizedChangedFiles(in: changeContext, requestedPath: path)
        guard !changedFiles.isEmpty else {
            return "No changed files matched \(path ?? "the current selection")."
        }

        var sections = [
            "Branch: \(changeContext.branchName)",
            "Base: \(changeContext.baseRef ?? "HEAD")",
            "Changed files:\n\(changedFileSummary)",
        ]
        var usedCharacters = sections.joined(separator: "\n\n").count

        for file in changedFiles {
            let result = GitChangeSet.loadDiff(for: file.url, in: changeContext)
            let section: String
            switch result {
            case .diff(let diff):
                section = """
                Diff for \(file.path) [\(statusLabel(file.status))]:
                ```diff
                \(diff.patch)
                ```
                """
            case .noDiff:
                section = "No diff content for \(file.path)."
            case .tooLarge(let bytes):
                section = "Diff for \(file.path) is too large to include (\(bytes) bytes)."
            case .fileNotInChangeSet:
                section = "\(file.path) is not in the change set."
            case .unavailable(let message):
                section = "Could not load diff for \(file.path): \(message)"
            }

            guard usedCharacters + section.count <= maxCharacters else {
                sections.append("[Diff truncated to \(maxCharacters) characters.]")
                break
            }
            sections.append(section)
            usedCharacters += section.count
        }

        return sections.joined(separator: "\n\n")
    }

    private func prioritizedChangedFiles(in context: GitChangeContext, requestedPath: String?) -> [GitChangedFile] {
        let selectedPath = selection.fileURL.flatMap { relativePath(for: $0) }
        let normalizedRequest = requestedPath?.trimmingCharacters(in: .whitespacesAndNewlines)

        var files = context.files
        files.sort { lhs, rhs in
            score(file: lhs, selectedPath: selectedPath, requestedPath: normalizedRequest)
                > score(file: rhs, selectedPath: selectedPath, requestedPath: normalizedRequest)
        }

        if let normalizedRequest, !normalizedRequest.isEmpty {
            let matches = files.filter {
                $0.path == normalizedRequest
                    || $0.repositoryPath == normalizedRequest
                    || $0.path.hasSuffix("/\(normalizedRequest)")
            }
            return matches.isEmpty ? files.prefixArray(12) : matches
        }

        return files.prefixArray(16)
    }

    private func score(file: GitChangedFile, selectedPath: String?, requestedPath: String?) -> Int {
        var score = 0
        if let selectedPath, file.path == selectedPath { score += 1_000 }
        if let requestedPath, !requestedPath.isEmpty {
            if file.path == requestedPath || file.repositoryPath == requestedPath { score += 2_000 }
            if file.path.contains(requestedPath) { score += 400 }
        }
        switch file.status {
        case .modified, .renamed, .copied:
            score += 80
        case .added, .deleted, .untracked:
            score += 50
        default:
            score += 20
        }
        return score
    }

    private func listFiles(query: String?, limit: Int) -> String {
        let query = query?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let changedPaths = Set(changeContext?.files.map(\.path) ?? [])
        let paths = fileInventory()
            .filter { path in
                guard let query, !query.isEmpty else { return true }
                return path.lowercased().contains(query)
            }
            .prefix(limit)
            .map { path in
                changedPaths.contains(path) ? "\(path) [changed]" : path
            }

        return paths.isEmpty ? "No matching files." : paths.joined(separator: "\n")
    }

    private func readFile(path: String, startLine: Int?, endLine: Int?, maxCharacters: Int) -> String {
        guard let url = safeURL(for: path) else {
            return "Path is outside the opened root or invalid: \(path)"
        }
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            return "Could not read file: \(path)"
        }
        guard !FileSystem.isProbablyBinary(data) else {
            return "File appears to be binary: \(path)"
        }

        let text = FileSystem.decodeText(data)
        let lines = text.components(separatedBy: .newlines)
        let start = max((startLine ?? 1), 1)
        let end = min(max(endLine ?? lines.count, start), lines.count)
        guard start <= end, !lines.isEmpty else {
            return "No lines in file: \(path)"
        }

        let body = lines[(start - 1)..<end]
            .enumerated()
            .map { offset, line in "\(start + offset): \(line)" }
            .joined(separator: "\n")
        return """
        File: \(path)
        Lines: \(start)-\(end)
        ```
        \(clip(body, maxCharacters: maxCharacters))
        ```
        """
    }

    private func searchText(query: String, pathPrefix: String?, maxResults: Int) -> String {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return "Search query is empty." }

        let lowerQuery = trimmedQuery.lowercased()
        let prefix = pathPrefix?.trimmingCharacters(in: .whitespacesAndNewlines)
        var results: [String] = []

        for path in fileInventory() {
            if let prefix, !prefix.isEmpty, !path.hasPrefix(prefix) { continue }
            guard let url = safeURL(for: path),
                  let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
                  !FileSystem.isProbablyBinary(data) else {
                continue
            }

            let lines = FileSystem.decodeText(data).components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() {
                if line.lowercased().contains(lowerQuery) {
                    results.append("\(path):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
                    if results.count >= maxResults {
                        return results.joined(separator: "\n")
                    }
                }
            }
        }

        return results.isEmpty ? "No matches for \(trimmedQuery)." : results.joined(separator: "\n")
    }

    private func fileInventory() -> [String] {
        let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: resolvedRootURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsPackageDescendants]
        ) else {
            return []
        }

        var paths: [String] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            guard let values = try? url.resourceValues(forKeys: resourceKeys) else { continue }
            if values.isDirectory == true {
                if Self.ignoredDirectoryNames.contains(name) || name.hasSuffix(".app") {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard values.isRegularFile == true,
                  isContextCandidate(url: url),
                  let path = relativePath(for: url) else {
                continue
            }
            paths.append(path)
        }

        return paths.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func safeURL(for path: String) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/") else { return nil }
        let url = resolvedRootURL.appendingPathComponent(trimmed)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard url.path == resolvedRootURL.path || url.path.hasPrefix(resolvedRootURL.path + "/") else {
            return nil
        }
        return url
    }

    private func relativePath(for url: URL) -> String? {
        let filePath = url.standardizedFileURL.resolvingSymlinksInPath().path
        let rootPath = resolvedRootURL.path
        guard filePath == rootPath || filePath.hasPrefix(rootPath + "/") else { return nil }
        if filePath == rootPath { return "." }
        return String(filePath.dropFirst(rootPath.count + 1))
    }

    private func isContextCandidate(url: URL) -> Bool {
        let name = url.lastPathComponent
        if Self.importantNames.contains(name) { return true }
        let ext = url.pathExtension.lowercased()
        return !ext.isEmpty && Self.sourceExtensions.contains(ext)
    }

    private func statusLabel(_ status: GitFileStatus) -> String {
        switch status {
        case .added: return "added"
        case .modified: return "modified"
        case .deleted: return "deleted"
        case .renamed: return "renamed"
        case .copied: return "copied"
        case .untracked: return "untracked"
        case .typeChanged: return "type changed"
        case .conflicted: return "conflicted"
        case .unknown(let value): return value
        }
    }

    private func clampedInt(_ value: Any?, defaultValue: Int, min: Int, max: Int) -> Int {
        let intValue = value as? Int ?? defaultValue
        return Swift.max(min, Swift.min(max, intValue))
    }

    private func clip(_ text: String, maxCharacters: Int) -> String {
        guard text.count > maxCharacters else { return text }
        return "\(text.prefix(maxCharacters))\n\n[Truncated]"
    }

    private func lastPathComponent(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    private func spokenSearchTerm(_ query: String) -> String {
        let cleaned = query
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        return cleaned.count > 40 ? "\(cleaned.prefix(40))" : cleaned
    }

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
}

private extension Array {
    func prefixArray(_ maxLength: Int) -> [Element] {
        Array(prefix(maxLength))
    }
}
