import Foundation

/// Review-progress state for one branch change set: which files are collapsed (reviewed) and
/// where the reader left off. Restored when the same repo+branch is opened again.
public struct ChangeSetViewState: Codable, Equatable, Sendable {
    /// Display paths (relative to the opened root) of files whose diffs are collapsed.
    public var collapsedPaths: [String]
    /// Display path of the file that was at the top of the viewport.
    public var anchorPath: String?
    /// 0-based line offset from that file's header line (collapse-independent).
    public var anchorLineOffset: Int?

    public init(collapsedPaths: [String] = [], anchorPath: String? = nil, anchorLineOffset: Int? = nil) {
        self.collapsedPaths = collapsedPaths
        self.anchorPath = anchorPath
        self.anchorLineOffset = anchorLineOffset
    }

    public static let empty = ChangeSetViewState()
}

/// Disk-backed store for `ChangeSetViewState`, keyed by repo root + branch (same scoping as
/// `ReviewCommentStore`, separate directory).
public struct ChangeSetViewStateStore: Equatable {
    public let id: String
    private let fileURL: URL

    public init(rootURL: URL, branchName: String, storageRoot: URL? = nil) {
        let resolvedRoot = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let scope = "\(resolvedRoot.path)#\(branchName)"
        self.id = Self.stableHexID(for: scope)

        let baseURL = storageRoot ?? Self.defaultStorageRoot()
        self.fileURL = baseURL
            .appendingPathComponent(id, isDirectory: false)
            .appendingPathExtension("json")
    }

    public func load() -> ChangeSetViewState {
        guard let data = try? Data(contentsOf: fileURL) else {
            return .empty
        }
        return (try? JSONDecoder().decode(ChangeSetViewState.self, from: data)) ?? .empty
    }

    public func save(_ state: ChangeSetViewState) {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            #if DEBUG
            fputs("MyIDE change-set view state persistence failed: \(error)\n", stderr)
            #endif
        }
    }

    private static func defaultStorageRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("MyIDE/ChangeSetViewState", isDirectory: true)
    }

    private static func stableHexID(for text: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
