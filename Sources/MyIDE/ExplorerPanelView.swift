import SwiftUI
import AppKit
import MyIDECore

/// Content of the floating Explorer panel: a glass header with one always-working back
/// button over a source file (⌘-clickable, commentable, findable). ⌘F opens the panel's own
/// find bar. References to a ⌘-clicked declaration appear as a dropdown anchored next to the
/// symbol, never as a page of their own.
struct ExplorerPanelView: View {
    @ObservedObject var explorer: ExplorerController
    @ObservedObject var comments: ReviewCommentsController
    let fontSize: CGFloat
    /// Resolve a ⌘-click inside the panel's file (url, 1-based line, column, and the clicked
    /// symbol's rect in the panel's coordinate space — the anchor for a references dropdown).
    var onCommandClick: (URL, Int, Int, CGRect) -> Void = { _, _, _, _ in }
    /// Begin a comment draft from a selection in the panel's file.
    var onAddComment: (CodeSelectionContext?) -> Void = { _ in }
    /// Open a reference row (url, root-relative-ish path, line).
    var onOpenReference: (TSReference) -> Void = { _ in }
    /// A comment marker bar was clicked: show this comment in the main window's panel.
    var onSelectComment: (ReviewComment) -> Void = { _ in }

    @State private var find = FindState()
    @State private var composerAnchor: CGRect?
    @State private var composerMeasuredHeight: CGFloat = 110
    @State private var dropdownMeasuredHeight: CGFloat = 260
    /// Latest selection in the panel's file, so ⌘K can start a comment like the ＋bubble.
    @State private var currentSelection: CodeSelectionContext?

    var body: some View {
        ZStack(alignment: .top) {
            content
            header
                .padding(.horizontal, 10)
                .padding(.top, 8)
            if find.isActive {
                CodeFindBar(state: $find, fontSize: fontSize)
                    .frame(maxWidth: 320)
                    .padding(.top, 58)
                    .padding(.trailing, 12)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .transition(.opacity)
            }
        }
        .frame(minWidth: 480, minHeight: 320)
        .background(Color(nsColor: .textBackgroundColor))
        .background(
            // Window-scoped shortcuts: these only fire while this panel is key.
            Group {
                Button("") {
                    withAnimation(.easeInOut(duration: 0.12)) { find.isActive = true }
                }
                .keyboardShortcut("f", modifiers: .command)

                // ⌘K: comment on the current selection, same as clicking the ＋bubble.
                Button("") {
                    guard comments.draft == nil else { return }
                    if let currentSelection {
                        onAddComment(currentSelection)
                    } else {
                        explorer.showStatus("Select lines to comment on.")
                    }
                }
                .keyboardShortcut("k", modifiers: .command)
            }
            .opacity(0)
            .accessibilityHidden(true)
        )
        .onChange(of: explorer.current) { _, _ in
            find = FindState() // a new file is a new search context
            currentSelection = nil
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                explorer.goBack()
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .disabled(!explorer.canGoBack)
            .help("Back")

            Image(systemName: headerIcon)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(headerTitle)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let headerSubtitle {
                    Text(headerSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
            if let status = explorer.status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
        .glassEffect(.regular, in: .rect(cornerRadius: 21))
        .animation(.easeInOut(duration: 0.18), value: explorer.status)
    }

    private var headerTitle: String {
        guard let entry = explorer.current else { return "Explorer" }
        return (entry.displayPath as NSString).lastPathComponent
    }

    private var headerSubtitle: String? {
        guard let entry = explorer.current else { return nil }
        let directory = (entry.displayPath as NSString).deletingLastPathComponent
        return directory.isEmpty ? nil : directory
    }

    private var headerIcon: String { "doc.text.magnifyingglass" }

    @ViewBuilder
    private var content: some View {
        fileContent
    }

    @ViewBuilder
    private var fileContent: some View {
        switch explorer.state {
        case .empty:
            placeholder("⌘-click a symbol in the changes to explore it", systemImage: "arrow.triangle.turn.up.right.circle")
        case .loading:
            ProgressView().controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .text(let text):
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    CodeTextView(
                        text: text,
                        fileURL: explorer.currentFileEntry?.url,
                        contentKind: .source,
                        topInset: 58,
                        fontSize: fontSize,
                        focusedLineRange: explorer.currentFileEntry?.focusLineRange,
                        commentedRanges: commentRanges,
                        composerAnchorLines: draftAnchorLines,
                        scrollRequest: explorer.scrollRequest,
                        findQuery: find.isActive && !find.query.isEmpty ? find.query : nil,
                        findActiveIndex: find.activeIndex,
                        onSelectionChange: { currentSelection = $0 },
                        onAddComment: onAddComment,
                        onFirstVisibleLineChange: { explorer.noteTopLine($0) },
                        onCommandClick: { line, column, anchor in
                            guard let entry = explorer.currentFileEntry else { return }
                            onCommandClick(entry.url, line, column, anchor)
                        },
                        onComposerAnchorChange: { composerAnchor = $0 },
                        onFindResults: { count in find.matchCount = count },
                        onCommentMarkerClick: { lines in
                            guard let entry = explorer.currentFileEntry,
                                  let comment = comments.comments.first(where: {
                                      $0.origin == .source
                                          && $0.filePath == entry.displayPath
                                          && $0.startLine == lines.lowerBound
                                  }) else { return }
                            onSelectComment(comment)
                        }
                    )
                        .accessibilityIdentifier("explorer-view")

                    if comments.draft?.origin == .source, let anchor = composerAnchor {
                        inlineComposer(anchor: anchor, in: geometry.size)
                    }

                    if let dropdown = explorer.referencesDropdown {
                        referencesDropdown(dropdown, in: geometry.size)
                    }
                }
            }
        case .message(let message):
            placeholder(message, systemImage: "doc")
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
                .onTapGesture { explorer.referencesDropdown = nil }
            ReferencesDropdownView(
                symbol: presentation.symbol,
                references: presentation.references,
                fontSize: fontSize,
                onOpen: { reference in
                    explorer.referencesDropdown = nil
                    onOpenReference(reference)
                },
                onDismiss: { explorer.referencesDropdown = nil }
            )
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { newHeight in
                dropdownMeasuredHeight = newHeight
            }
            .offset(x: origin.x, y: origin.y)
            .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
        }
    }

    private var commentRanges: [CommentedCodeRange] {
        guard let entry = explorer.currentFileEntry else { return [] }
        return comments.comments.compactMap { comment in
            guard comment.origin == .source, comment.filePath == entry.displayPath else { return nil }
            return CommentedCodeRange(
                rows: comment.startLine...max(comment.endLine, comment.startLine),
                startColumn: comment.startColumn,
                endColumn: comment.endColumn
            )
        }
    }

    private var draftAnchorLines: ClosedRange<Int>? {
        guard let draft = comments.draft, draft.origin == .source else { return nil }
        return draft.startLine...draft.endLine
    }

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

    private func placeholder(_ text: String, systemImage: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage).font(.system(size: 32)).foregroundStyle(.secondary)
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
