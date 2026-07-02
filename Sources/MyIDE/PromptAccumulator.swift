import AppKit
import Combine
import Foundation

struct PromptFixSnapshot {
    let rootURL: URL
    let context: CodeSelectionContext
    let contextLabel: String
    let requestedChange: String
    let exchanges: [SelectionChatExchange]
}

struct PromptFixItem: Codable, Identifiable, Equatable {
    let id: UUID
    let createdAt: Date
    let title: String
    let location: String
    let requestedChange: String
    let conversationSummary: String
    let prompt: String

    init(
        proposal: AgentFixProposal,
        snapshot: PromptFixSnapshot,
        id: UUID = UUID(),
        createdAt: Date = Date()
    ) {
        let path = Self.relativePath(for: snapshot.context.fileURL, rootURL: snapshot.rootURL)
        let location = Self.location(path: path, context: snapshot.context)
        let summary = Self.trimmedOrFallback(
            proposal.summary,
            fallback: snapshot.requestedChange
        )
        let prompt = Self.trimmedOrFallback(
            proposal.prompt,
            fallback: Self.prompt(
                path: path,
                location: location,
                snapshot: snapshot,
                requestedChange: summary,
                conversationSummary: Self.conversationSummary(for: snapshot.exchanges)
            )
        )

        self.id = id
        self.createdAt = createdAt
        self.title = Self.title(
            requestedChange: Self.trimmedOrFallback(proposal.title, fallback: summary),
            fallbackLocation: location
        )
        self.location = location
        self.requestedChange = summary
        self.conversationSummary = Self.conversationSummary(for: snapshot.exchanges)
        self.prompt = prompt
    }

    init(snapshot: PromptFixSnapshot, id: UUID = UUID(), createdAt: Date = Date()) {
        let path = Self.relativePath(for: snapshot.context.fileURL, rootURL: snapshot.rootURL)
        let location = Self.location(path: path, context: snapshot.context)
        let requestedChange = Self.trimmedOrFallback(
            snapshot.requestedChange,
            fallback: "Implement the intended fix for this selected code."
        )
        let conversationSummary = Self.conversationSummary(for: snapshot.exchanges)

        self.id = id
        self.createdAt = createdAt
        self.title = Self.title(requestedChange: requestedChange, fallbackLocation: location)
        self.location = location
        self.requestedChange = requestedChange
        self.conversationSummary = conversationSummary
        self.prompt = Self.prompt(
            path: path,
            location: location,
            snapshot: snapshot,
            requestedChange: requestedChange,
            conversationSummary: conversationSummary
        )
    }

    private static func prompt(
        path: String,
        location: String,
        snapshot: PromptFixSnapshot,
        requestedChange: String,
        conversationSummary: String
    ) -> String {
        let kind = snapshot.context.contentKind == .diff ? "Git diff" : "Source"
        let language = snapshot.context.contentKind == .diff
            ? "diff"
            : languageHint(for: path)
        let selectedCode = clip(snapshot.context.text, maxCharacters: 6_000)

        return """
        Implement this fix in the opened repository.

        Target
        - File: \(path)
        - Location: \(location)
        - Anchor kind: \(kind)
        - Selected label: \(snapshot.contextLabel)

        Requested change
        \(requestedChange)

        Conversation context
        \(conversationSummary)

        Selected code
        ````\(language)
        \(selectedCode)
        ````

        Please inspect nearby code and tests before editing. Make the smallest coherent change, update or add tests if needed, and report what changed.
        """
    }

    private static func conversationSummary(for exchanges: [SelectionChatExchange]) -> String {
        let recent = exchanges.suffix(6)
        guard !recent.isEmpty else {
            return "No prior chat. Use the target location and selected code as the anchor."
        }

        return recent.enumerated()
            .map { index, exchange in
                var lines = [
                    "\(index + 1). User: \(singleLine(exchange.question, maxCharacters: 320))",
                ]
                let answer = exchange.answer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !answer.isEmpty {
                    lines.append("   Assistant: \(singleLine(answer, maxCharacters: 760))")
                }
                return lines.joined(separator: "\n")
            }
            .joined(separator: "\n")
    }

