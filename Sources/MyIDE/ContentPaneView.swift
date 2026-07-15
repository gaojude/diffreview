import SwiftUI
import AppKit
import MyIDECore

/// The main pane: the branch change set as an editor-style diff under one floating glass
/// header, plus the review-comments column on the left while a review exists.
///
/// - **Changes** — unified (default) or split (old|new, scroll-locked, draggable divider)
///   layout, with a line-number gutter and +/- change markers. Only the new-code side takes
///   ⌘-click definitions and comments. File headers are real controls that collapse like
///   GitHub's "viewed" files; collapse state + reading position persist per repo+branch. ⌘F
///   finds in the new-code column.
/// - **Explorer** — a floating panel over the window (never replacing the diff) holding a
///   stack of source files: ⌘-click a usage to jump to its definition. ⌘-clicking a
///   declaration shows everywhere it's used as a dropdown next to the symbol.
/// - **Comments** — select lines, click the ＋bubble, and a glass composer appears inline
///   under the selection. The left column lists the review, jumps back to code on click,
///   and copies everything as one prompt-ready block.
/// A one-shot "jump to the next/previous change block" command. Fresh identity per press
/// so pressing the same chevron twice still fires (same trick as CodeScrollRequest).
struct ChangeJumpRequest: Equatable {
    let id = UUID()
    let forward: Bool

    init(forward: Bool) {
        self.forward = forward
    }
}

struct ContentPaneView: View {
    let rootURL: URL
    let changeTreeState: AppState.ChangeTreeState
    var fontSize: CGFloat = FontSizes.default
    /// Split (old|new) vs unified single-column diff; persisted app-wide.
    var diffLayout: DiffLayoutMode = .unified
    var onDiffLayoutChange: (DiffLayoutMode) -> Void = { _ in }
    /// Owned by RootView (the toolbar toggle lives there); auto-shown here on the first
    /// comment and auto-hidden when the last one is deleted.
    @Binding var showCommentsPanel: Bool
    /// One-shot command from RootView's toolbar chevrons: jump to the next/previous
    /// change block. Fresh identity per press so repeats re-trigger.
    var changeJumpRequest: ChangeJumpRequest?

    @State private var state: LoadState = .empty
    @State private var selectionContext: CodeSelectionContext?
    @State private var scrollRequest: CodeScrollRequest?
    /// Per-file diff bodies, kept so collapse toggles rebuild without rerunning `git diff`.
    @State private var loadedEntries: [ChangeSetDocument.Entry] = []
    /// Moved blocks detected across the change set. Keyed on file lines (not document rows),
    /// so the same list survives every collapse/layout rebuild; rows re-resolve per document.
    @State private var movedBlocks: [MovedBlock] = []
    @State private var loadedDocumentID: String?
    @State private var collapsedPaths: Set<String> = []
    @State private var viewStateStore: ChangeSetViewStateStore?
    @State private var topDocumentLine = 1
    @State private var viewStateSaveTask: Task<Void, Never>?
    @State private var transientStatus: String?
    @State private var transientStatusTask: Task<Void, Never>?
    @State private var isResolvingDefinition = false
    /// Yellow emphasis on the new-code pane for the comment being written or last clicked.
    @State private var focusedDocumentRange: ClosedRange<Int>?
    /// Rows the inline composer is pinned under while drafting a diff comment.
    @State private var draftAnchorRows: ClosedRange<Int>?
    @State private var changesComposerAnchor: CGRect?
    @State private var composerMeasuredHeight: CGFloat = 110
    /// References dropdown for a symbol ⌘-clicked in the changes pane.
    @State private var changesReferencesDropdown: SymbolReferencesPresentation?
    @State private var dropdownMeasuredHeight: CGFloat = 260
    @State private var diffScrollSync = ScrollSyncGroup()
    /// Fraction of the diff width given to the old (left) pane; draggable, double-click resets.
    @State private var splitFraction: CGFloat = 0.5
    @State private var diffFind = FindState()
    /// Latest raw selection in the primary pane (document rows for diffs), so ⌘K can start a
    /// comment exactly like the ＋bubble does.
    @State private var lastPrimarySelection: CodeSelectionContext?
    /// Where the last ⌥⌘↑/↓ jump landed, so repeated presses step hunk by hunk exactly.
    @State private var changeJumpAnchor: ChangeJumpAnchor?
    @State private var explorerPanel = ExplorerPanelController()
    @StateObject private var explorer = ExplorerController()
    @StateObject private var definitions = DefinitionController()
    @StateObject private var comments = ReviewCommentsController()

    enum LoadState {
        case empty
        case loading
        case document(SideBySideDocument) // the side-by-side change set
        case message(String)              // placeholder: not a repo / no changes / error
    }

