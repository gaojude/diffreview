import Foundation

/// Named login states — the Assistant's first-class "stay signed in" feature.
/// A saved session is agent-browser's own state snapshot (cookies +
/// local/session storage) written to a file we own, so the user can sign in
/// once, save it, and restore it into any later browser session (even a fresh
/// one) without typing credentials again.
///
/// Foundation-only: this type just manages the files and metadata. The actual
/// `agent-browser state save|load` calls live in `RealAgentBrowser`.
public struct BrowserSessionStore {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("MyIDE/Sessions", isDirectory: true)
    }

    /// A saved login, addressable by a human name and backed by one JSON file.
    public struct SavedSession: Equatable, Sendable, Identifiable {
        public var name: String
        public var slug: String
        public var savedAt: Date
        public var fileURL: URL
        public var id: String { slug }

        public init(name: String, slug: String, savedAt: Date, fileURL: URL) {
            self.name = name
            self.slug = slug
            self.savedAt = savedAt
            self.fileURL = fileURL
        }
    }

    /// Sidecar metadata so the list can show real names, not slugs.
    private struct Meta: Codable {
        var name: String
        var savedAt: Date
    }

    public static func slug(from name: String) -> String {
        Automation.slug(from: name)
    }

    /// Absolute path of the state file for a slug — handed to
    /// `agent-browser state save|load`.
    public func stateFileURL(forSlug slug: String) -> URL {
        directory.appendingPathComponent("\(slug).json")
    }

    /// Records the human name for a just-saved state file. Call after the
    /// `agent-browser state save` succeeds.
    @discardableResult
    public func recordMetadata(name: String, slug: String, savedAt: Date) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(Meta(name: name, savedAt: savedAt))
            try data.write(to: metaFileURL(forSlug: slug), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    public func prepareDirectory() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func list() -> [SavedSession] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var sessions: [SavedSession] = []
        for entry in entries where entry.pathExtension == "json" && !entry.lastPathComponent.hasSuffix(".meta.json") {
            let slug = entry.deletingPathExtension().lastPathComponent
            let meta = (try? Data(contentsOf: metaFileURL(forSlug: slug)))
                .flatMap { try? decoder.decode(Meta.self, from: $0) }
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            sessions.append(SavedSession(
                name: meta?.name ?? slug,
                slug: slug,
                savedAt: meta?.savedAt ?? modified ?? Date(timeIntervalSince1970: 0),
                fileURL: entry
            ))
        }
        return sessions.sorted { $0.savedAt > $1.savedAt }
    }

    @discardableResult
    public func delete(slug: String) -> Bool {
        let state = (try? FileManager.default.removeItem(at: stateFileURL(forSlug: slug))) != nil
        try? FileManager.default.removeItem(at: metaFileURL(forSlug: slug))
        return state
    }

    private func metaFileURL(forSlug slug: String) -> URL {
        directory.appendingPathComponent("\(slug).meta.json")
    }
}