    private static func title(requestedChange: String, fallbackLocation: String) -> String {
        let cleaned = singleLine(requestedChange, maxCharacters: 72)
        let genericFixRequests: Set<String> = [
            "fix it",
            "lets fix it",
            "let's fix it",
            "please fix it",
            "make the change",
            "make this change",
            "do it",
        ]
        if genericFixRequests.contains(cleaned.lowercased()) {
            return "Fix \(fallbackLocation)"
        }
        return cleaned.isEmpty ? "Fix \(fallbackLocation)" : cleaned
    }

    private static func location(path: String, context: CodeSelectionContext) -> String {
        "\(path):\(context.startLine)-\(context.endLine)"
    }

    private static func relativePath(for url: URL?, rootURL: URL) -> String {
        guard let url else { return "unknown" }
        let root = rootURL.standardizedFileURL.resolvingSymlinksInPath().path
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard path.hasPrefix(root + "/") else { return url.lastPathComponent }
        return String(path.dropFirst(root.count + 1))
    }

    private static func languageHint(for path: String) -> String {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "swift": return "swift"
        case "ts": return "typescript"
        case "tsx": return "tsx"
        case "js": return "javascript"
        case "jsx": return "jsx"
        case "py": return "python"
        case "rb": return "ruby"
        case "rs": return "rust"
        case "go": return "go"
        case "java": return "java"
        case "kt": return "kotlin"
        case "c", "h": return "c"
        case "cc", "cpp", "hpp": return "cpp"
        case "cs": return "csharp"
        case "html": return "html"
        case "css": return "css"
        case "json": return "json"
        case "md": return "markdown"
        case "sh": return "bash"
        case "yml", "yaml": return "yaml"
        default: return ""
        }
    }

    private static func trimmedOrFallback(_ text: String, fallback: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private static func singleLine(_ text: String, maxCharacters: Int) -> String {
        clip(
            text
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " "),
            maxCharacters: maxCharacters
        )
    }

    private static func clip(_ text: String, maxCharacters: Int) -> String {
        guard text.count > maxCharacters else { return text }
        return String(text.prefix(maxCharacters)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }
}

@MainActor
final class PromptAccumulatorController: ObservableObject {
    @Published private(set) var items: [PromptFixItem] = []
    @Published var selectedItemIDs: Set<PromptFixItem.ID> = []

    private var persistenceStore: AssistantPersistenceStore?
    private var isRestoringPersistedState = false

    var selectedItems: [PromptFixItem] {
        items.filter { selectedItemIDs.contains($0.id) }
    }

    var selectedPromptText: String? {
        let selected = selectedItems
        guard !selected.isEmpty else { return nil }
        return selected.map(\.prompt).joined(separator: "\n\n---\n\n")
    }

    func configurePersistence(store: AssistantPersistenceStore) {
        guard persistenceStore?.id != store.id else { return }
        persistenceStore = store

        isRestoringPersistedState = true
        items = store.load().fixes
        selectedItemIDs = []
        isRestoringPersistedState = false
    }

    @discardableResult
    func capture(proposal: AgentFixProposal, snapshot: PromptFixSnapshot) -> PromptFixItem {
        let item = PromptFixItem(proposal: proposal, snapshot: snapshot)
        items.insert(item, at: 0)
        selectedItemIDs = [item.id]
        persist()
        return item
    }

    @discardableResult
    func capture(_ snapshot: PromptFixSnapshot) -> PromptFixItem {
        let item = PromptFixItem(snapshot: snapshot)
        items.insert(item, at: 0)
        selectedItemIDs = [item.id]
        persist()
        return item
    }

    func removeSelected() {
        guard !selectedItemIDs.isEmpty else { return }
        items.removeAll { selectedItemIDs.contains($0.id) }
        selectedItemIDs.removeAll()
        persist()
    }

    @discardableResult
    func copySelectedToPasteboard() -> Int {
        guard let selectedPromptText else { return 0 }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selectedPromptText, forType: .string)
        return selectedItems.count
    }

    private func persist() {
        guard !isRestoringPersistedState else { return }
        persistenceStore?.saveFixes(items)
    }
}