    var body: some View {
        GeometryReader { outer in
            HSplitView {
                if showCommentsPanel {
                    CommentsPaneView(
                        controller: comments,
                        fontSize: fontSize,
                        onJump: { jump(to: $0) }
                    )
                        // A quarter of the window by default; the diff keeps the rest.
                        .frame(
                            minWidth: 280,
                            idealWidth: max(outer.size.width * 0.25, 280),
                            maxWidth: max(outer.size.width * 0.4, 320)
                        )
                }
                primaryPane
                    .frame(minWidth: 520)
                    .layoutPriority(1)
            }
        }
        .onChange(of: comments.comments.count) { oldCount, newCount in
            // The panel exists exactly when there is a review: appears with the first
            // comment, leaves with the last. Manual toggling in between is respected.
            if oldCount == 0, newCount > 0 {
                withAnimation(.easeInOut(duration: 0.2)) { showCommentsPanel = true }
            } else if newCount == 0 {
                withAnimation(.easeInOut(duration: 0.2)) { showCommentsPanel = false }
            }
        }
        .onChange(of: comments.selectedCommentID) { _, id in
            // Deselecting clears the yellow emphasis — unless a draft is opening: beginDraft
            // nils the selection first and beginComment then focuses the drafted rows, and
            // this handler runs AFTER both, so without the guard it would erase the very
            // emphasis the draft just placed.
            if id == nil, comments.draft == nil {
                focusedDocumentRange = nil
            }
        }
        .onChange(of: comments.draft) { _, draft in
            if draft == nil {
                draftAnchorRows = nil
                if comments.selectedCommentID == nil {
                    focusedDocumentRange = nil
                }
            }
        }
        .onChange(of: explorer.stack) { _, _ in
            explorerPanel.updateTitle(explorer.panelTitle)
        }
        .task(id: commentsPersistenceID) {
            configureCommentsPersistence()
        }
    }

    private var commentsPersistenceID: String {
        "\(rootURL.standardizedFileURL.resolvingSymlinksInPath().path)#\(commentsBranchName)"
    }

    private var commentsBranchName: String {
        switch changeTreeState {
        case .loaded(let context):
            return context.branchName
        case .notRepository:
            return "no-git"
        case .loading:
            return "loading"
        }
    }

    private func configureCommentsPersistence() {
        guard commentsBranchName != "loading" else { return }
        comments.configurePersistence(store: ReviewCommentStore(
            rootURL: rootURL,
            branchName: commentsBranchName
        ))
    }

    // MARK: - Primary pane

