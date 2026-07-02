import Combine
import Foundation

struct SelectionChatExchange: Codable, Identifiable, Equatable {
    let id: UUID
    let question: String
    var answer: String
    let contextLabel: String
    let context: CodeSelectionContext
    let createdAt: Date

    init(
        id: UUID = UUID(),
        question: String,
        answer: String = "",
        contextLabel: String,
        context: CodeSelectionContext,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.question = question
        self.answer = answer
        self.contextLabel = contextLabel
        self.context = context
        self.createdAt = createdAt
    }
}

struct SelectionChatThread: Codable, Identifiable, Equatable {
    let id: UUID
    var title: String
    var contextLabel: String?
    var exchanges: [SelectionChatExchange]
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String = "New chat",
        contextLabel: String? = nil,
        exchanges: [SelectionChatExchange] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.contextLabel = contextLabel
        self.exchanges = exchanges
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@MainActor
final class SelectionChatController: ObservableObject {
    enum Phase: Equatable {
        case closed
        case composing
        case thinking
        case failed(String)
    }

    @Published private(set) var phase: Phase = .closed
    @Published var draft = ""
    @Published private(set) var submittedQuestion = ""
    @Published private(set) var answer = ""
    @Published private(set) var contextLabel: String?
    @Published private(set) var currentActivity = ""
    @Published private(set) var toolEvents: [AgentToolEvent] = []
    @Published private(set) var referenceRequest: CodeReferenceRequest?
    @Published private(set) var threads: [SelectionChatThread] = []
    @Published private(set) var selectedThreadID: SelectionChatThread.ID?
    @Published private(set) var exchanges: [SelectionChatExchange] = []
    @Published private(set) var activeExchangeID: SelectionChatExchange.ID?
    @Published private(set) var scrollRevision = 0

    private let client = StreamingCodeAgentClient()
    private var activeContext: CodeSelectionContext?
    private var activeRootURL: URL?
    private var activeTask: Task<Void, Never>?
    private var pendingAnswerDeltas: [SelectionChatExchange.ID: String] = [:]
    private var answerFlushTask: Task<Void, Never>?
    private var persistenceStore: AssistantPersistenceStore?
    private var isRestoringPersistedState = false

    private static let answerFlushDelayNanoseconds: UInt64 = 35_000_000

    var isOpen: Bool {
        phase != .closed
    }

    var hasContext: Bool {
        activeContext != nil && activeRootURL != nil
    }

    var isBusy: Bool {
        if case .thinking = phase { return true }
        return false
    }

