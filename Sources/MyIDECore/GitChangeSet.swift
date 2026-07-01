import Foundation

/// Git status for a path included in the branch/worktree change set.
public enum GitFileStatus: Equatable, Hashable, Sendable {
    case added
    case modified
    case deleted
    case renamed
    case copied
    case untracked
    case typeChanged
    case conflicted
    case unknown(String)
}

/// One changed file, with paths normalized for both display and repository access.
public struct GitChangedFile: Equatable, Hashable, Sendable {
    /// Path relative to the opened root. This is what the sidebar tree renders.
    public let path: String

    /// Path relative to the Git repository root.
    public let repositoryPath: String

    /// Best local file URL for opening the current working-tree version.
    public let url: URL

    /// Previous display path for renames/copies, when Git reported one.
    public let oldPath: String?

    public let status: GitFileStatus

    public init(path: String, repositoryPath: String, url: URL, oldPath: String?, status: GitFileStatus) {
        self.path = path
        self.repositoryPath = repositoryPath
        self.url = url
        self.oldPath = oldPath
        self.status = status
    }
}

/// The branch-scoped set of files shown in the sidebar.
public struct GitChangeContext: Equatable, Sendable {
    public let repositoryRootURL: URL
    public let openedRootURL: URL
    public let branchName: String
    public let baseRef: String?
    public let upstreamRef: String?
    public let files: [GitChangedFile]

    public init(
        repositoryRootURL: URL,
        openedRootURL: URL,
        branchName: String,
        baseRef: String?,
        upstreamRef: String?,
        files: [GitChangedFile]
    ) {
        self.repositoryRootURL = repositoryRootURL
        self.openedRootURL = openedRootURL
        self.branchName = branchName
        self.baseRef = baseRef
        self.upstreamRef = upstreamRef
        self.files = files
    }
}

public enum GitChangeLoadResult: Equatable, Sendable {
    case repository(GitChangeContext)
    case notRepository(String)
}

public struct GitFileDiff: Equatable, Sendable {
    public let file: GitChangedFile
    public let patch: String

    public init(file: GitChangedFile, patch: String) {
        self.file = file
        self.patch = patch
    }
}

public enum GitDiffLoadResult: Equatable, Sendable {
    case diff(GitFileDiff)
    case noDiff(GitChangedFile)
    case tooLarge(bytes: Int)
    case fileNotInChangeSet
    case unavailable(String)
}

/// Reads a Git repository as a branch/worktree change set rather than as a raw directory tree.
public enum GitChangeSet {
    public static let maxPatchSize: Int = 5 * 1024 * 1024

    public static func load(for openedRootURL: URL) -> GitChangeLoadResult {
        let openedRoot = openedRootURL.standardizedFileURL.resolvingSymlinksInPath()
        guard let repositoryRoot = repositoryRoot(for: openedRoot) else {
            return .notRepository("No Git repository found.")
        }

        let branchName = currentBranch(in: repositoryRoot)
        let upstreamRef = optionalOutput(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], in: repositoryRoot)
        let baseRef = discoverBaseRef(upstreamRef: upstreamRef, in: repositoryRoot)
        let openedPrefix = repositoryRelativePath(for: openedRoot, repositoryRoot: repositoryRoot)

        var changesByPath: [String: GitChangedFile] = [:]

        if let baseRef {
            let branchDiff = runGit(["diff", "--name-status", "-M", "-z", "\(baseRef)...HEAD"], in: repositoryRoot)
            if branchDiff?.exitCode == 0, let stdout = branchDiff?.stdout {
                merge(parseNameStatus(stdout), into: &changesByPath, repositoryRoot: repositoryRoot, openedPrefix: openedPrefix)
            }
        }

        let workingTree = runGit(["status", "--porcelain=v1", "-z", "--untracked-files=all"], in: repositoryRoot)
        if workingTree?.exitCode == 0, let stdout = workingTree?.stdout {
            merge(parsePorcelainStatus(stdout), into: &changesByPath, repositoryRoot: repositoryRoot, openedPrefix: openedPrefix)
        }

        let files = changesByPath.values.sorted { lhs, rhs in
            lhs.path.localizedCaseInsensitiveCompare(rhs.path) == .orderedAscending
        }