    private var primaryPane: some View {
        ZStack(alignment: .top) {
            changesLayer
            // Both sit below the sticky section-header strip.
            statusToast
                .padding(.top, 48)
                .animation(.easeInOut(duration: 0.18), value: transientStatus)
            if diffFind.isActive {
                CodeFindBar(state: $diffFind, fontSize: fontSize)
                    .frame(maxWidth: 320)
                    .padding(.top, 48)
                    .padding(.trailing, 12)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .background(
            // Window-scoped shortcuts (the Explorer panel has its own).
            Group {
                Button("") {
                    withAnimation(.easeInOut(duration: 0.12)) { diffFind.isActive = true }
                }
                .keyboardShortcut("f", modifiers: .command)

                // ⌘K: comment on the current selection, same as clicking the ＋bubble.
                Button("") {
                    beginCommentFromKeyboard()
                }
                .keyboardShortcut("k", modifiers: .command)
            }
            .opacity(0)
            .accessibilityHidden(true)
        )
        .onChange(of: changeJumpRequest) { _, request in
            if let request {
                jumpToChange(forward: request.forward)
            }
        }
        .task(id: loadID) { await load() } // auto-cancels when the target changes
    }

    @ViewBuilder
    private var changesLayer: some View {
        switch state {
        case .empty:
            glassPlaceholder("Open a repository with branch changes", systemImage: "plus.forwardslash.minus")
                .accessibilityIdentifier("empty-state")
        case .loading:
            ProgressView().controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .document(let document):
            Group {
                if document.layout == .split {
                    sideBySideDiff(document)
                } else {
                    primaryDiffPane(document)
                }
            }
            .accessibilityIdentifier("content-view")
            .onChange(of: diffLayout) { _, _ in
                rebuildForLayoutChange()
            }
        case .message(let m):
            glassPlaceholder(m, systemImage: "doc")
                .accessibilityIdentifier("content-message")
        }
    }

    private var activeFindQuery: String? {
        diffFind.isActive && !diffFind.query.isEmpty ? diffFind.query : nil
    }

    /// Old version left, new version right. Identical row counts keep the shared scroll group
    /// perfectly aligned; the divider between the two code panes drags to rebalance and
    /// double-clicks back to center.
    private func sideBySideDiff(_ document: SideBySideDocument) -> some View {
        GeometryReader { outer in
            let leftWidth = max(200, min(outer.size.width - 240, outer.size.width * splitFraction))
            HStack(spacing: 0) {
                CodeTextView(
                    text: document.leftText,
                    fileURL: nil,
                    contentKind: .diff,
                    topInset: 10,
                    fontSize: fontSize,
                    allowsCommenting: false,
                    focusedLineRange: focusedDocumentRange,
                    // Move sources are deleted code, which renders on this pane in split view.
                    moveLinks: moveLinkModels(in: document, pane: .left),
                    rowKinds: document.leftKinds,
                    highlightSpans: highlightSpans(in: document, pane: .left),
                    primaryLineMap: document.leftFileLines,
                    syncGroup: diffScrollSync,
                    showsVerticalScroller: false,
                    sectionHeaders: sectionHeaderModels(in: document),
                    onHeaderLineToggle: { line in toggleCollapse(atDocumentLine: line) },
                    onSectionToggle: { path in toggleCollapse(path: path) },
                    onSectionOpen: { path in openSection(path: path) },
                    onMoveLinkClick: { link in jumpToMoveCounterpart(link) }
                )
                    .frame(width: leftWidth)
                    .accessibilityIdentifier("diff-left")

                PaneSplitHandle(
                    onDrag: { deltaX in
                        guard outer.size.width > 0 else { return }
                        splitFraction = min(max(splitFraction + deltaX / outer.size.width, 0.15), 0.85)
                    },
                    onDoubleClick: {
                        withAnimation(.easeInOut(duration: 0.15)) { splitFraction = 0.5 }
                    }
                )
                .frame(width: 10)

                primaryDiffPane(document)
            }
        }
    }

    /// The interactive pane (the only one in unified layout; the right one in split): comments,
    /// definitions, header controls, scroll-spy, find, and the inline composer all live here.
    private func primaryDiffPane(_ document: SideBySideDocument) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                CodeTextView(
                    text: document.rightText,
                    fileURL: nil,
                    contentKind: .diff,
                    topInset: 10,
                    fontSize: fontSize,
                    focusedLineRange: focusedDocumentRange,
                    commentedLineRanges: rightCommentRanges(in: document),
                    moveLinks: moveLinkModels(in: document, pane: document.layout == .split ? .right : .unified),
                    rowKinds: document.rightKinds,
                    highlightSpans: highlightSpans(in: document, pane: document.layout == .split ? .right : .unified),
                    primaryLineMap: document.rightFileLines,
                    secondaryLineMap: document.layout == .unified ? document.leftFileLines : [],
                    syncGroup: document.layout == .split ? diffScrollSync : nil,
                    sectionHeaders: sectionHeaderModels(in: document),
                    composerAnchorLines: comments.draft?.origin == .diff ? draftAnchorRows : nil,
                    scrollRequest: scrollRequest,
                    findQuery: activeFindQuery,
                    findActiveIndex: diffFind.activeIndex,
                    onSelectionChange: { raw in
                        lastPrimarySelection = raw
                        selectionDidChange(mapRightSelection(raw))
                    },
                    onAddComment: { raw in beginComment(mapRightSelection(raw), documentSelection: raw) },
                    onFirstVisibleLineChange: topLineDidChange,
                    onCommandClick: { line, column, anchor in
                        commandClickInChanges(line: line, column: column, anchor: anchor)
                    },
                    onHeaderLineToggle: { line in toggleCollapse(atDocumentLine: line) },
                    onComposerAnchorChange: { changesComposerAnchor = $0 },
                    onSectionToggle: { path in toggleCollapse(path: path) },
                    onSectionOpen: { path in openSection(path: path) },
                    onFindResults: { diffFind.matchCount = $0 },
                    onCommentMarkerClick: { rows in selectComment(atDocumentRows: rows) },
                    onMoveLinkClick: { link in jumpToMoveCounterpart(link) }
                )
                    .accessibilityIdentifier("diff-right")

                if comments.draft?.origin == .diff, let anchor = changesComposerAnchor {
                    inlineComposer(anchor: anchor, in: geometry.size)
                }

                if let dropdown = changesReferencesDropdown {
                    referencesDropdown(dropdown, in: geometry.size)
                }
            }
        }
    }

    /// The references dropdown, anchored next to the ⌘-clicked symbol. A clear backdrop
    /// catches stray clicks so any click elsewhere dismisses it.
    private func referencesDropdown(
        _ presentation: SymbolReferencesPresentation,
        in size: CGSize
    ) -> some View {
        let dropdownSize = CGSize(width: 460, height: min(dropdownMeasuredHeight, 320))
        let origin = AnchoredOverlayLayout.origin(
            anchor: presentation.anchor,
            size: dropdownSize,
            in: size
        )
        return ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { changesReferencesDropdown = nil }
            ReferencesDropdownView(
                symbol: presentation.symbol,
                references: presentation.references,
                fontSize: fontSize,
                onOpen: { reference in
                    changesReferencesDropdown = nil
                    let url = URL(fileURLWithPath: reference.file)
                    openInExplorer(
                        url: url,
                        displayPath: displayPath(for: url),
                        focus: reference.line...reference.line
                    )
                },
                onDismiss: { changesReferencesDropdown = nil }
            )
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { newHeight in
                dropdownMeasuredHeight = newHeight
            }
            .offset(x: origin.x, y: origin.y)
            .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
        }
    }

    /// The composer floats right under the commented lines — the code being discussed stays
    /// visible in the editor itself. Positioned with its real measured height, flipping above
    /// the selection when there's no room below.
    private func inlineComposer(anchor: CGRect, in size: CGSize) -> some View {
        let width = min(440, max(size.width - 24, 260))
        let height = max(composerMeasuredHeight, 110)
        let below = anchor.maxY + 8
        let y = below + height > size.height - 8
            ? max(anchor.minY - height - 8, 8)
            : below
        let x = min(max(anchor.minX, 12), max(size.width - width - 12, 12))

        return InlineCommentComposer(controller: comments, fontSize: fontSize)
            .frame(width: width)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { newHeight in
                composerMeasuredHeight = newHeight
            }
            .offset(x: x, y: y)
            .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
    }

    // MARK: - Transient status toast

    /// Short-lived feedback ("Resolving…", "No definition found.") as a small glass capsule
    /// at the top center — the sticky section headers own the top strip otherwise.
    @ViewBuilder
    private var statusToast: some View {
        if let transientStatus {
            Text(transientStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .glassEffect(.regular, in: .capsule)
                .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
                .transition(.opacity)
        }
    }

    private func selectionDidChange(_ context: CodeSelectionContext?) {
        let changed = context != selectionContext
        selectionContext = context
        // A fresh selection means the reviewer moved on — drop the comment highlight so the
        // yellow band always points at exactly one thing.
        if changed, context != nil, comments.selectedCommentID != nil {
            comments.selectedCommentID = nil
        }
    }

    private var loadID: String {
        switch changeTreeState {
        case .loading:
            return "waiting"
        case .loaded(let context):
            return Self.documentID(for: context)
        case .notRepository:
            return "no-git"
        }
    }

    private static func documentID(for context: GitChangeContext) -> String {
        // Scope is part of the identity: two sibling commits can share a parent (the same
        // baseRef) and a file set whose hash collides, but must never share a document.
        "document:\(context.branchName):\(context.baseRef ?? "worktree"):\(String(describing: context.scope)):\(context.files.hashValue)"
    }

    // MARK: - Highlighting & layout

    private enum DiffPane {
        case left, right, unified
    }

    /// Highlight spans enriched with complete file texts, so rows are colored from whole-file
    /// highlighting (correct lexer state) rather than truncated diff fragments.
    private func highlightSpans(in document: SideBySideDocument, pane: DiffPane) -> [CodeHighlightSpan] {
        let entriesByPath = Dictionary(uniqueKeysWithValues: loadedEntries.map { ($0.file.path, $0) })
        return document.sections.compactMap { section in
            let bodyStart = section.headerLine + SideBySideDocument.headerRowCount
            guard !section.isCollapsed, !section.isPlaceholder, let language = section.language,
                  section.endLine >= bodyStart else { return nil }
            let entry = entriesByPath[section.file.path]
            let primaryText: String?
            let secondaryText: String?
            switch pane {
            case .left:
                primaryText = entry?.oldText
                secondaryText = nil
            case .right:
                primaryText = entry?.newText
                secondaryText = nil
            case .unified:
                primaryText = entry?.newText
                secondaryText = entry?.oldText // deletions highlight from the base version
            }
            return CodeHighlightSpan(
                startLine: bodyStart,
                endLine: section.endLine,
                language: language,
                primaryText: primaryText,
                secondaryText: secondaryText
            )
        }
    }

    /// Rebuilds the document in the newly chosen layout, keeping the same file at the top and
    /// re-deriving comment emphasis and composer anchors in the new row space.
    private func rebuildForLayoutChange() {
        guard case .document(let old) = state, !loadedEntries.isEmpty,
              old.layout != diffLayout else { return }
        let anchorPath = old.section(containingLine: topDocumentLine)?.file.path
        let document = SideBySideDocument.build(
            entries: loadedEntries,
            collapsedPaths: collapsedPaths,
            layout: diffLayout
        )
        state = .document(document)

        if let id = comments.selectedCommentID,
           let comment = comments.comments.first(where: { $0.id == id }), comment.origin == .diff {
            focusedDocumentRange = document.rowRange(
                forNewFileLines: comment.startLine...max(comment.endLine, comment.startLine),
                inSectionPath: comment.filePath
            )
        } else if comments.draft == nil {
            focusedDocumentRange = nil
        }
        if let draft = comments.draft, draft.origin == .diff {
            let rows = document.rowRange(
                forNewFileLines: draft.startLine...draft.endLine,
                inSectionPath: draft.filePath
            )
            draftAnchorRows = rows
            focusedDocumentRange = rows
        }
        if let anchorPath, let section = document.section(forPath: anchorPath) {
            scrollRequest = CodeScrollRequest(line: section.headerLine)
        }
    }

    // MARK: - Collapse (reviewed files)

    /// Header-control models for the interactive pane: file identity, ±stats, collapse state.
    private func sectionHeaderModels(in document: SideBySideDocument) -> [DiffSectionHeaderModel] {
        document.sections.map { section in
            let (label, tint) = Self.statusPresentation(for: section.file.status)
            return DiffSectionHeaderModel(
                path: section.file.path,
                row: section.headerLine,
                fileName: (section.file.path as NSString).lastPathComponent,
                directory: (section.file.path as NSString).deletingLastPathComponent,
                statusLabel: label,
                statusTint: tint,
                additions: section.additions,
                deletions: section.deletions,
                isCollapsed: section.isCollapsed,
                hiddenLineCount: section.hiddenLineCount
            )
        }
    }

    private static func statusPresentation(for status: GitFileStatus) -> (String?, DiffSectionHeaderModel.StatusTint) {
        switch status {
        case .added: return ("Added", .green)
        case .untracked: return ("New", .green)
        case .deleted: return ("Deleted", .red)
        case .renamed: return ("Renamed", .purple)
        case .copied: return ("Copied", .purple)
        case .conflicted: return ("Conflict", .orange)
        case .typeChanged: return ("Type", .blue)
        case .modified, .unknown: return (nil, .blue)
        }
    }

    private func openSection(path: String) {
        guard case .document(let document) = state,
              let section = document.section(forPath: path) else { return }
        openInExplorer(url: section.file.url, displayPath: path, focus: nil)
    }

    private func toggleCollapse(atDocumentLine line: Int) {
        guard
            case .document(let document) = state,
            let section = document.section(containingLine: line),
            section.headerRowRange.contains(line)
        else {
            return
        }
        toggleCollapse(path: section.file.path)
    }

    private func toggleCollapse(path: String) {
        if collapsedPaths.contains(path) {
            collapsedPaths.remove(path)
        } else {
            collapsedPaths.insert(path)
        }
        rebuildDocument(anchoredTo: path)
        persistViewState()
    }

    private func rebuildDocument(anchoredTo path: String?) {
        guard !loadedEntries.isEmpty else { return }
        let document = SideBySideDocument.build(
            entries: loadedEntries,
            collapsedPaths: collapsedPaths,
            layout: diffLayout
        )
        state = .document(document)
        if let path, let section = document.section(forPath: path) {
            scrollRequest = CodeScrollRequest(line: section.headerLine)
        }
    }

    private func scheduleViewStatePersist() {
        viewStateSaveTask?.cancel()
        viewStateSaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            persistViewState()
        }
    }

    private func persistViewState() {
        guard let viewStateStore, case .document(let document) = state else { return }
        var anchorPath: String?
        var anchorOffset: Int?
        if let section = document.section(containingLine: topDocumentLine) {
            anchorPath = section.file.path
            anchorOffset = topDocumentLine - section.headerLine
        }
        let snapshot = ChangeSetViewState(
            collapsedPaths: collapsedPaths.sorted(),
            anchorPath: anchorPath,
            anchorLineOffset: anchorOffset
        )
        let store = viewStateStore
        Task.detached(priority: .utility) {
            store.save(snapshot)
        }
    }

    // MARK: - Navigation within the document

    /// Selections on the interactive pane carry row numbers; rewrite them to the file and its
    /// real (new version) line numbers. Nil when the selection holds no new-version lines.
    private func mapRightSelection(_ context: CodeSelectionContext?) -> CodeSelectionContext? {
        guard
            let context,
            case .document(let document) = state,
            let section = document.section(containingLine: context.startLine)
        else {
            return context
        }
        let rows = max(context.startLine, section.headerLine)...min(max(context.endLine, context.startLine), section.endLine)
        var fileLines: [Int] = []
        for row in rows {
            if let line = document.rightFileLines[row - 1] {
                fileLines.append(line)
            }
        }
        guard let startLine = fileLines.min(), let endLine = fileLines.max() else { return nil }
        return CodeSelectionContext(
            fileURL: section.file.url,
            contentKind: .diff,
            startLine: startLine,
            endLine: endLine,
            text: context.text
        )
    }

    private func topLineDidChange(_ line: Int) {
        topDocumentLine = line
        // Jump-anchor bookkeeping: the first emit after a jump records where it parked;
        // any movement after that means the user scrolled, so stepping re-anchors to the
        // viewport on the next press.
        if var anchor = changeJumpAnchor {
            if anchor.parkedTopLine == nil {
                anchor.parkedTopLine = line
                changeJumpAnchor = anchor
            } else if anchor.parkedTopLine != line {
                changeJumpAnchor = nil
            }
        }
        guard
            case .document(let document) = state,
            let section = document.section(containingLine: line)
        else {
            return
        }
        scheduleViewStatePersist()
    }

    // MARK: - Review comments

    /// ⌘K: start a comment on the current selection. No selection (or one with no
    /// new-version lines) gets the same guidance the bubble path shows.
    private func beginCommentFromKeyboard() {
        guard comments.draft == nil else { return } // already composing
        if case .document = state {
            beginComment(mapRightSelection(lastPrimarySelection), documentSelection: lastPrimarySelection)
        } else {
            beginComment(lastPrimarySelection, documentSelection: nil)
        }
    }

    /// Starts a comment draft from the ＋bubble. `context` is already file-mapped;
    /// `documentSelection` carries the raw pane rows so the inline composer can anchor under
    /// them and the drafted lines can be emphasized while writing.
    private func beginComment(_ context: CodeSelectionContext?, documentSelection: CodeSelectionContext?) {
        guard let context, let url = context.fileURL else {
            showTransientStatus("Select lines from the new version to comment.")
            return
        }
        comments.beginDraft(CommentDraft(
            filePath: displayPath(for: url),
            origin: context.contentKind == .diff ? .diff : .source,
            startLine: context.startLine,
            endLine: max(context.endLine, context.startLine),
            codeText: context.text
        ))
        if let documentSelection {
            let rows = documentSelection.startLine...max(documentSelection.endLine, documentSelection.startLine)
            draftAnchorRows = rows
            focusedDocumentRange = rows
        }
    }

    /// Comment card clicked: bring the exact commented lines back into view, expanding the
    /// file if it was collapsed. Source comments open in the Explorer panel.
    private func jump(to comment: ReviewComment) {
        comments.selectedCommentID = comment.id
        switch comment.origin {
        case .diff:
            if collapsedPaths.contains(comment.filePath) {
                collapsedPaths.remove(comment.filePath)
                rebuildDocument(anchoredTo: nil)
                persistViewState()
            }
            guard
                case .document(let document) = state,
                let section = document.section(forPath: comment.filePath),
                let rows = document.rowRange(
                    forNewFileLines: comment.startLine...max(comment.endLine, comment.startLine),
                    inSectionPath: comment.filePath
                )
            else {
                return
            }
            focusedDocumentRange = rows
            scrollRequest = CodeScrollRequest(line: max(rows.lowerBound - 3, section.headerLine))
        case .source:
            let url = comment.filePath.hasPrefix("~")
                ? URL(fileURLWithPath: (comment.filePath as NSString).expandingTildeInPath)
                : rootURL.appendingPathComponent(comment.filePath)
            openInExplorer(
                url: url,
                displayPath: comment.filePath,
                focus: comment.startLine...max(comment.endLine, comment.startLine)
            )
        }
    }

    /// Marker bar clicked in the diff: light up that comment and open the panel to its card.
    private func selectComment(atDocumentRows rows: ClosedRange<Int>) {
        guard case .document(let document) = state else { return }
        guard let match = comments.comments.first(where: { comment in
            comment.origin == .diff && document.rowRange(
                forNewFileLines: comment.startLine...max(comment.endLine, comment.startLine),
                inSectionPath: comment.filePath
            ) == rows
        }) else {
            return
        }
        comments.selectedCommentID = match.id
        focusedDocumentRange = rows
        withAnimation(.easeInOut(duration: 0.2)) { showCommentsPanel = true }
    }

    /// Marker bar clicked in the Explorer panel: same, for a source comment.
    private func selectSourceComment(_ comment: ReviewComment) {
        comments.selectedCommentID = comment.id
        withAnimation(.easeInOut(duration: 0.2)) { showCommentsPanel = true }
    }

    /// Row ranges (interactive pane) for every diff comment, so commented code stays tinted.
    private func rightCommentRanges(in document: SideBySideDocument) -> [ClosedRange<Int>] {
        comments.comments.compactMap { comment in
            guard comment.origin == .diff else { return nil }
            return document.rowRange(
                forNewFileLines: comment.startLine...max(comment.endLine, comment.startLine),
                inSectionPath: comment.filePath
            )
        }
    }

    // MARK: - Moved code links

    /// Chip models for one pane. Sources (deleted code) render on the left pane in split
    /// layout and inline in unified; destinations (added code) on the right/unified pane.
    /// Blocks whose end is collapsed resolve to no rows and simply drop their chip.
    private func moveLinkModels(in document: SideBySideDocument, pane: DiffPane) -> [MoveLinkModel] {
        guard !movedBlocks.isEmpty else { return [] }
        var models: [MoveLinkModel] = []
        for (index, block) in movedBlocks.enumerated() {
            if pane != .right,
               let rows = document.rowRange(forOldFileLines: block.source.lines, inSectionPath: block.source.path) {
                models.append(moveLinkModel(block, index: index, role: .source, rows: rows))
            }
            if pane != .left,
               let rows = document.rowRange(forNewFileLines: block.destination.lines, inSectionPath: block.destination.path) {
                models.append(moveLinkModel(block, index: index, role: .destination, rows: rows))
            }
        }
        return models
    }

    private func moveLinkModel(
        _ block: MovedBlock,
        index: Int,
        role: MoveLinkModel.Role,
        rows: ClosedRange<Int>
    ) -> MoveLinkModel {
        let counterpart = role == .source ? block.destination : block.source
        let label = block.isWithinOneFile
            ? "line \(counterpart.lines.lowerBound)"
            : (counterpart.path as NSString).lastPathComponent
        let lines = counterpart.lines.count == 1
            ? "line \(counterpart.lines.lowerBound)"
            : "lines \(counterpart.lines.lowerBound)–\(counterpart.lines.upperBound)"
        return MoveLinkModel(
            blockIndex: index,
            role: role,
            rows: rows,
            counterpartLabel: label,
            counterpartDetail: "\(counterpart.path) · \(lines)"
        )
    }

    /// Chip clicked: bring the block's other end into view, expanding its file if collapsed —
    /// the same choreography as jumping to a comment, but resolved through old-file lines
    /// when the target is the removed side.
    private func jumpToMoveCounterpart(_ link: MoveLinkModel) {
        guard link.blockIndex < movedBlocks.count else { return }
        let block = movedBlocks[link.blockIndex]
        let jumpingToDestination = link.role == .source
        let target = jumpingToDestination ? block.destination : block.source
        if collapsedPaths.contains(target.path) {
            collapsedPaths.remove(target.path)
            rebuildDocument(anchoredTo: nil)
            persistViewState()
        }
        guard
            case .document(let document) = state,
            let section = document.section(forPath: target.path),
            let rows = jumpingToDestination
                ? document.rowRange(forNewFileLines: target.lines, inSectionPath: target.path)
                : document.rowRange(forOldFileLines: target.lines, inSectionPath: target.path)
        else {
            showTransientStatus("Couldn't find the moved code.")
            return
        }
        focusedDocumentRange = rows
        scrollRequest = CodeScrollRequest(line: max(rows.lowerBound - 3, section.headerLine))
        let name = (target.path as NSString).lastPathComponent
        showTransientStatus(jumpingToDestination ? "Moved to \(name)" : "Moved from \(name)")
    }

    // MARK: - Go to definition & references

    private func commandClickInChanges(line: Int, column: Int, anchor: CGRect) {
        guard
            case .document(let document) = state,
            let section = document.section(containingLine: line)
        else {
            return
        }

        if section.headerRowRange.contains(line) {
            // ⌘-click a file header opens the whole file in the Explorer.
            openInExplorer(url: section.file.url, displayPath: section.file.path, focus: nil)
            return
        }
        guard !section.isPlaceholder, !section.isCollapsed else { return }
        guard let fileLine = document.rightFileLines[line - 1] else {
            showTransientStatus("No new-version code on that row.")
            return
        }
        resolveSymbol(in: section.file.url, line: fileLine, column: column, fromPanel: false, anchor: anchor)
    }

    /// ⌘-click: usages jump to the definition; the definition itself drops down its usages
    /// next to the clicked symbol (`anchor`).
    private func resolveSymbol(in target: URL, line: Int, column: Int, fromPanel: Bool, anchor: CGRect) {
        guard !isResolvingDefinition else { return }
        let report: (String, Bool) -> Void = { message, autoClears in
            if fromPanel {
                explorer.showStatus(message, autoClears: autoClears)
            } else {
                showTransientStatus(message, autoClears: autoClears)
            }
        }
        let clearReport: () -> Void = {
            if fromPanel {
                explorer.clearStatus()
            } else {
                clearTransientStatus()
            }
        }
        guard TSServer.supportedExtensions.contains(target.pathExtension.lowercased()) else {
            report(TSServerError.unsupportedFile.userMessage, true)
            return
        }
        isResolvingDefinition = true
        report("Resolving…", false)
        Task { @MainActor in
            defer { isResolvingDefinition = false }
            let result = await definitions.definition(
                rootURL: rootURL,
                fileURL: target,
                line: line,
                column: column
            )
            switch result {
            case .success(let spans):
                guard let span = spans.first else {
                    report("No definition found.", true)
                    return
                }
                let targetPath = target.standardizedFileURL.resolvingSymlinksInPath().path
                let spanPath = URL(fileURLWithPath: span.file).standardizedFileURL.resolvingSymlinksInPath().path
                if spanPath == targetPath, span.line == line {
                    // Already on the declaration — the useful answer is its usages.
                    await showReferences(
                        of: target,
                        line: line,
                        column: column,
                        fromPanel: fromPanel,
                        anchor: anchor,
                        report: report,
                        clearReport: clearReport
                    )
                } else {
                    clearReport()
                    let url = URL(fileURLWithPath: span.file)
                    openInExplorer(
                        url: url,
                        displayPath: displayPath(for: url),
                        focus: span.line...span.line
                    )
                }
            case .failure(let error):
                report(error.userMessage, true)
            }
        }
    }

    private func showReferences(
        of target: URL,
        line: Int,
        column: Int,
        fromPanel: Bool,
        anchor: CGRect,
        report: (String, Bool) -> Void,
        clearReport: () -> Void
    ) async {
        let result = await definitions.references(
            rootURL: rootURL,
            fileURL: target,
            line: line,
            column: column
        )
        switch result {
        case .success(let payload):
            let usages = payload.references.filter { !$0.isDefinition }
            guard !usages.isEmpty else {
                report("No usages found.", true)
                return
            }
            clearReport()
            // References render as a dropdown next to the clicked symbol — in whichever
            // view the click happened — instead of replacing the Explorer's content.
            let presentation = SymbolReferencesPresentation(
                symbol: payload.symbolName ?? "symbol",
                references: payload.references,
                anchor: anchor
            )
            if fromPanel {
                explorer.referencesDropdown = presentation
            } else {
                changesReferencesDropdown = presentation
            }
        case .failure(let error):
            report(error.userMessage, true)
        }
    }

    // MARK: - Explorer panel

    private func openInExplorer(url: URL, displayPath: String, focus: ClosedRange<Int>?) {
        explorer.open(url: url, displayPath: displayPath, focus: focus)
        presentExplorerPanel()
    }

    private func presentExplorerPanel() {
        explorerPanel.onClosed = {
            explorer.reset()
            if comments.draft?.origin == .source {
                comments.cancelDraft()
            }
        }
        explorerPanel.present(
            ExplorerPanelView(
                explorer: explorer,
                comments: comments,
                fontSize: fontSize,
                onCommandClick: { url, line, column, anchor in
                    resolveSymbol(in: url, line: line, column: column, fromPanel: true, anchor: anchor)
                },
                onAddComment: { beginComment($0, documentSelection: nil) },
                onOpenReference: { reference in
                    let url = URL(fileURLWithPath: reference.file)
                    explorer.open(
                        url: url,
                        displayPath: displayPath(for: url),
                        focus: reference.line...reference.line
                    )
                },
                onSelectComment: { comment in selectSourceComment(comment) }
            ),
            title: explorer.panelTitle
        )
    }

    private func displayPath(for url: URL) -> String {
        let rootPath = rootURL.standardizedFileURL.resolvingSymlinksInPath().path
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        if path.hasPrefix(rootPath + "/") {
            return String(path.dropFirst(rootPath.count + 1))
        }
        return (path as NSString).abbreviatingWithTildeInPath
    }

    // MARK: - Change navigation (⌥⌘↓ / ⌥⌘↑)

    /// Rows of context kept above a jumped-to change (also clears the sticky section bar).
    private static let jumpContextRows = 3
    /// Where a jump parks the viewport top relative to its target: the context rows above,
    /// plus the sticky-bar allowance `scrollLineToTop` adds, plus one for probe rounding.
    /// Only the re-anchoring fallback uses this; repeated presses step by index exactly.
    private static let jumpParkAllowance = jumpContextRows + SideBySideDocument.headerRowCount + 1

    /// Steps to the next/previous hunk. Anchored by *index*, not scroll position: deriving
    /// "where am I" from the viewport top after a jump needs the exact park arithmetic, and
    /// getting it off by even one row re-finds the same target forever (the buttons look
    /// dead). So repeated presses step the last jump's index, and the viewport-derived
    /// search only runs when the user scrolled (or the document changed) since then.
    private func jumpToChange(forward: Bool) {
        guard case .document(let document) = state else {
            // Never let the chevrons no-op silently — the combined document for a big
            // branch takes a moment to assemble.
            showTransientStatus("Changes are still loading…")
            return
        }
        let targets = document.changeJumpTargets()
        guard !targets.isEmpty else {
            showTransientStatus("No changes to jump to.")
            return
        }
        let index: Int?
        if let anchor = changeJumpAnchor,
           targets.indices.contains(anchor.index), targets[anchor.index] == anchor.row {
            index = anchor.index + (forward ? 1 : -1)
        } else {
            let current = topDocumentLine + Self.jumpParkAllowance
            index = forward
                ? targets.firstIndex(where: { $0 > current })
                : targets.lastIndex(where: { $0 < current })
        }
        guard let index, targets.indices.contains(index) else {
            showTransientStatus(forward ? "No changes below." : "No changes above.")
            return
        }
        changeJumpAnchor = ChangeJumpAnchor(index: index, row: targets[index], parkedTopLine: nil)
        scrollRequest = CodeScrollRequest(line: max(targets[index] - Self.jumpContextRows, 1))
        showTransientStatus("Change \(index + 1) of \(targets.count)")
    }

    /// The last jump's target (index + row, so a rebuilt document that renumbers rows
    /// invalidates it) and the viewport top observed once its scroll settled — a later
    /// top-line change means the user scrolled away and the anchor no longer holds.
    private struct ChangeJumpAnchor: Equatable {
        let index: Int
        let row: Int
        var parkedTopLine: Int?
    }

    private func showTransientStatus(_ message: String, autoClears: Bool = true) {
        transientStatusTask?.cancel()
        transientStatus = message
        guard autoClears else { return }
        transientStatusTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            guard !Task.isCancelled else { return }
            transientStatus = nil
        }
    }

    private func clearTransientStatus() {
        transientStatusTask?.cancel()
        transientStatus = nil
    }

    private func glassPlaceholder(_ text: String, systemImage: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage).font(.system(size: 36)).foregroundStyle(.secondary)
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(28)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Loading

    @MainActor
    private func load() async {
        switch changeTreeState {
        case .loading:
            state = .loading
        case .loaded(let context):
            await load(document: context)
        case .notRepository(let reason):
            state = .message(reason)
        }
    }

    @MainActor
    private func load(document context: GitChangeContext) async {
        let store = ChangeSetViewStateStore(rootURL: rootURL, branchName: context.branchName)
        viewStateStore = store

        guard !context.files.isEmpty else {
            loadedEntries = []
            loadedDocumentID = nil
            state = .message("No changed files on this branch.")
            return
        }

        let id = Self.documentID(for: context)
        if loadedDocumentID == id, !loadedEntries.isEmpty {
            return // already showing this change set
        }

        state = .loading
        let (entries, savedState, moves) = await Task.detached(priority: .userInitiated) {
            let entries = GitChangeSet.loadDocumentEntries(for: context)
            return (entries, store.load(), MovedBlockDetector.detect(entries: entries))
        }.value
        if Task.isCancelled { return }

        loadedEntries = entries
        movedBlocks = moves
        loadedDocumentID = id
        let knownPaths = Set(entries.map(\.file.path))
        collapsedPaths = Set(savedState.collapsedPaths).intersection(knownPaths)

        let document = SideBySideDocument.build(
            entries: entries,
            collapsedPaths: collapsedPaths,
            layout: diffLayout
        )
        selectionContext = nil
        state = .document(document)

        // Restore the persisted reading position; fall back to the first section.
        if let anchorPath = savedState.anchorPath,
           let section = document.section(forPath: anchorPath) {
            let offset = max(savedState.anchorLineOffset ?? 0, 0)
            scrollRequest = CodeScrollRequest(line: min(section.headerLine + offset, section.endLine))
        } else if let target = document.sections.first {
            scrollRequest = CodeScrollRequest(line: target.headerLine)
        }
    }
}

