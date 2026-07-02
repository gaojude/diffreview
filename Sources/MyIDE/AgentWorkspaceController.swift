import Foundation
import Combine
import MyIDECore

/// One line of the terminal pane's session transcript.
struct AgentTranscriptEntry: Identifiable {
    enum Kind {
        case user
        case assistant
        case tool(ok: Bool)
        case status
    }

    let id = UUID()
    var kind: Kind
    var text: String
    /// Short secondary line (a tool's result message, an error, …).
    var detail: String?
}

/// Owns the agent workspace session: the in-process browser engine + demo
/// portal, the harness sidecar that runs the Claude session, the recorder that
/// turns sessions into automations, and the store they live in. Everything the
/// three panes render comes from here.
@MainActor
final class AgentWorkspaceController: ObservableObject {
    enum Phase: Equatable {
        case connecting
        case ready
        case working
        case replaying(step: Int, of: Int)
        case offline(String)
    }

    enum Mode: Equatable {
        case none, mock, live
    }

    @Published private(set) var transcript: [AgentTranscriptEntry] = []
    @Published private(set) var page: BrowserPage?
    @Published private(set) var lastActedElementID: String?
    /// Bumped on every browser action so the pane can re-fire its highlight flash.
    @Published private(set) var actionRevision = 0
    @Published private(set) var automations: [Automation] = []
    @Published private(set) var phase: Phase = .connecting
    @Published private(set) var mode: Mode = .none
    @Published private(set) var canSaveAutomation = false
    @Published var input = ""

    private let portal = MapleLifePortal()
    private let engine: AgentBrowserEngine
    private let recorder = AutomationRecorder()
    private let store: AutomationStore
    private let client = AgentHarnessClient()
    private var lastAssistantText: String?
    private var replayTask: Task<Void, Never>?

    init(store: AutomationStore = AutomationStore(directory: AutomationStore.defaultDirectory())) {
        self.store = store
        engine = AgentBrowserEngine(sites: [portal])
        engine.onEvent = { [weak self] event in
            self?.handleEngineEvent(event)
        }
        automations = store.list()
        recorder.start()
    }

    /// Plain-English status for the chip above the terminal.
    var statusText: String {
        switch phase {
        case .connecting: return "Starting up…"
        case .ready: return mode == .mock ? "Ready — demo mode" : "Ready"
        case .working: return "Working in the browser…"
        case .replaying(let step, let of): return "Replaying — step \(step) of \(of)"
        case .offline: return "Offline"
        }
    }

    var isBusy: Bool {
        switch phase {
        case .working, .replaying: return true
        case .connecting, .ready, .offline: return false
        }
    }

    var canSendPrompt: Bool {
        phase == .ready && mode != .none
    }

    // MARK: - Session lifecycle

    /// Locates node + the harness sidecar and starts the session. Demo (mock)
    /// mode is the default whenever the Claude Agent SDK isn't installed, so the
    /// workspace works out of the box with no API key and no npm install.
    func connect() {
        guard mode == .none, client.isRunning == false else { return }
        let environment = ProcessInfo.processInfo.environment

        guard let node = AgentHarnessLocator.findNode(environment: environment) else {
            phase = .offline("Node.js is not installed")
            appendStatus("I couldn't find Node.js, so live sessions are off — but saved automations still replay with one click.")
            return
        }
        guard let script = locateHarnessScript(environment: environment) else {
            phase = .offline("Harness not found")
            appendStatus("I couldn't find my harness files (harness/agent-harness.mjs) — saved automations still replay fine.")
            return
        }

        let harnessDirectory = script.deletingLastPathComponent()
        let sdkPath = harnessDirectory.appendingPathComponent("node_modules/@anthropic-ai/claude-agent-sdk").path
        let sdkInstalled = FileManager.default.fileExists(atPath: sdkPath)
        let useMock = environment["MYIDE_AGENT_MOCK"] == "1" || !sdkInstalled

        var arguments: [String] = []
        if useMock {
            arguments = ["--mock", harnessDirectory.appendingPathComponent("scenarios/insurance-claim.json").path]
        }

        client.onMessage = { [weak self] message in
            Task { @MainActor in self?.handle(message) }
        }
        client.onTermination = { [weak self] code in
            Task { @MainActor in self?.handleTermination(code) }
        }

        switch client.launch(AgentHarnessClient.LaunchSpec(nodeURL: node, scriptURL: script, arguments: arguments)) {
        case .running:
            mode = useMock ? .mock : .live
            phase = .ready
            appendStatus(useMock
                ? "Hi! I'm in demo mode. Ask me anything — try “Submit my massage claim” — or run a saved automation on the left."
                : "Hi! Tell me what you'd like me to do in the browser, or run a saved automation on the left.")
        case .failed(let message):
            phase = .offline(message)
            appendStatus("I couldn't start my helper: \(message)")
        }
    }