        return .repository(GitChangeContext(
            repositoryRootURL: repositoryRoot,
            openedRootURL: openedRoot,
            branchName: branchName,
            baseRef: baseRef,
            upstreamRef: upstreamRef,
            files: files
        ))
    }

    public static func loadDiff(for fileURL: URL, in context: GitChangeContext) -> GitDiffLoadResult {
        guard let file = changedFile(for: fileURL, in: context) else {
            return .fileNotInChangeSet
        }

        let result: GitCommandResult?
        if case .untracked = file.status {
            result = runGit(
                ["diff", "--no-ext-diff", "--no-color", "--no-index", "--", "/dev/null", file.repositoryPath],
                in: context.repositoryRootURL
            )
        } else if let baseRef = context.baseRef {
            let diffBase = mergeBase(for: baseRef, in: context.repositoryRootURL) ?? baseRef
            result = runGit(
                ["diff", "--no-ext-diff", "--no-color", "--find-renames", "--unified=80", diffBase, "--", file.repositoryPath],
                in: context.repositoryRootURL
            )
        } else {
            result = runGit(
                ["diff", "--no-ext-diff", "--no-color", "--find-renames", "--unified=80", "HEAD", "--", file.repositoryPath],
                in: context.repositoryRootURL
            )
        }

        guard let result else {
            return .unavailable("Could not run git diff.")
        }

        if result.stdout.count > maxPatchSize {
            return .tooLarge(bytes: result.stdout.count)
        }

        let allowedExitCodes: Set<Int32> = file.status == .untracked ? [0, 1] : [0]
        guard allowedExitCodes.contains(result.exitCode) else {
            let message = String(data: result.stderr, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .unavailable(message?.isEmpty == false ? message! : "Git diff failed.")
        }

        let patch = String(data: result.stdout, encoding: .utf8) ?? String(decoding: result.stdout, as: UTF8.self)
        if patch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .noDiff(file)
        }
        return .diff(GitFileDiff(file: file, patch: patch))
    }

    private static func changedFile(for fileURL: URL, in context: GitChangeContext) -> GitChangedFile? {
        let selectedPath = fileURL.standardizedFileURL.path
        return context.files.first { $0.url.standardizedFileURL.path == selectedPath }
    }

    // MARK: - Repository metadata

    private static func repositoryRoot(for openedRoot: URL) -> URL? {
        guard let result = runGit(["rev-parse", "--show-toplevel"], in: openedRoot),
              result.exitCode == 0,
              let path = result.trimmedOutput,
              !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
    }

    private static func currentBranch(in repositoryRoot: URL) -> String {
        if let branch = optionalOutput(["branch", "--show-current"], in: repositoryRoot), !branch.isEmpty {
            return branch
        }
        if let shortSHA = optionalOutput(["rev-parse", "--short", "HEAD"], in: repositoryRoot), !shortSHA.isEmpty {
            return "Detached \(shortSHA)"
        }
        return "Unborn branch"
    }

    private static func discoverBaseRef(upstreamRef: String?, in repositoryRoot: URL) -> String? {
        let originHead = optionalOutput(["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"], in: repositoryRoot)
        let candidates = unique([
            originHead,
            "origin/main",
            "origin/master",
            "main",
            "master",
            "origin/trunk",
            "trunk",
            "origin/develop",
            "develop",
            upstreamRef,
        ].compactMap { $0 })

        return candidates.first { candidate in
            refExists(candidate, in: repositoryRoot) && hasMergeBase(candidate, in: repositoryRoot)
        }
    }

    private static func refExists(_ ref: String, in repositoryRoot: URL) -> Bool {
        runGit(["rev-parse", "--verify", "--quiet", "\(ref)^{commit}"], in: repositoryRoot)?.exitCode == 0
    }

    private static func hasMergeBase(_ ref: String, in repositoryRoot: URL) -> Bool {
        runGit(["merge-base", ref, "HEAD"], in: repositoryRoot)?.exitCode == 0
    }

    private static func mergeBase(for ref: String, in repositoryRoot: URL) -> String? {
        optionalOutput(["merge-base", ref, "HEAD"], in: repositoryRoot)
    }

    private static func optionalOutput(_ arguments: [String], in repositoryRoot: URL) -> String? {
        guard let result = runGit(arguments, in: repositoryRoot), result.exitCode == 0 else { return nil }
        return result.trimmedOutput
    }

    // MARK: - Parsing

    private struct RawGitChange {
        let repositoryPath: String
        let oldRepositoryPath: String?
        let status: GitFileStatus
    }

    private static func parseNameStatus(_ data: Data) -> [RawGitChange] {
        let fields = nullSeparatedStrings(data)
        var index = 0
        var changes: [RawGitChange] = []

        while index < fields.count {
            let code = fields[index]
            index += 1
            guard let first = code.first else { continue }

            if first == "R" || first == "C" {
                guard index + 1 < fields.count else { break }
                let oldPath = fields[index]
                let newPath = fields[index + 1]
                index += 2
                changes.append(RawGitChange(
                    repositoryPath: newPath,
                    oldRepositoryPath: oldPath,
                    status: statusFromNameStatus(code)
                ))
            } else {
                guard index < fields.count else { break }
                let path = fields[index]
                index += 1
                changes.append(RawGitChange(
                    repositoryPath: path,
                    oldRepositoryPath: nil,
                    status: statusFromNameStatus(code)
                ))
            }
        }

        return changes
    }

    private static func parsePorcelainStatus(_ data: Data) -> [RawGitChange] {
        let records = nullSeparatedStrings(data)
        var index = 0
        var changes: [RawGitChange] = []

        while index < records.count {
            let record = records[index]
            index += 1
            guard record.count >= 4 else { continue }

            let statusPair = String(record.prefix(2))
            let pathStart = record.index(record.startIndex, offsetBy: 3)
            let path = String(record[pathStart...])
            var oldPath: String?

            if statusPair.contains("R") || statusPair.contains("C") {
                if index < records.count {
                    oldPath = records[index]
                    index += 1
                }
            }

            changes.append(RawGitChange(
                repositoryPath: path,
                oldRepositoryPath: oldPath,
                status: statusFromPorcelain(statusPair)
            ))
        }

        return changes
    }

    private static func statusFromNameStatus(_ code: String) -> GitFileStatus {
        switch code.first {
        case "A": return .added
        case "M": return .modified
        case "D": return .deleted
        case "R": return .renamed
        case "C": return .copied
        case "T": return .typeChanged
        case "U": return .conflicted
        default: return .unknown(code)
        }
    }

    private static func statusFromPorcelain(_ statusPair: String) -> GitFileStatus {
        if statusPair == "??" { return .untracked }
        if statusPair.contains("U") { return .conflicted }
        if statusPair.contains("D") { return .deleted }
        if statusPair.contains("R") { return .renamed }
        if statusPair.contains("C") { return .copied }
        if statusPair.contains("A") { return .added }
        if statusPair.contains("M") { return .modified }
        if statusPair.contains("T") { return .typeChanged }
        return .unknown(statusPair)
    }

    private static func nullSeparatedStrings(_ data: Data) -> [String] {
        data.split(separator: 0, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }
    }

    // MARK: - Path filtering

    private static func merge(
        _ rawChanges: [RawGitChange],
        into changesByPath: inout [String: GitChangedFile],
        repositoryRoot: URL,
        openedPrefix: String?
    ) {
        for raw in rawChanges {
            guard let visiblePath = displayPath(for: raw.repositoryPath, openedPrefix: openedPrefix),
                  !visiblePath.isEmpty else {
                continue
            }

            let oldPath = raw.oldRepositoryPath.flatMap {
                displayPath(for: $0, openedPrefix: openedPrefix)
            }
            let fileURL = URL(fileURLWithPath: raw.repositoryPath, relativeTo: repositoryRoot).standardizedFileURL
            changesByPath[raw.repositoryPath] = GitChangedFile(
                path: visiblePath,
                repositoryPath: raw.repositoryPath,
                url: fileURL,
                oldPath: oldPath,
                status: raw.status
            )
        }
    }

    private static func repositoryRelativePath(for openedRoot: URL, repositoryRoot: URL) -> String? {
        let rootPath = repositoryRoot.path
        let openedPath = openedRoot.path
        if openedPath == rootPath { return "" }
        guard openedPath.hasPrefix(rootPath + "/") else { return nil }
        return String(openedPath.dropFirst(rootPath.count + 1))
    }

    private static func displayPath(for repositoryPath: String, openedPrefix: String?) -> String? {
        guard let openedPrefix else { return nil }
        if openedPrefix.isEmpty { return repositoryPath }
        guard repositoryPath.hasPrefix(openedPrefix + "/") else { return nil }
        return String(repositoryPath.dropFirst(openedPrefix.count + 1))
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    // MARK: - Git command runner

    private struct GitCommandResult {
        let exitCode: Int32
        let stdout: Data
        let stderr: Data

        var trimmedOutput: String? {
            String(data: stdout, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func runGit(_ arguments: [String], in directory: URL) -> GitCommandResult? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", directory.path] + arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        return GitCommandResult(
            exitCode: process.terminationStatus,
            stdout: stdout.fileHandleForReading.readDataToEndOfFile(),
            stderr: stderr.fileHandleForReading.readDataToEndOfFile()
        )
    }
}
