import Combine
import Foundation

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
    @Published private(set) var answer = ""
    @Published private(set) var contextLabel: String?
    @Published private(set) var currentActivity = ""
    @Published private(set) var toolEvents: [AgentToolEvent] = []

    private let client = StreamingCodeAgentClient()
    private var activeContext: CodeSelectionContext?
    private var activeRootURL: URL?
    private var activeTask: Task<Void, Never>?

    var isOpen: Bool {
        phase != .closed
    }

    var isBusy: Bool {
        if case .thinking = phase { return true }
        return false
    }

    var canSubmit: Bool {
        !isBusy && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var statusText: String {
        switch phase {
        case .closed:
            return ""
        case .composing:
            return "Ask about \(contextLabel ?? "selection")"
        case .thinking:
            return currentActivity.isEmpty ? "Thinking" : currentActivity
        case .failed(let message):
            return message
        }
    }

    func open(context: CodeSelectionContext?, rootURL: URL) {
        guard let context else {
            phase = .failed("Select code before asking.")
            return
        }
        cancelActiveTask()
        activeContext = context
        activeRootURL = rootURL
        contextLabel = context.locationLabel
        currentActivity = ""
        answer = ""
        toolEvents = []
        draft = ""
        phase = .composing
    }

    func close() {
        cancelActiveTask()
        activeContext = nil
        activeRootURL = nil
        contextLabel = nil
        currentActivity = ""
        answer = ""
        toolEvents = []
        draft = ""
        phase = .closed
    }

    func submit() {
        guard canSubmit else { return }
        guard let context = activeContext, let rootURL = activeRootURL else {
            phase = .failed("Selection context is no longer available.")
            return
        }

        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        answer = ""
        toolEvents = []
        currentActivity = "Inspecting the diff"
        phase = .thinking

        cancelActiveTask()
        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let reply = try await client.ask(
                    question: question,
                    context: context,
                    rootURL: rootURL,
                    onProgress: { [weak self] message in
                        self?.currentActivity = message
                    },
                    onToolEvent: { [weak self] event in
                        self?.applyToolEvent(event)
                    },
                    onDelta: { [weak self] delta in
                        self?.answer += delta
                    }
                )
                if !Task.isCancelled {
                    answer = reply
                    currentActivity = ""
                    phase = .composing
                }
            } catch {
                if !Task.isCancelled {
                    phase = .failed(error.localizedDescription)
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
                return
            }
            toolEvents[index] = event
        }
    }

    private func cancelActiveTask() {
        activeTask?.cancel()
        activeTask = nil
    }
}
