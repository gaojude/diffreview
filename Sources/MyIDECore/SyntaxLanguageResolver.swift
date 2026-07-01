import Foundation

/// Maps common file names and extensions to Highlight.js language identifiers.
public enum SyntaxLanguageResolver {
    private static let languageByFileName: [String: String] = [
        ".bashrc": "bash",
        ".zprofile": "bash",
        ".zshrc": "bash",
        "Dockerfile": "dockerfile",
        "Gemfile": "ruby",
        "Makefile": "makefile",
        "Package.swift": "swift",
        "Podfile": "ruby",
    ]

    private static let languageByExtension: [String: String] = [
        "c": "c",
        "cc": "cpp",
        "clj": "clojure",
        "cljs": "clojure",
        "cpp": "cpp",
        "cs": "csharp",
        "css": "css",
        "dart": "dart",
        "diff": "diff",
        "ex": "elixir",
        "exs": "elixir",
        "go": "go",
        "graphql": "graphql",
        "h": "objectivec",
        "hpp": "cpp",
        "html": "xml",
        "java": "java",
        "js": "javascript",
        "json": "json",
        "jsx": "javascript",
        "kt": "kotlin",
        "kts": "kotlin",
        "less": "less",
        "lua": "lua",
        "m": "objectivec",
        "md": "markdown",
        "mm": "objectivec",
        "php": "php",
        "pl": "perl",
        "plist": "xml",
        "pm": "perl",
        "py": "python",
        "rb": "ruby",
        "rs": "rust",
        "sass": "scss",
        "scala": "scala",
        "scss": "scss",
        "sh": "bash",
        "sql": "sql",
        "swift": "swift",
        "toml": "toml",
        "ts": "typescript",
        "tsx": "typescript",
        "vue": "xml",
        "xml": "xml",
        "yaml": "yaml",
        "yml": "yaml",
        "zsh": "bash",
    ]

    public static func languageName(for url: URL) -> String? {
        let fileName = url.lastPathComponent
        if let exactMatch = languageByFileName[fileName] {
            return exactMatch
        }

        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        return languageByExtension[ext]
    }
}
