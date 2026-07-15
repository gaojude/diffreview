import Foundation

/// One project the user has opened, remembered for the welcome screen's recents list.
public struct RecentProject: Codable, Equatable, Sendable {
    /// Resolved project root path (the same identity projects attach by).
    public let path: String
    public let lastOpenedAt: Date

    public init(path: String, lastOpenedAt: Date) {
        self.path = path
        self.lastOpenedAt = lastOpenedAt
    }

    public var displayName: String { (path as NSString).lastPathComponent }
}

/// Recency policy for the welcome screen: most recent first, one entry per path, capped.
/// Pure — exercised directly by `MyIDESelfTest`.
public enum RecentProjects {
    /// Enough to cover a week of PR review without turning the welcome screen into a browser.
    public static let limit = 8

    public static func adding(
        _ path: String,
        at date: Date = Date(),
        to projects: [RecentProject]
    ) -> [RecentProject] {
        var next = projects.filter { $0.path != path }
        next.insert(RecentProject(path: path, lastOpenedAt: date), at: 0)
        if next.count > limit {
            next.removeLast(next.count - limit)
        }
        return next
    }
}

/// Disk-backed store for the recents list (one global file, unlike the per-repo review
/// stores). Loading prunes entries whose directory no longer exists, so deleted worktrees
/// and temp fixtures disappear on their own.
public struct RecentProjectsStore: Equatable {
    private let fileURL: URL

    public init(storageRoot: URL? = nil) {
        let baseURL = storageRoot ?? Self.defaultStorageRoot()
        self.fileURL = baseURL.appendingPathComponent("recent-projects.json", isDirectory: false)
    }

    public func load(directoryExists: (String) -> Bool = Self.directoryExists) -> [RecentProject] {
        guard let data = try? Data(contentsOf: fileURL),
              let projects = try? JSONDecoder().decode([RecentProject].self, from: data) else {
            return []
        }
        return projects.filter { directoryExists($0.path) }
    }

    public func save(_ projects: [RecentProject]) {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(projects)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            #if DEBUG
            fputs("MyIDE recent projects persistence failed: \(error)\n", stderr)
            #endif
        }
    }

    public static func directoryExists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func defaultStorageRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("MyIDE", isDirectory: true)
    }
}