    private func locateHarnessScript(environment: [String: String]) -> URL? {
        if let override = environment["MYIDE_HARNESS_DIR"] {
            let candidate = URL(fileURLWithPath: override, isDirectory: true).appendingPathComponent("agent-harness.mjs")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        var starts: [URL] = []
        if let resources = Bundle.main.resourceURL {
            starts.append(resources)
        }
        starts.append(Bundle.main.bundleURL)
        starts.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
        return AgentHarnessLocator.findHarnessScript(startingFrom: starts)
    }

    func stop() {
        replayTask?.cancel()
        replayTask = nil
        client.stop()
    }

    // MARK: - User actions

    func sendPrompt() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, canSendPrompt else { return }
        input = ""
        transcript.append(AgentTranscriptEntry(kind: .user, text: text))
        phase = .working
        client.send(.user(text))
    }

    /// Replays a saved automation directly on the engine — no agent, no network,
    /// deterministic. Paced so a person can watch the browser do the work.
    func runAutomation(_ automation: Automation) {
        guard replayTask == nil, !isBusy else { return }
        recorder.stop()
        engine.reset()
        appendStatus("Replaying “\(automation.name)” — watch the browser on the right.")
        phase = .replaying(step: 0, of: automation.steps.count)

        replayTask = Task { [weak self] in
            guard let self else { return }
            var failureMessage: String?
            for (index, step) in automation.steps.enumerated() {
                if Task.isCancelled { break }
                self.phase = .replaying(step: index + 1, of: automation.steps.count)
                let result = self.engine.execute(step.command)
                if !result.ok {
                    failureMessage = "Step \(index + 1) didn't work anymore: \(result.output)"
                    break
                }
                try? await Task.sleep(nanoseconds: 350_000_000)
            }
            if let failureMessage {
                self.appendStatus("I had to stop the replay — \(failureMessage)")
            } else if !Task.isCancelled {
                self.appendStatus("Done! “\(automation.name)” finished all \(automation.steps.count) steps.")
            }
            self.phase = (self.mode == .none) ? .offline("Assistant offline") : .ready
            self.recorder.start()
            self.replayTask = nil
        }
    }

    func saveRecording(name: String, summary: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !recorder.steps.isEmpty else { return }
        let automation = Automation(
            name: trimmedName,
            slug: Automation.slug(from: trimmedName),
            summary: summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Recorded with the assistant."
                : summary.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAt: Date(),
            steps: recorder.steps
        )
        switch store.save(automation) {
        case .saved:
            automations = store.list()
            recorder.clear()
            canSaveAutomation = false
            appendStatus("Saved “\(trimmedName)”. Next time it's one click in the list on the left.")
        case .failed(let message):
            appendStatus(message)
        }
    }

    func deleteAutomation(_ automation: Automation) {
        store.delete(slug: automation.slug)
        automations = store.list()
    }

    // MARK: - Harness messages

    private func handle(_ message: HarnessMessage) {
        switch message {
        case .hello:
            break // mode is decided at launch; hello just confirms liveness
        case .state(let value):
            if replayTask == nil {
                phase = (value == "working") ? .working : .ready
            }
        case .text(let text):
            lastAssistantText = text
            transcript.append(AgentTranscriptEntry(kind: .assistant, text: text))
        case .toolUse(let id, let command):
            let result = engine.execute(command)
            client.send(.toolResult(id: id, ok: result.ok, output: result.output))
        case .turnEnd:
            if replayTask == nil {
                phase = .ready
            }
            canSaveAutomation = !recorder.steps.isEmpty
        case .fatal(let message):
            phase = .offline(message)
            appendStatus("My helper hit a problem: \(message)")
        }
    }

    private func handleTermination(_ code: Int32) {
        guard mode != .none else { return }
        mode = .none
        if case .offline = phase {} else {
            phase = .offline("Assistant stopped")
            if code != 0 {
                appendStatus("My helper stopped unexpectedly (code \(code)) — saved automations still replay fine.")
            }
        }
    }

    // MARK: - Engine events

    private func handleEngineEvent(_ event: AgentBrowserEngineEvent) {
        switch event {
        case .pageChanged:
            page = engine.currentPage
            lastActedElementID = engine.lastActedElementID
            actionRevision += 1
        case .commandExecuted(let command, let result):
            recorder.observe(command: command, result: result, note: shortNote())
            appendToolLine(command: command, result: result)
            // Failed actions still deserve the highlight flash (that's where the
            // agent is struggling) and a fresh render.
            page = engine.currentPage
            lastActedElementID = engine.lastActedElementID
            actionRevision += 1
        }
    }

    private func shortNote() -> String? {
        guard let text = lastAssistantText else { return nil }
        return text.count <= 140 ? text : String(text.prefix(139)) + "…"
    }

    private func appendToolLine(command: String, result: AgentBrowserCommandResult) {
        let verb = command.split(separator: " ").first.map(String.init) ?? ""
        var detail: String?
        if !result.ok {
            detail = result.output
        } else if !["snapshot", "screenshot"].contains(verb), result.output.count <= 90 {
            detail = result.output
        }
        transcript.append(AgentTranscriptEntry(kind: .tool(ok: result.ok), text: "agent-browser \(command)", detail: detail))
    }

    private func appendStatus(_ text: String) {
        transcript.append(AgentTranscriptEntry(kind: .status, text: text))
    }
}
