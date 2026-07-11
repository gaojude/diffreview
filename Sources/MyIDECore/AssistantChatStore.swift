import Foundation

/// Persists the Assistant conversation so it survives app restarts: the visible
/// transcript (so the user sees their history) plus the SDK session id (so the
/// agent can `resume` and actually remember). Cleared by "New chat".
public struct AssistantChatStore {
    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("MyIDE/assistant-chat.json")
    }

    /// One transcript line, in a shape decoupled from the SwiftUI view model.
    public struct Line: Codable, Equatable, Sendable {
        public enum Role: String, Codable, Sendable { case user, assistant, tool, status }
        public var role: Role
        public var text: String
        public var detail: String?
        public var ok: Bool?

        public init(role: Role, text: String, detail: String? = nil, ok: Bool? = nil) {
            self.role = role
            self.text = text
            self.detail = detail
            self.ok = ok
        }
    }

    public struct Snapshot: Codable, Equatable, Sendable {
        public var sessionID: String?
        public var lines: [Line]

        public init(sessionID: String? = nil, lines: [Line] = []) {
            self.sessionID = sessionID
            self.lines = lines
        }
    }

    public func load() -> Snapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    public func save(_ snapshot: Snapshot) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
        } catch {
            // Best-effort persistence; a failed save must never disrupt chat.
        }
    }

    public func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

/// Tiny durable preferences for the Assistant (currently just the chosen model),
/// kept separate from the transcript so "New chat" doesn't reset them.
public struct AssistantPreferencesStore {
    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("MyIDE/assistant-preferences.json")
    }

    public struct Preferences: Codable, Equatable, Sendable {
        public var model: String?
        public init(model: String? = nil) { self.model = model }
    }

    public func load() -> Preferences {
        guard let data = try? Data(contentsOf: fileURL),
              let prefs = try? JSONDecoder().decode(Preferences.self, from: data) else {
            return Preferences()
        }
        return prefs
    }

    public func save(_ preferences: Preferences) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(preferences).write(to: fileURL, options: .atomic)
        } catch {
            // Best-effort.
        }
    }
}

/// The Assistant's model catalog — friendly labels mapped to model-id families,
/// resolved against whatever prefix the active configuration uses (e.g. the
/// Vercel gateway's `anthropic/claude-` vs. a bare `claude-`).
public enum AssistantModelCatalog {
    public struct Option: Equatable, Sendable {
        public var label: String
        public var family: String   // e.g. "opus-4-8"
        public init(label: String, family: String) {
            self.label = label
            self.family = family
        }
    }

    public static let options: [Option] = [
        Option(label: "Opus 4.8 — most capable", family: "opus-4-8"),
        Option(label: "Sonnet 5 — balanced", family: "sonnet-5"),
        Option(label: "Haiku 4.5 — fastest", family: "haiku-4-5"),
    ]

    private static let families = ["opus-4-8", "sonnet-5", "haiku-4-5", "fable-5"]

    /// The prefix in front of the family in a model id, e.g.
    /// "anthropic/claude-sonnet-5" → "anthropic/claude-". Falls back to
    /// "anthropic/claude-" (this environment's working gateway form).
    public static func prefix(from currentModel: String?) -> String {
        guard let model = currentModel else { return "anthropic/claude-" }
        for family in families where model.hasSuffix(family) {
            return String(model.dropLast(family.count))
        }
        return "anthropic/claude-"
    }

    /// Full model id for a family, matching the current model's prefix.
    public static func modelID(family: String, currentModel: String?) -> String {
        prefix(from: currentModel) + family
    }

    /// Which catalog option (if any) the current model id corresponds to.
    public static func family(of model: String?) -> String? {
        guard let model else { return nil }
        return families.first { model.hasSuffix($0) }
    }
}