    var canSubmit: Bool {
        hasContext && !isBusy && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canCaptureFix: Bool {
        hasContext && !isBusy && (!exchanges.isEmpty || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var canDeleteCurrentThread: Bool {
        selectedThreadID != nil && !isBusy
    }

    var selectedThreadTitle: String {
        selectedThread?.title ?? "New chat"
    }

    var statusText: String {
        switch phase {
        case .closed:
            return "Select code to ask"
        case .composing:
            if let contextLabel {
                return "\(selectedThreadTitle) - \(contextLabel)"
            }
            return selectedThreadTitle
        case .thinking:
            return currentActivity.isEmpty ? "Thinking" : currentActivity
        case .failed(let message):
            return message
        }
    }

    func configurePersistence(store: AssistantPersistenceStore) {
        guard persistenceStore?.id != store.id else { return }
        persistenceStore = store

        isRestoringPersistedState = true
        let state = store.load()
        threads = state.threads
        selectedThreadID = state.selectedThreadID.flatMap { id in
            threads.contains(where: { $0.id == id }) ? id : nil
        } ?? threads.first?.id
        syncSelectedThread()
        phase = hasContext ? .composing : .closed
        isRestoringPersistedState = false
    }

    func open(context: CodeSelectionContext?, rootURL: URL) {
        cancelActiveTask()
        setContext(context: context, rootURL: rootURL)
        newChat()
    }

    func setContext(context: CodeSelectionContext?, rootURL: URL) {
        guard let context else {
            return
        }
        activeContext = context
        activeRootURL = rootURL
        contextLabel = context.locationLabel
        referenceRequest = nil
        if phase == .closed {
            phase = .composing
        }
    }

    func close() {
        cancelActiveTask()
        cancelPendingAnswerDeltas()
        activeContext = nil
        activeRootURL = nil
        contextLabel = nil
        currentActivity = ""
        referenceRequest = nil
        submittedQuestion = ""
        answer = ""
        toolEvents = []
        activeExchangeID = nil
        draft = ""
        phase = .closed
        scrollRevision += 1
    }

    func clearTranscript() {
        guard let index = selectedThreadIndex else {
            newChat()
            return
        }
        cancelActiveTask()
        cancelPendingAnswerDeltas()
        threads[index].exchanges = []
        threads[index].updatedAt = Date()
        exchanges = []
        submittedQuestion = ""
        answer = ""
        toolEvents = []
        activeExchangeID = nil
        draft = ""
        currentActivity = ""
        phase = hasContext ? .composing : .closed
        persistThreads()
        scrollRevision += 1
    }

    func cancelResponse() {
        flushPendingAnswerDeltas()
        cancelActiveTask()
        persistThreads()
        currentActivity = ""
        activeExchangeID = nil
        phase = .composing
    }

    func newChat() {
        cancelActiveTask()
        cancelPendingAnswerDeltas()

        let thread = SelectionChatThread(contextLabel: contextLabel)
        threads.insert(thread, at: 0)
        selectedThreadID = thread.id
        syncSelectedThread()
        draft = ""
        submittedQuestion = ""
        answer = ""
        toolEvents = []
        activeExchangeID = nil
        currentActivity = ""
        phase = hasContext ? .composing : .closed
        persistThreads()
        scrollRevision += 1
    }

    func selectThread(_ id: SelectionChatThread.ID) {
        guard !isBusy, threads.contains(where: { $0.id == id }) else { return }
        selectedThreadID = id
        syncSelectedThread()
        persistThreads()
        scrollRevision += 1
    }

    func deleteCurrentThread() {
        guard !isBusy, let selectedThreadID else { return }
        cancelActiveTask()
        cancelPendingAnswerDeltas()
        threads.removeAll { $0.id == selectedThreadID }
        self.selectedThreadID = threads.first?.id
        syncSelectedThread()
        persistThreads()
        scrollRevision += 1
    }

    func openCodeReference(_ reference: CodeReference) {
        referenceRequest = CodeReferenceRequest(reference: reference)
    }

    func submit(onFixCapture: ((AgentFixProposal, PromptFixSnapshot) -> PromptFixItem?)? = nil) {
        guard canSubmit else { return }
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        startAgentTurn(question: question, forceFixCapture: false, onFixCapture: onFixCapture)
    }

    func requestFixCapture(onFixCapture: ((AgentFixProposal, PromptFixSnapshot) -> PromptFixItem?)? = nil) {
        guard canCaptureFix else { return }
        let requestedChange = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !requestedChange.isEmpty {
            draft = ""
        }
        let question = requestedChange.isEmpty
            ? "Create a fix proposal from this selection and chat."
            : requestedChange
        startAgentTurn(question: question, forceFixCapture: true, onFixCapture: onFixCapture)
    }

    func makeFixSnapshot(requestedChange: String? = nil) -> PromptFixSnapshot? {
        guard let activeContext, let activeRootURL else { return nil }

        let candidates = [
            requestedChange,
            draft,
            exchanges.last?.question,
        ]
        let request = candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
            ?? "Implement the intended fix for this selected code."

        return PromptFixSnapshot(
            rootURL: activeRootURL,
            context: activeContext,
            contextLabel: contextLabel ?? activeContext.locationLabel,
            requestedChange: request,
            exchanges: exchanges
        )
    }

    func clearDraft() {
        draft = ""
    }

    private func startAgentTurn(
        question: String,
        forceFixCapture: Bool,
        onFixCapture: ((AgentFixProposal, PromptFixSnapshot) -> PromptFixItem?)?
    ) {
        guard hasContext else {
            phase = .failed("Selection context is no longer available.")
            return
        }
        guard let context = activeContext, let rootURL = activeRootURL else {
            phase = .failed("Selection context is no longer available.")
            return
        }

        let threadID = ensureSelectedThread(for: question)
        submittedQuestion = question
        answer = ""
        toolEvents = []
        currentActivity = "Inspecting the diff"
        phase = .thinking
        let exchangeID = appendLocalExchange(question: question, answer: "", context: context, threadID: threadID)
        activeExchangeID = exchangeID

        cancelActiveTask()
        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let reply = try await client.ask(
                    question: question,
                    context: context,
                    rootURL: rootURL,
                    forceFixCapture: forceFixCapture,
                    onProgress: { [weak self] message in
                        self?.currentActivity = message
                    },
                    onToolEvent: { [weak self] event in
                        self?.applyToolEvent(event)
                    },
                    onDelta: { [weak self] delta in
                        self?.bufferAnswerDelta(delta, to: exchangeID)
                    },
                    onFixProposal: { [weak self] proposal in
                        guard let self,
                              let snapshot = self.makeFixSnapshot(requestedChange: proposal.summary) else {
                            return
                        }
                        _ = onFixCapture?(proposal, snapshot)
                    }
                )
                if !Task.isCancelled {
                    flushPendingAnswerDeltas()
                    replaceAnswer(reply, for: exchangeID)
                    currentActivity = ""
                    activeExchangeID = nil
                    phase = .composing
                }
            } catch {
                if !Task.isCancelled {
                    flushPendingAnswerDeltas()
                    activeExchangeID = nil
                    phase = .failed(error.localizedDescription)
                    persistThreads()
                }
            }
        }
    }

    private func applyToolEvent(_ event: AgentToolEvent) {
        switch event.status {
        case .started:
            toolEvents.append(event)
        case .finished:
            guard let index = toolEvents.firstIndex(where: { $0.id == event.id }) else {
                toolEvents.append(event)
                scrollRevision += 1
                return
            }
            toolEvents[index] = event
        }
        scrollRevision += 1
    }

    @discardableResult
    private func appendLocalExchange(
        question: String,
        answer: String,
        context: CodeSelectionContext,
        threadID: SelectionChatThread.ID
    ) -> SelectionChatExchange.ID {
        let exchange = SelectionChatExchange(
            question: question,
            answer: answer,
            contextLabel: context.locationLabel,
            context: context
        )
        updateThread(id: threadID) { thread in
            if thread.exchanges.isEmpty {
                thread.title = Self.title(for: question)
            }
            thread.contextLabel = context.locationLabel
            thread.exchanges.append(exchange)
        }
        syncSelectedThread()
        submittedQuestion = question
        self.answer = answer
        scrollRevision += 1
        return exchange.id
    }

    private func bufferAnswerDelta(_ delta: String, to id: SelectionChatExchange.ID) {
        guard !delta.isEmpty else { return }
        pendingAnswerDeltas[id, default: ""] += delta
        scheduleAnswerFlush()
    }

    private func scheduleAnswerFlush() {
        guard answerFlushTask == nil else { return }
        answerFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.answerFlushDelayNanoseconds)
            guard !Task.isCancelled else { return }
            self?.answerFlushTask = nil
            self?.flushPendingAnswerDeltas()
        }
    }

