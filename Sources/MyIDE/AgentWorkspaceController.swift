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

    /// Real-Chrome session state (browserIsReal == true): the browser is an
    /// actual Chrome window, so the pane shows a live action feed instead of a
    /// rendered page.
    @Published private(set) var browserIsReal = false
    @Published private(set) var lastRealAction: String?
    @Published private(set) var currentRealURL: String?
    @Published private(set) var isExecutingCommand = false

    private let portal = MapleLifePortal()
    private let engine: AgentBrowserEngine
    private var recorder = AutomationRecorder()
    private let store: AutomationStore
    private let client = AgentHarnessClient()
    private var realBrowser: RealAgentBrowser?
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
        case .ready:
            if mode == .mock { return "Ready — demo mode" }
            return browserIsReal ? "Ready — real browser" : "Ready"
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
        let useMock = environment["MYIDE_AGENT_MOCK"] == "1" || !Self.isLiveCapable(script)

        // Live sessions get a REAL Chrome browser whenever the agent-browser
        // CLI is installed; the simulated portal stays as the offline demo.
        var realExecutor: RealAgentBrowser?
        if !useMock,
           environment["MYIDE_REAL_BROWSER"] != "0",
           let cli = AgentHarnessLocator.findAgentBrowserCLI(environment: environment) {
            realExecutor = RealAgentBrowser(cliURL: cli)
        }

        var arguments: [String] = []
        if useMock {
            arguments = ["--mock", harnessDirectory.appendingPathComponent("scenarios/insurance-claim.json").path]
        } else {
            if realExecutor != nil {
                arguments = ["--real"]
            }
            // Explicit model override; otherwise the SDK resolves from
            // ANTHROPIC_MODEL / the claude CLI's default.
            if let model = environment["MYIDE_ASSISTANT_MODEL"]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !model.isEmpty {
                arguments += ["--model", model]
            }
        }

        // Real CLI calls block for seconds, so they run right on the client's
        // serial delivery queue (keeping commands ordered) instead of the main
        // actor; only the UI bookkeeping hops to main.
        let liveClient = client
        client.onMessage = { [weak self] message in
            if let executor = realExecutor, case .toolUse(let id, let command) = message {
                Task { @MainActor in self?.noteRealCommandStarted(command) }
                let result = executor.execute(command)
                liveClient.send(.toolResult(id: id, ok: result.ok, output: result.output))
                Task { @MainActor in self?.finishRealCommand(command: command, result: result) }
                return
            }
            Task { @MainActor in self?.handle(message) }
        }
        client.onTermination = { [weak self] code in
            Task { @MainActor in self?.handleTermination(code) }
        }

        switch client.launch(AgentHarnessClient.LaunchSpec(nodeURL: node, scriptURL: script, arguments: arguments)) {
        case .running:
            realBrowser = realExecutor
            browserIsReal = realExecutor != nil
            if realExecutor != nil {
                // Real recordings keep their waits — replays on live sites
                // fail without them.
                recorder = AutomationRecorder(readOnlyVerbs: AutomationRecorder.realBrowserReadOnlyVerbs)
                recorder.start()
            }
            mode = useMock ? .mock : .live
            phase = .ready
            if useMock {
                appendStatus("Hi! I'm in demo mode. Ask me anything — try “Submit my massage claim”.")
            } else if browserIsReal {
                appendStatus("Hi! Tell me what to do on the web — I'll open a Chrome window you can watch. If a site needs your password, I'll hand the keyboard to you.")
            } else {
                appendStatus("Hi! Tell me what you'd like me to do in the browser.")
            }
            // Scripted entry point: launch with a goal and the session starts
            // itself — no typing needed (demos, tests, "open and go" shortcuts).
            if let kickoff = environment["MYIDE_ASSISTANT_PROMPT"]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !kickoff.isEmpty {
                input = kickoff
                sendPrompt()
            }
        case .failed(let message):
            phase = .offline(message)
            appendStatus("I couldn't start my helper: \(message)")
        }
    }

    /// Gathers every harness copy in sight and prefers a live-capable one (SDK
    /// installed next to it). The bundle ships a lean copy without node_modules
    /// for demo mode; a repo checkout where the user ran `npm install` should
    /// win over it so "install once, get live sessions" holds from any launch.
    private func locateHarnessScript(environment: [String: String]) -> URL? {
        var candidates: [URL] = []
        if let override = environment["MYIDE_HARNESS_DIR"] {
            let candidate = URL(fileURLWithPath: override, isDirectory: true).appendingPathComponent("agent-harness.mjs")
            if FileManager.default.fileExists(atPath: candidate.path) {
                candidates.append(candidate.standardizedFileURL)
            }
        }
        var starts: [URL] = []
        if let resources = Bundle.main.resourceURL {
            starts.append(resources)
        }
        starts.append(Bundle.main.bundleURL)
        starts.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
        for start in starts {
            if let found = AgentHarnessLocator.findHarnessScript(startingFrom: [start]),
               !candidates.contains(found.standardizedFileURL) {
                candidates.append(found.standardizedFileURL)
            }
        }
        return candidates.first(where: Self.isLiveCapable) ?? candidates.first
    }

    private static func isLiveCapable(_ script: URL) -> Bool {
        let sdk = script.deletingLastPathComponent()
            .appendingPathComponent("node_modules/@anthropic-ai/claude-agent-sdk")
        return FileManager.default.fileExists(atPath: sdk.path)
    }

    func stop() {
        replayTask?.cancel()
        replayTask = nil
        if let real = realBrowser {
            Task.detached { real.closeSession() }
        }
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
        let real = realBrowser
        if real == nil {
            engine.reset()
        }
        appendStatus(real == nil
            ? "Replaying “\(automation.name)”."
            : "Replaying “\(automation.name)” — watch the Chrome window.")
        phase = .replaying(step: 0, of: automation.steps.count)

        replayTask = Task { [weak self] in
            guard let self else { return }
            if let real {
                // Fresh browser session so the recording starts from its `open`.
                await Task.detached { real.closeSession() }.value
            }
            var failureMessage: String?
            for (index, step) in automation.steps.enumerated() {
                if Task.isCancelled { break }
                self.phase = .replaying(step: index + 1, of: automation.steps.count)
                let result: AgentBrowserCommandResult
                if let real {
                    self.noteRealCommandStarted(step.command)
                    result = await Task.detached { real.execute(step.command) }.value
                    self.finishRealCommand(command: step.command, result: result)
                } else {
                    result = self.engine.execute(step.command)
                }
                if !result.ok {
                    failureMessage = "Step \(index + 1) didn't work anymore: \(result.output)"
                    break
                }
                try? await Task.sleep(nanoseconds: real == nil ? 350_000_000 : 120_000_000)
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

    // MARK: - Real-browser bookkeeping

    private func noteRealCommandStarted(_ command: String) {
        isExecutingCommand = true
        lastRealAction = command
    }

    private func finishRealCommand(command: String, result: AgentBrowserCommandResult) {
        isExecutingCommand = false
        lastRealAction = command
        recorder.observe(command: command, result: result, note: shortNote())
        appendToolLine(command: command, result: result)
        let tokens = command.split(separator: " ").map(String.init)
        if tokens.first == "open", result.ok, let url = tokens.dropFirst().first(where: { !$0.hasPrefix("-") }) {
            currentRealURL = url
        }
        actionRevision += 1
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
        } else if !["snapshot", "screenshot", "read"].contains(verb), result.output.count <= 90 {
            detail = result.output
        }
        transcript.append(AgentTranscriptEntry(kind: .tool(ok: result.ok), text: "agent-browser \(command)", detail: detail))
    }

    private func appendStatus(_ text: String) {
        transcript.append(AgentTranscriptEntry(kind: .status, text: text))
    }
}
