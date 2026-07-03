import Foundation

/// Recorded browser automations — the feature the insurance-claim skill pointed
/// at: an agent session is really a sequence of browser commands worth keeping,
/// so we capture it, store it as a replayable script, and generate a SKILL.md
/// playbook alongside (a skill that is literally a recorded automation).

// MARK: - Model

public struct AutomationStep: Codable, Equatable, Sendable {
    /// A replayable engine command in quoted-label form (`click "Sign in"`) —
    /// label selectors survive ref renumbering; `@eN` refs would not.
    public var command: String
    /// What the assistant was saying when it ran this step; becomes the step's
    /// annotation in the generated playbook.
    public var note: String?

    public init(command: String, note: String? = nil) {
        self.command = command
        self.note = note
    }
}

public struct Automation: Codable, Equatable, Sendable {
    public var name: String
    public var slug: String
    public var summary: String
    public var createdAt: Date
    public var steps: [AutomationStep]

    public init(name: String, slug: String, summary: String, createdAt: Date, steps: [AutomationStep]) {
        self.name = name
        self.slug = slug
        self.summary = summary
        self.createdAt = createdAt
        self.steps = steps
    }

    /// Lowercased, non-alphanumeric runs collapsed to single hyphens, trimmed —
    /// "Submit my massage claim!" → "submit-my-massage-claim".
    public static func slug(from name: String) -> String {
        var slug = ""
        var pendingHyphen = false
        for scalar in name.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if pendingHyphen && !slug.isEmpty { slug.append("-") }
                pendingHyphen = false
                slug.unicodeScalars.append(scalar)
            } else {
                pendingHyphen = true
            }
        }
        return slug.isEmpty ? "automation" : slug
    }
}

// MARK: - Recorder

/// Observes every command the engine executes during a session and keeps the
/// ones worth replaying: successful, state-mutating commands in their canonical
/// label form. Read-only verbs and failed attempts are noise — a replay should
/// be the clean path, not the agent's trial-and-error.
public final class AutomationRecorder {
    public private(set) var isRecording = false
    public private(set) var steps: [AutomationStep] = []

    /// Observer verbs for the simulated browser (waits are meaningless there).
    public static let simulatedReadOnlyVerbs: Set<String> = ["snapshot", "get", "wait", "sleep", "screenshot"]
    /// Real Chrome recordings KEEP `wait` — real replays fail without them.
    public static let realBrowserReadOnlyVerbs: Set<String> = ["snapshot", "get", "read", "screenshot", "sleep"]

    private let readOnlyVerbs: Set<String>

    public init(readOnlyVerbs: Set<String> = AutomationRecorder.simulatedReadOnlyVerbs) {
        self.readOnlyVerbs = readOnlyVerbs
    }

    public func start() { isRecording = true }
    public func stop() { isRecording = false }

    public func clear() {
        steps = []
    }

    public func observe(command: String, result: AgentBrowserCommandResult, note: String?) {
        guard isRecording, result.ok else { return }
        let verb = command.split(separator: " ").first.map(String.init) ?? ""
        guard !verb.isEmpty, !readOnlyVerbs.contains(verb) else { return }
        // `open` has no element target, so its typed form is already canonical.
        let stored = result.canonicalCommand ?? command
        steps.append(AutomationStep(command: stored, note: note))
    }
}

// MARK: - Store

public struct AutomationStore {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("MyIDE/Automations", isDirectory: true)
    }

    public func list() -> [Automation] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        let automations = entries.compactMap { entry -> Automation? in
            let file = entry.appendingPathComponent("automation.json")
            guard let data = try? Data(contentsOf: file) else { return nil }
            return try? decoder.decode(Automation.self, from: data)
        }
        return automations.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public enum SaveResult {
        case saved(URL)
        case failed(String)
    }

    @discardableResult
    public func save(_ automation: Automation) -> SaveResult {
        let folder = directory.appendingPathComponent(automation.slug, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(automation)
            try data.write(to: folder.appendingPathComponent("automation.json"), options: .atomic)
            let markdown = Self.skillMarkdown(for: automation)
            try Data(markdown.utf8).write(to: folder.appendingPathComponent("SKILL.md"), options: .atomic)
            return .saved(folder)
        } catch {
            return .failed("Could not save the automation: \(error.localizedDescription)")
        }
    }

    @discardableResult
    public func delete(slug: String) -> Bool {
        let folder = directory.appendingPathComponent(slug, isDirectory: true)
        return (try? FileManager.default.removeItem(at: folder)) != nil
    }

    /// The playbook twin of the recorded script, in the same shape as the
    /// hand-written skills this feature grew out of.
    public static func skillMarkdown(for automation: Automation) -> String {
        var lines: [String] = [
            "---",
            "name: \(automation.slug)",
            "description: \(automation.summary)",
            "---",
            "",
            "# \(automation.name)",
            "",
            "## What this automation does",
            "",
            automation.summary,
            "",
            "## Steps",
            "",
        ]
        for (index, step) in automation.steps.enumerated() {
            var line = "\(index + 1). `\(step.command)`"
            if let note = step.note, !note.isEmpty {
                line += " — \(note)"
            }
            lines.append(line)
        }
        lines += [
            "",
            "## Replay",
            "",
            "Open MyIDE → Assistant (⇧⌘A) → Automations → Run \"\(automation.name)\".",
            "",
        ]
        return lines.joined(separator: "\n")
    }
}

// MARK: - Replay

public enum AutomationReplay {
    public struct Outcome: Equatable {
        public var completedSteps: Int
        public var failureMessage: String?
        public var succeeded: Bool { failureMessage == nil }

        public init(completedSteps: Int, failureMessage: String?) {
            self.completedSteps = completedSteps
            self.failureMessage = failureMessage
        }
    }

    /// Runs the automation's steps in order, stopping at the first failure —
    /// a stale recording should halt loudly, not plough on against the wrong
    /// page. Pacing (delays, UI highlights) is the caller's concern.
    @discardableResult
    public static func run(
        _ automation: Automation,
        on engine: AgentBrowserEngine,
        onStep: ((Int, AutomationStep, AgentBrowserCommandResult) -> Void)? = nil
    ) -> Outcome {
        for (index, step) in automation.steps.enumerated() {
            let result = engine.execute(step.command)
            onStep?(index, step, result)
            if !result.ok {
                return Outcome(
                    completedSteps: index,
                    failureMessage: "Step \(index + 1) (`\(step.command)`) failed: \(result.output)"
                )
            }
        }
        return Outcome(completedSteps: automation.steps.count, failureMessage: nil)
    }
}