/// AppKit-backed drag handle for the old↔new pane split. SwiftUI drag gestures wedged
/// between two hosted NSScrollViews lose events; a real NSView with its own mouse tracking
/// and cursor rects is deterministic.
private struct PaneSplitHandle: NSViewRepresentable {
    var onDrag: (CGFloat) -> Void
    var onDoubleClick: () -> Void

    func makeNSView(context: Context) -> PaneSplitHandleNSView {
        let view = PaneSplitHandleNSView()
        view.onDrag = onDrag
        view.onDoubleClick = onDoubleClick
        return view
    }

    func updateNSView(_ nsView: PaneSplitHandleNSView, context: Context) {
        nsView.onDrag = onDrag
        nsView.onDoubleClick = onDoubleClick
    }
}

final class PaneSplitHandleNSView: NSView {
    var onDrag: ((CGFloat) -> Void)?
    var onDoubleClick: (() -> Void)?
    private var isHovering = false
    private var isDragging = false

    override var isFlipped: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }
        isDragging = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        onDrag?(event.deltaX)
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let emphasized = isHovering || isDragging
        let lineWidth: CGFloat = emphasized ? 2 : 1
        let color = emphasized
            ? NSColor.controlAccentColor.withAlphaComponent(0.7)
            : NSColor.separatorColor.withAlphaComponent(0.6)
        color.setFill()
        NSRect(
            x: (bounds.width - lineWidth) / 2,
            y: 0,
            width: lineWidth,
            height: bounds.height
        ).fill()
    }

    override var acceptsFirstResponder: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
