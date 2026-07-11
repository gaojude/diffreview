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

    /// Saved logins (real-browser mode only). First-class "stay signed in".
    @Published private(set) var savedSessions: [BrowserSessionStore.SavedSession] = []
    @Published private(set) var isSavingSession = false

    /// The active model id (full, e.g. "anthropic/claude-opus-4-8"), persisted.
    @Published private(set) var currentModel: String?

    private let portal = MapleLifePortal()
    private let engine: AgentBrowserEngine
    private var recorder = AutomationRecorder()
    private let store: AutomationStore
    private let sessionStore: BrowserSessionStore
    private let chatStore: AssistantChatStore
    private let preferencesStore: AssistantPreferencesStore
    private let client = AgentHarnessClient()
    private var realBrowser: RealAgentBrowser?
    private var lastAssistantText: String?
    private var replayTask: Task<Void, Never>?
    private var isRestarting = false

    /// Live SDK session id (for persistence); and the id to resume on launch.
    private var sessionID: String?
    private var pendingResumeID: String?

    // Launch inputs remembered so New chat / model switch can rebuild the spec.
    private var harnessNodeURL: URL?
    private var harnessScriptURL: URL?
    private var harnessUseMock = false
    private var greeting = "Hi! Tell me what you'd like me to do."

    init(
        store: AutomationStore = AutomationStore(directory: AutomationStore.defaultDirectory()),
        sessionStore: BrowserSessionStore = BrowserSessionStore(directory: BrowserSessionStore.defaultDirectory()),
        chatStore: AssistantChatStore = AssistantChatStore(fileURL: AssistantChatStore.defaultFileURL()),
        preferencesStore: AssistantPreferencesStore = AssistantPreferencesStore(fileURL: AssistantPreferencesStore.defaultFileURL())
    ) {
        self.store = store
        self.sessionStore = sessionStore
        self.chatStore = chatStore
        self.preferencesStore = preferencesStore
        engine = AgentBrowserEngine(sites: [portal])
        engine.onEvent = { [weak self] event in
            self?.handleEngineEvent(event)
        }
        automations = store.list()
        sessionStore.prepareDirectory()
        savedSessions = sessionStore.list()
        recorder.start()

        // Restore prior chat (transcript + session id) and the chosen model.
        currentModel = preferencesStore.load().model
        if let snapshot = chatStore.load() {
            transcript = snapshot.lines.map(Self.entry(from:))
            pendingResumeID = snapshot.sessionID
            sessionID = snapshot.sessionID
        }
    }

    /// The label of the active model, for the picker's checkmark.
    var currentModelFamily: String? { AssistantModelCatalog.family(of: currentModel) }

    /// Whether the save/restore-login controls should show (real browser only).
    var supportsSavedLogins: Bool { browserIsReal }

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

        let useMock = environment["MYIDE_AGENT_MOCK"] == "1" || !Self.isLiveCapable(script)

        // Live sessions get a REAL Chrome browser whenever the agent-browser
        // CLI is installed; the simulated portal stays as the offline demo.
        // By default the app MANAGES a dedicated persistent Chrome (so it can
        // relaunch one the user closes). Overrides: MYIDE_CHROME_CDP attaches
        // to an externally started Chrome; MYIDE_CHROME_PROFILE reuses a named
        // Chrome profile with a CLI-launched browser.
        var realExecutor: RealAgentBrowser?
        var linkNote: String?
        if !useMock,
           environment["MYIDE_REAL_BROWSER"] != "0",
           let cli = AgentHarnessLocator.findAgentBrowserCLI(environment: environment) {
            func setting(_ key: String) -> String? {
                guard let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !value.isEmpty else { return nil }
                return value
            }
            let cdp = setting("MYIDE_CHROME_CDP")
            let profile = setting("MYIDE_CHROME_PROFILE")
            var manager: ChromeProcessManager?
            if cdp == nil, profile == nil, let chrome = ChromeProcessManager.discoverChrome() {
                let port = Int(setting("MYIDE_CHROME_PORT") ?? "") ?? 9333
                manager = ChromeProcessManager(config: .init(
                    chromeBinaryURL: chrome,
                    port: port,
                    userDataDir: ChromeProcessManager.defaultUserDataDir()
                ))
            }
            let executor = RealAgentBrowser(cliURL: cli, cdpTarget: cdp, chromeProfile: profile, chromeManager: manager)
            executor.onStatus = { [weak self] note in
                Task { @MainActor in self?.appendStatus(note) }
            }
            realExecutor = executor
            if let cdp {
                linkNote = "I'm linked to your own Chrome (CDP \(cdp)) — I'll work right in your browser."
            } else if let profile {
                linkNote = "I'm using your Chrome profile “\(profile)” — your logins come along."
            } else if manager != nil {
                linkNote = "I manage a Chrome window for you — if you close it, I'll just open a new one."
            }
        }

        // Model: a persisted choice wins, else the launch env, else SDK default.
        if currentModel == nil {
            currentModel = environment["MYIDE_ASSISTANT_MODEL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Remember the launch inputs so New chat and model switches can rebuild.
        harnessNodeURL = node
        harnessScriptURL = script
        harnessUseMock = useMock
        realBrowser = realExecutor
        browserIsReal = realExecutor != nil

        if useMock {
            greeting = "Hi! I'm in demo mode. Ask me anything — try “Submit my massage claim”."
        } else if realExecutor != nil {
            greeting = "Hi! Tell me what to do on the web — I'll open a Chrome window you can watch. If a site needs your password, I'll hand the keyboard to you."
        } else {
            greeting = "Hi! Tell me what you'd like me to do in the browser."
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

        // Resume the prior conversation if we have one — true memory across
        // restarts. A fresh transcript from disk is already showing.
        let resuming = !useMock && pendingResumeID != nil
        let spec = buildLaunchSpec(resume: resuming ? pendingResumeID : nil)

        switch client.launch(spec) {
        case .running:
            if realExecutor != nil {
                // Real recordings keep their waits — replays on live sites
                // fail without them.
                recorder = AutomationRecorder(readOnlyVerbs: AutomationRecorder.realBrowserReadOnlyVerbs)
                recorder.start()
            }
            mode = useMock ? .mock : .live
            phase = .ready
            if resuming {
                appendStatus("Welcome back — I picked up where we left off.")
            } else {
                appendStatus(greeting)
                if let linkNote { appendStatus(linkNote) }
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

    /// Builds the harness launch spec from the remembered inputs plus the
    /// current model and an optional session to resume.
    private func buildLaunchSpec(resume: String?) -> AgentHarnessClient.LaunchSpec {
        let node = harnessNodeURL ?? URL(fileURLWithPath: "/usr/bin/env")
        let script = harnessScriptURL ?? URL(fileURLWithPath: "agent-harness.mjs")
        var arguments: [String] = []
        if harnessUseMock {
            arguments = ["--mock", script.deletingLastPathComponent().appendingPathComponent("scenarios/insurance-claim.json").path]
        } else {
            if browserIsReal { arguments += ["--real"] }
            if let model = currentModel, !model.isEmpty { arguments += ["--model", model] }
            if let resume, !resume.isEmpty { arguments += ["--resume", resume] }
        }
        return AgentHarnessClient.LaunchSpec(nodeURL: node, scriptURL: script, arguments: arguments)
    }

    /// Clears the conversation and starts a fresh agent session so the context
    /// window doesn't bloat over a long session. The harness restarts with an
    /// empty context (no resume); the browser, its logins, saved automations,
    /// and the chosen model are all untouched.
    func clearConversation() {
        guard mode != .none, !isRestarting else { return }
        isRestarting = true
        replayTask?.cancel()
        replayTask = nil
        transcript.removeAll()
        lastAssistantText = nil
        canSaveAutomation = false
        sessionID = nil
        pendingResumeID = nil
        chatStore.clear()
        phase = .connecting
        appendStatus("Starting a fresh chat…")

        let client = self.client
        let spec = buildLaunchSpec(resume: nil)
        Task { @MainActor in
            // Stop the old harness off the main actor (stop() briefly blocks).
            await Task.detached { client.stop() }.value
            switch client.launch(spec) {
            case .running:
                self.transcript.removeAll()
                self.phase = .ready
                self.appendStatus(self.greeting)
            case .failed(let message):
                self.phase = .offline(message)
                self.appendStatus("I couldn't start a fresh chat: \(message)")
            }
            self.isRestarting = false
        }
    }

    /// Switches the model. Live via the SDK's setModel (no restart, context
    /// kept); the choice is persisted so it sticks across launches.
    func switchModel(family: String) {
        let id = AssistantModelCatalog.modelID(family: family, currentModel: currentModel)
        guard id != currentModel else { return }
        currentModel = id
        preferencesStore.save(.init(model: id))
        let label = AssistantModelCatalog.options.first { $0.family == family }?.label ?? family
        if mode == .live {
            client.send(.setModel(id))
            appendStatus("Switched to \(label).")
        } else {
            appendStatus("\(label) will be used next time a live session starts.")
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
        persistChat()

        // Ground every real-browser turn in what's on screen: "post it here"
        // almost always means the page that's already open, so the model gets
        // a [Current browser page: …] header without the user spelling it out.
        guard let real = realBrowser, real.hasActiveSession else {
            client.send(.user(text))
            return
        }
        let client = self.client
        Task.detached {
            var header = ""
            let url = real.execute("get url")
            if url.ok, !url.output.isEmpty, url.output != "about:blank" {
                let title = real.execute("get title")
                let pageTitle = (title.ok && !title.output.isEmpty) ? title.output : "untitled"
                header = "[Current browser page: \(pageTitle) — \(url.output)]\n"
            }
            client.send(.user(header + text))
        }
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

    // MARK: - Saved logins

    /// Snapshots the current browser's cookies + storage under `name` so the
    /// user stays signed in across sessions.
    func saveLogin(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let real = realBrowser, !trimmed.isEmpty, !isSavingSession else { return }
        let slug = BrowserSessionStore.slug(from: trimmed)
        let fileURL = sessionStore.stateFileURL(forSlug: slug)
        let store = sessionStore
        isSavingSession = true
        Task { @MainActor in
            let outcome = await Task.detached { () -> (AgentBrowserCommandResult, String?) in
                let saved = real.saveState(to: fileURL)
                return (saved, saved.ok ? real.currentURL() : nil)
            }.value
            self.isSavingSession = false
            if outcome.0.ok {
                store.recordMetadata(name: trimmed, slug: slug, savedAt: Date(), url: outcome.1)
                self.savedSessions = store.list()
                self.appendStatus("Saved your login as “\(trimmed)”. I'll restore it next time so you stay signed in.")
            } else {
                self.appendStatus("I couldn't save the login: \(outcome.0.output)")
            }
        }
    }

    /// Restores a saved login into the live browser (attaching/opening first).
    func restoreLogin(_ session: BrowserSessionStore.SavedSession) {
        guard let real = realBrowser, !isBusy else { return }
        let fileURL = session.fileURL
        let destination = session.url
        appendStatus("Restoring your “\(session.name)” login…")
        phase = .working
        Task { @MainActor in
            let result = await Task.detached { real.loadState(from: fileURL, navigateTo: destination) }.value
            self.currentRealURL = self.currentRealURL // no-op; keep pane fresh
            self.actionRevision += 1
            self.phase = (self.mode == .none) ? .offline("Assistant offline") : .ready
            self.appendStatus(result.ok
                ? "Restored “\(session.name)”. If a page is open, it should now show you as signed in."
                : "I couldn't restore that login: \(result.output)")
        }
    }

    func deleteSavedLogin(_ session: BrowserSessionStore.SavedSession) {
        sessionStore.delete(slug: session.slug)
        savedSessions = sessionStore.list()
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
            persistChat()
        case .fatal(let message):
            phase = .offline(message)
            appendStatus("My helper hit a problem: \(message)")
            // A poisoned resume id must not brick every future launch: drop it
            // (keeping the visible transcript) so the next start is clean.
            if pendingResumeID != nil {
                pendingResumeID = nil
                sessionID = nil
                persistChat()
            }
        case .session(let id):
            // Persist so the conversation can resume after a restart. Once the
            // (possibly resumed) session confirms, the pending id is spent.
            sessionID = id
            pendingResumeID = nil
            persistChat()
        }
    }

    private func handleTermination(_ code: Int32) {
        // A deliberate restart (New chat) stops the old process on purpose;
        // don't flip the UI to "offline" while the new one is coming up.
        guard !isRestarting else { return }
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

    // MARK: - Chat persistence

    /// Writes the current transcript + session id to disk so the conversation
    /// survives an app restart. Off the main actor; a snapshot is captured on
    /// the main actor first. Never persists the demo/mock transcript.
    private func persistChat() {
        guard mode == .live else { return }
        let snapshot = AssistantChatStore.Snapshot(
            sessionID: sessionID,
            lines: transcript.map(Self.line(from:))
        )
        let store = chatStore
        Task.detached(priority: .utility) { store.save(snapshot) }
    }

    private static func line(from entry: AgentTranscriptEntry) -> AssistantChatStore.Line {
        switch entry.kind {
        case .user: return .init(role: .user, text: entry.text, detail: entry.detail)
        case .assistant: return .init(role: .assistant, text: entry.text, detail: entry.detail)
        case .status: return .init(role: .status, text: entry.text, detail: entry.detail)
        case .tool(let ok): return .init(role: .tool, text: entry.text, detail: entry.detail, ok: ok)
        }
    }

    private static func entry(from line: AssistantChatStore.Line) -> AgentTranscriptEntry {
        let kind: AgentTranscriptEntry.Kind
        switch line.role {
        case .user: kind = .user
        case .assistant: kind = .assistant
        case .status: kind = .status
        case .tool: kind = .tool(ok: line.ok ?? true)
        }
        return AgentTranscriptEntry(kind: kind, text: line.text, detail: line.detail)
    }
}