    private func flushPendingAnswerDeltas() {
        guard !pendingAnswerDeltas.isEmpty else {
            answerFlushTask?.cancel()
            answerFlushTask = nil
            return
        }

        answerFlushTask?.cancel()
        answerFlushTask = nil

        let deltas = pendingAnswerDeltas
        pendingAnswerDeltas.removeAll()
        for (id, delta) in deltas {
            appendAnswerDelta(delta, to: id)
        }
    }

    private func cancelPendingAnswerDeltas() {
        answerFlushTask?.cancel()
        answerFlushTask = nil
        pendingAnswerDeltas.removeAll()
    }

    private func appendAnswerDelta(_ delta: String, to id: SelectionChatExchange.ID) {
        answer += delta
        updateExchange(id: id) { exchange in
            exchange.answer += delta
        }
        syncSelectedThread()
        scrollRevision += 1
    }

    private func replaceAnswer(_ answer: String, for id: SelectionChatExchange.ID) {
        self.answer = answer
        updateExchange(id: id) { exchange in
            exchange.answer = answer
        }
        syncSelectedThread()
        persistThreads()
        scrollRevision += 1
    }

    private var selectedThread: SelectionChatThread? {
        guard let selectedThreadID else { return nil }
        return threads.first { $0.id == selectedThreadID }
    }

    private var selectedThreadIndex: Int? {
        guard let selectedThreadID else { return nil }
        return threads.firstIndex { $0.id == selectedThreadID }
    }

    private func ensureSelectedThread(for question: String) -> SelectionChatThread.ID {
        if let selectedThreadID, threads.contains(where: { $0.id == selectedThreadID }) {
            return selectedThreadID
        }

        let thread = SelectionChatThread(
            title: Self.title(for: question),
            contextLabel: contextLabel
        )
        threads.insert(thread, at: 0)
        selectedThreadID = thread.id
        syncSelectedThread()
        persistThreads()
        return thread.id
    }

    private func syncSelectedThread() {
        exchanges = selectedThread?.exchanges ?? []
        submittedQuestion = exchanges.last?.question ?? ""
        answer = exchanges.last?.answer ?? ""
    }

    private func updateThread(
        id: SelectionChatThread.ID,
        _ update: (inout SelectionChatThread) -> Void
    ) {
        guard let index = threads.firstIndex(where: { $0.id == id }) else { return }
        update(&threads[index])
        threads[index].updatedAt = Date()
    }

    private func updateExchange(
        id: SelectionChatExchange.ID,
        _ update: (inout SelectionChatExchange) -> Void
    ) {
        guard let threadIndex = threads.firstIndex(where: { thread in
            thread.exchanges.contains(where: { $0.id == id })
        }), let exchangeIndex = threads[threadIndex].exchanges.firstIndex(where: { $0.id == id }) else {
            return
        }
        update(&threads[threadIndex].exchanges[exchangeIndex])
        threads[threadIndex].updatedAt = Date()
    }

    private func persistThreads() {
        guard !isRestoringPersistedState else { return }
        persistenceStore?.saveThreads(threads, selectedThreadID: selectedThreadID)
    }

    private func cancelActiveTask() {
        activeTask?.cancel()
        activeTask = nil
    }

    private static func title(for question: String) -> String {
        let cleaned = question
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !cleaned.isEmpty else { return "New chat" }
        if cleaned.count <= 48 { return cleaned }
        return "\(cleaned.prefix(48))..."
    }
}
