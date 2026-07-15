import AppKit
import Foundation
import MarginCore

/// The reply being reviewed: its text, where it came from, and precomputed line geometry.
struct MarginDocument: Equatable {
    let sourceURL: URL?
    let title: String
    let text: String
    let lineStarts: [Int]

    init(sourceURL: URL?, title: String, text: String) {
        self.sourceURL = sourceURL
        self.title = title
        self.text = text
        self.lineStarts = ProseGeometry.lineStarts(of: text)
    }
}

/// A comment being written: the selection is locked in, the words are still being typed.
struct ProseDraft: Equatable {
    let selection: ProseSelection
}

/// Owns the review of one document: the comment list, the in-progress draft, selection for
/// text↔comment correspondence, and clipboard export. Persists per content hash, so the
/// same reply reopened later gets its comments back. Mirrors DiffReview's
/// `ReviewCommentsController`.
@MainActor
final class MarginReviewController: ObservableObject {
    @Published private(set) var comments: [ProseComment] = []
    @Published private(set) var draft: ProseDraft?
    @Published var draftText = ""
    @Published var selectedCommentID: UUID?
    /// Briefly true after Copy so the button can acknowledge ("Copied").
    @Published private(set) var justCopied = false

    private var store: ProseReviewStore?
    private var documentTitle: String?
    private var copyFeedbackTask: Task<Void, Never>?

    func configurePersistence(store: ProseReviewStore, documentTitle: String?) {
        guard self.store?.contentKey != store.contentKey else { return }
        self.store = store
        self.documentTitle = documentTitle
        comments = store.load()
        draft = nil
        draftText = ""
        selectedCommentID = nil
    }

    // MARK: - Draft lifecycle

    func beginDraft(_ selection: ProseSelection) {
        draft = ProseDraft(selection: selection)
        draftText = ""
        selectedCommentID = nil
    }

    func cancelDraft() {
        draft = nil
        draftText = ""
    }

    /// Turns the draft into a comment. Returns it so the caller can highlight the range.
    @discardableResult
    func commitDraft() -> ProseComment? {
        let body = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let draft, !body.isEmpty else { return nil }
        let comment = ProseComment(selection: draft.selection, body: body)
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

    /// The comment whose range contains the given text offset, if any (for click-to-focus).
    func comment(atOffset offset: Int) -> ProseComment? {
        comments.first { offset >= $0.startOffset && offset < $0.endOffset }
    }

    // MARK: - Export

    var canCopy: Bool { !comments.isEmpty }

    /// Copies every comment as one prompt-ready block for a coding agent.
    func copyAllToPasteboard() {
        let text = ProseReviewFormatter.format(comments: comments, title: documentTitle)
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

    /// Document order — the panel mirrors the text, not the typing order.
    private func sortComments() {
        comments.sort {
            if $0.startOffset != $1.startOffset { return $0.startOffset < $1.startOffset }
            return $0.createdAt < $1.createdAt
        }
    }

    private func persist() {
        guard let store else { return }
        let snapshot = comments
        let title = documentTitle
        Task.detached(priority: .utility) {
            store.save(snapshot, title: title)
        }
    }
}

/// One window's state: the open document, its review, and the live text selection the
/// ⌘K menu command turns into a draft.
@MainActor
final class MarginSession: ObservableObject {
    @Published private(set) var document: MarginDocument?
    @Published var fontSize: CGFloat = 13
    /// The current selection in the text view, continuously reported by `ProseTextView`.
    @Published var currentSelection: ProseSelection?
    /// Monotonic token: bumping it asks the text view to scroll a comment into view.
    @Published private(set) var focusRequest: (comment: ProseComment, token: Int)?

    let review = MarginReviewController()

    static let minimumFontSize: CGFloat = 10
    static let maximumFontSize: CGFloat = 22

    func open(fileURL: URL) {
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8),
              !text.isEmpty else {
            NSSound.beep()
            return
        }
        let document = MarginDocument(
            sourceURL: fileURL,
            title: fileURL.deletingPathExtension().lastPathComponent,
            text: text
        )
        self.document = document
        currentSelection = nil
        focusRequest = nil
        review.configurePersistence(
            store: ProseReviewStore(contentText: text, sourcePath: fileURL.path),
            documentTitle: document.title
        )
    }

    var canComment: Bool { currentSelection != nil && document != nil }

    func beginDraftFromSelection() {
        guard let selection = currentSelection else {
            NSSound.beep()
            return
        }
        review.beginDraft(selection)
    }

    func focus(_ comment: ProseComment) {
        review.selectedCommentID = comment.id
        focusRequest = (comment, (focusRequest?.token ?? 0) + 1)
    }

    func increaseFontSize() { fontSize = min(fontSize + 1, Self.maximumFontSize) }
    func decreaseFontSize() { fontSize = max(fontSize - 1, Self.minimumFontSize) }
    func resetFontSize() { fontSize = 13 }
}
