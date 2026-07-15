import AppKit
import Foundation
import MyIDECore

/// A comment being written: the selected code is locked in, the text is still being typed.
struct CommentDraft: Equatable {
    let filePath: String
    let origin: ReviewComment.Origin
    let startLine: Int
    let endLine: Int
    /// Character precision of the original selection (1-based columns within the start/end
    /// lines); nil when the comment targets whole lines.
    var startColumn: Int?
    var endColumn: Int?
    let codeText: String

    var lineLabel: String {
        startLine == endLine ? "line \(startLine)" : "lines \(startLine)–\(endLine)"
    }
}

/// Owns the review: the comment list, the in-progress draft, selection for code↔comment
/// correspondence, and clipboard export. Persists per repo+branch.
@MainActor
final class ReviewCommentsController: ObservableObject {
    @Published private(set) var comments: [ReviewComment] = []
    @Published private(set) var draft: CommentDraft?
    @Published var draftText = ""
    @Published var selectedCommentID: UUID?
    /// Briefly true after Copy so the button can acknowledge ("Copied").
    @Published private(set) var justCopied = false

    private var store: ReviewCommentStore?
    private var copyFeedbackTask: Task<Void, Never>?
    private var externalChangeObserver: (any NSObjectProtocol)?

    init() {
        // `diffreview respond` runs in a separate process and edits the persisted review
        // directly; it announces the write through a distributed notification so an open
        // panel shows the reply without a relaunch.
        externalChangeObserver = DistributedNotificationCenter.default().addObserver(
            forName: .reviewCommentsChangedExternally,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reloadFromStore()
            }
        }
    }

    deinit {
        if let externalChangeObserver {
            DistributedNotificationCenter.default().removeObserver(externalChangeObserver)
        }
    }

    func configurePersistence(store: ReviewCommentStore) {
        guard self.store?.id != store.id else { return }
        self.store = store
        comments = store.load()
        draft = nil
        draftText = ""
        selectedCommentID = nil
    }

    /// Re-reads the persisted review after an external process changed it. Disk is the
    /// source of truth (every in-app mutation persists immediately), so replacing the
    /// in-memory list is safe; the selection survives when its comment still exists.
    func reloadFromStore() {
        guard let store else { return }
        let reloaded = store.load()
        guard reloaded != comments else { return }
        comments = reloaded
        if let selected = selectedCommentID, !reloaded.contains(where: { $0.id == selected }) {
            selectedCommentID = nil
        }
    }

    // MARK: - Draft lifecycle

    func beginDraft(_ newDraft: CommentDraft) {
        draft = newDraft
        draftText = ""
        selectedCommentID = nil
    }

    func cancelDraft() {
        draft = nil
        draftText = ""
    }

    /// Turns the draft into a comment. Returns it so the caller can highlight the code range.
    @discardableResult
    func commitDraft() -> ReviewComment? {
        let body = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let draft, !body.isEmpty else { return nil }
        let comment = ReviewComment(
            filePath: draft.filePath,
            origin: draft.origin,
            startLine: draft.startLine,
            endLine: draft.endLine,
            startColumn: draft.startColumn,
            endColumn: draft.endColumn,
            codeText: draft.codeText,
            body: body
        )
        comments.append(comment)
        sortComments()
        persist()
        self.draft = nil
        draftText = ""
        selectedCommentID = comment.id
        return comment
    }

    // MARK: - List management

    func delete(_ id: UUID) {
        comments.removeAll { $0.id == id }
        if selectedCommentID == id {
            selectedCommentID = nil
        }
        persist()
    }

    func clearAll() {
        comments = []
        selectedCommentID = nil
        persist()
    }

    // MARK: - Export

    var canCopy: Bool { !comments.isEmpty }

    /// Copies every comment as one prompt-ready block for a coding agent.
    func copyAllToPasteboard() {
        let text = ReviewCommentFormatter.format(comments: comments)
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        justCopied = true
        copyFeedbackTask?.cancel()
        copyFeedbackTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard !Task.isCancelled else { return }
            justCopied = false
        }
    }

    // MARK: - Private

    /// Document order (file, then line) — the panel mirrors the code, not the typing order.
    private func sortComments() {
        comments.sort {
            if $0.filePath != $1.filePath { return $0.filePath < $1.filePath }
            if $0.startLine != $1.startLine { return $0.startLine < $1.startLine }
            return $0.createdAt < $1.createdAt
        }
    }

    private func persist() {
        guard let store else { return }
        let snapshot = comments
        Task.detached(priority: .utility) {
            store.save(snapshot)
        }
    }
}
