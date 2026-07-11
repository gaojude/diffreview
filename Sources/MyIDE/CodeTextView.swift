import SwiftUI
import AppKit
import MyIDECore
import Highlighter

enum CodeContentKind: String, Codable, Equatable, Sendable {
    case source
    case diff
}

struct CodeSelectionContext: Codable, Equatable, Sendable {
    let fileURL: URL?
    let contentKind: CodeContentKind
    let startLine: Int
    let endLine: Int
    let text: String

    var lineLabel: String {
        startLine == endLine ? "Line \(startLine)" : "Lines \(startLine)-\(endLine)"
    }

    var locationLabel: String {
        if let fileURL {
            return "\(fileURL.lastPathComponent) \(lineLabel)"
        }
        return lineLabel
    }
}

/// A one-shot "scroll this line to the top" command. Each request has a fresh identity so
/// repeating the same line (e.g. re-clicking a file in the sidebar) still scrolls.
struct CodeScrollRequest: Equatable {
    let id = UUID()
    let line: Int

    init(line: Int) {
        self.line = line
    }
}

/// A run of rows to syntax-highlight. When `primaryText`/`secondaryText` (complete file
/// contents) are present, each row is colored from the *whole file's* highlighting, located by
/// its real line number — truncated diff fragments mislead lexers (a hunk starting mid-string
/// or mid-comment poisons everything after it), whole files never do. Without texts, the
/// displayed chunk itself is highlighted as a fallback.
struct CodeHighlightSpan: Equatable {
    let startLine: Int
    let endLine: Int
    let language: String
    /// File content whose line numbers the view's `primaryLineMap` refers to.
    let primaryText: String?
    /// Second source tried per row (e.g. the base version for unified-view deletions).
    let secondaryText: String?
}

/// Everything a section header control shows: identity, stats, and collapse state. Assembled
/// by the content pane from the side-by-side document + git status.
struct DiffSectionHeaderModel: Equatable, Identifiable {
    let path: String
    /// First row of the section's header block (1-based).
    let row: Int
    let fileName: String
    let directory: String
    let statusLabel: String?
    let statusTint: StatusTint
    let additions: Int
    let deletions: Int
    let isCollapsed: Bool
    let hiddenLineCount: Int

    var id: String { path }

    enum StatusTint: Equatable {
        case green, red, purple, orange, blue

        var color: Color {
            switch self {
            case .green: return .green
            case .red: return .red
            case .purple: return .purple
            case .orange: return .orange
            case .blue: return .blue
            }
        }
    }
}

/// Keeps a set of scroll views vertically locked together — the two halves of the
/// side-by-side diff share one of these. Their documents have identical row counts, so
/// mirroring the raw scroll offset keeps rows aligned exactly. Main-thread only, like the
/// scroll views it mirrors (bounds-change notifications always arrive there).
final class ScrollSyncGroup {
    private struct Member {
        weak var scrollView: NSScrollView?
    }

    private var members: [Member] = []
    private var isSyncing = false

    func register(_ scrollView: NSScrollView) {
        members.removeAll { $0.scrollView == nil || $0.scrollView === scrollView }
        members.append(Member(scrollView: scrollView))
    }

    func mirror(from source: NSScrollView) {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        let y = source.contentView.bounds.origin.y
        for member in members {
            guard let scrollView = member.scrollView, scrollView !== source else { continue }
            let clipView = scrollView.contentView
            var origin = clipView.bounds.origin
            guard abs(origin.y - y) > 0.5 else { continue }
            origin.y = y
            let constrained = clipView.constrainBoundsRect(NSRect(origin: origin, size: clipView.bounds.size)).origin
            clipView.setBoundsOrigin(constrained)
            scrollView.reflectScrolledClipView(clipView)
        }
    }
}

/// Read-only, monospaced code viewer backed by AppKit's `NSTextView`. Native text layout
/// handles large files far better than SwiftUI's `Text`, which is the point of using a
/// representable here.
struct CodeTextView: NSViewRepresentable {
    let text: String
    let fileURL: URL?
    var contentKind: CodeContentKind = .source
    /// Space reserved at the top so content scrolls under the floating glass header.
    var topInset: CGFloat = 8
    /// Monospaced point size, driven by the View-menu font shortcuts.
    var fontSize: CGFloat = FontSizes.default
    var allowsCommenting = true
    var focusedLineRange: ClosedRange<Int>?
    /// Lines that carry review comments; tinted so commented code is recognizable at a glance.
    var commentedLineRanges: [ClosedRange<Int>] = []
    /// Side-by-side row metadata: when non-empty, per-row backgrounds (add/delete/filler…)
    /// replace the unified `+`/`-` prefix styling.
    var rowKinds: [SideBySideDocument.RowKind] = []
    /// Line runs to syntax-highlight with a specific language (one per file section).
    var highlightSpans: [CodeHighlightSpan] = []
    /// Real file line numbers per row for `primaryText` (e.g. new-version lines).
    var primaryLineMap: [Int?] = []
    /// Real file line numbers per row for `secondaryText` (e.g. base-version lines).
    var secondaryLineMap: [Int?] = []
    /// Registering two views in one group locks their vertical scrolling together.
    var syncGroup: ScrollSyncGroup?
    var showsVerticalScroller = true
    /// Real header controls drawn over each section's (empty) header rows.
    var sectionHeaders: [DiffSectionHeaderModel] = []
    /// Lines the inline comment composer is anchored to; their on-screen rect is reported via
    /// `onComposerAnchorChange` (in this view's top-left coordinate space) as layout/scroll move it.
    var composerAnchorLines: ClosedRange<Int>?
    var scrollRequest: CodeScrollRequest?
    /// Active find query (nil = find inactive); matches get temporary highlights.
    var findQuery: String?
    /// Which match is current; normalized by modulo, so it can grow/shrink freely.
    var findActiveIndex: Int = 0
    var onSelectionChange: (CodeSelectionContext?) -> Void = { _ in }
    /// The floating ＋bubble next to a selection: start a comment on these lines.
    var onAddComment: (CodeSelectionContext?) -> Void = { _ in }
    /// Reports the topmost fully visible line (below the floating header) as the user scrolls,
    /// so the header can track which file of a combined document is in view.
    var onFirstVisibleLineChange: ((Int) -> Void)?
    /// ⌘-click on a character: (1-based line, 1-based column within that line, and the
    /// clicked character's rect in this view's top-left coordinate space — the anchor for
    /// overlays like the references dropdown).
    var onCommandClick: ((_ line: Int, _ column: Int, _ anchor: CGRect) -> Void)?
    /// Plain click on a file-header row of a combined diff (1-based line).
    var onHeaderLineToggle: ((_ line: Int) -> Void)?
    var onComposerAnchorChange: ((CGRect?) -> Void)?
    /// Section header control actions (keyed by the section's path).
    var onSectionToggle: ((String) -> Void)?
    var onSectionOpen: ((String) -> Void)?
    /// Reports the number of find matches whenever the query or text changes.
    var onFindResults: ((Int) -> Void)?
    /// Click on a comment marker bar (the range it spans).
    var onCommentMarkerClick: ((ClosedRange<Int>) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SelectionAskContainerView {
        let container = SelectionAskContainerView()
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = showsVerticalScroller
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        // Reserve room for the floating glass header; the scroller tracks the inset too.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: topInset, left: 0, bottom: 0, right: 0)

        let textView = ClickRoutingTextView()
        textView.onCommandClick = { [weak coordinator = context.coordinator] index in
            coordinator?.handleCommandClick(at: index) ?? false
        }
        textView.onPlainClick = { [weak coordinator = context.coordinator] index in
            coordinator?.handleHeaderClick(at: index) ?? false
        }
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = .textColor
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.lineBreakMode = .byClipping
        textView.setAccessibilityIdentifier("code-text")
        textView.delegate = context.coordinator

        scrollView.documentView = textView
        container.install(scrollView: scrollView, target: context.coordinator, action: #selector(Coordinator.addComment))
        context.coordinator.textView = textView
        context.coordinator.containerView = container
        context.coordinator.observeScrollView(scrollView)
        context.coordinator.syncGroup = syncGroup
        syncGroup?.register(scrollView)
        applyConfiguration(to: context.coordinator)
        context.coordinator.render(
            text,
            language: language,
            contentKind: contentKind,
            fontSize: fontSize,
            focusedLineRange: focusedLineRange,
            commentedLineRanges: commentedLineRanges,
            rowKinds: rowKinds,
            highlightSpans: highlightSpans,
            primaryLineMap: primaryLineMap,
            secondaryLineMap: secondaryLineMap,
            appearance: textView.effectiveAppearance,
            resetScroll: true
        )
        context.coordinator.handleScrollRequest(scrollRequest)
        context.coordinator.applyFind(query: findQuery, activeIndex: findActiveIndex)
        return container
    }

    func updateNSView(_ nsView: SelectionAskContainerView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        applyConfiguration(to: context.coordinator)
        context.coordinator.render(
            text,
            language: language,
            contentKind: contentKind,
            fontSize: fontSize,
            focusedLineRange: focusedLineRange,
            commentedLineRanges: commentedLineRanges,
            rowKinds: rowKinds,
            highlightSpans: highlightSpans,
            primaryLineMap: primaryLineMap,
            secondaryLineMap: secondaryLineMap,
            appearance: textView.effectiveAppearance,
            resetScroll: context.coordinator.currentText != text
        )
        context.coordinator.handleScrollRequest(scrollRequest)
        context.coordinator.applyFind(query: findQuery, activeIndex: findActiveIndex)
    }

    private func applyConfiguration(to coordinator: Coordinator) {
        coordinator.topInset = topInset
        coordinator.fileURL = fileURL
        coordinator.contentKind = contentKind
        coordinator.allowsCommenting = allowsCommenting
        coordinator.onSelectionChange = onSelectionChange
        coordinator.onAddComment = onAddComment
        coordinator.onFirstVisibleLineChange = onFirstVisibleLineChange
        coordinator.onCommandClick = onCommandClick
        coordinator.onHeaderLineToggle = onHeaderLineToggle
        coordinator.onComposerAnchorChange = onComposerAnchorChange
        coordinator.setComposerAnchorLines(composerAnchorLines)
        coordinator.configureSectionHeaders(
            sectionHeaders,
            fontSize: fontSize,
            onToggle: onSectionToggle,
            onOpen: onSectionOpen
        )
        coordinator.configureCommentMarkers(commentedLineRanges, fontSize: fontSize, onTap: onCommentMarkerClick)
        coordinator.onFindResults = onFindResults
        coordinator.updateCommentButton()
    }

    private var language: String? {
        switch contentKind {
        case .source:
            return fileURL.flatMap(SyntaxLanguageResolver.languageName(for:))
        case .diff:
            return "diff"
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var textView: NSTextView?
        weak var containerView: SelectionAskContainerView?
        private let renderQueue = DispatchQueue(label: "com.judegao.myide.syntax-highlighting", qos: .userInitiated)
        private var highlighter: Highlighter?
        private var renderID = 0
        private var currentRenderKey: RenderKey?
        private weak var observedClipView: NSClipView?
        private var lastSelectionContext: CodeSelectionContext?
        private var lastSelectionRect: NSRect?
        private var lineStartsCache: [Int]?
        private var handledScrollRequestID: UUID?
        private var lastEmittedTopLine: Int?
        private var pendingTopLineEmit = false

        var topInset: CGFloat = 0
        var fileURL: URL?
        var contentKind: CodeContentKind = .source
        var allowsCommenting = true
        var onSelectionChange: (CodeSelectionContext?) -> Void = { _ in }
        var onAddComment: (CodeSelectionContext?) -> Void = { _ in }
        var onFirstVisibleLineChange: ((Int) -> Void)?
        var onCommandClick: ((Int, Int, CGRect) -> Void)?
        var onHeaderLineToggle: ((Int) -> Void)?
        var onComposerAnchorChange: ((CGRect?) -> Void)?
        var onFindResults: ((Int) -> Void)?
        var syncGroup: ScrollSyncGroup?
        var currentText: String?
        var rowKindsStore: [SideBySideDocument.RowKind] = []
        private var composerAnchorLines: ClosedRange<Int>?
        private var lastReportedAnchorRect: CGRect?
        private var findMatches: [NSRange] = []
        private var findKey: String?
        private var lastFindScrollKey: String?
        private var currentFontSize: CGFloat = 0
        /// Set when new text loads; consumed by the deferred viewport pass once the view has
        /// real geometry, snapping the horizontal origin flush left of the gutter. (Scrolling
        /// during makeNSView is constrained against a zero-sized clip and silently clamps.)
        private var pendingInitialXReset = false

        // MARK: - Find

        /// Highlights every match of `query` with temporary attributes (display-only — they
        /// ride on top of styling and never touch layout or scroll), emphasizes the active
        /// match, and scrolls to it when it changes.
        func applyFind(query: String?, activeIndex: Int) {
            guard let textView, let layoutManager = textView.layoutManager else { return }
            let nsString = textView.string as NSString
            let fullRange = NSRange(location: 0, length: nsString.length)

            guard let query, !query.isEmpty, nsString.length > 0 else {
                if findKey != nil {
                    layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: fullRange)
                    findKey = nil
                    findMatches = []
                    lastFindScrollKey = nil
                }
                return
            }

            let key = "\(query.lowercased())#\(nsString.length)"
            if key != findKey {
                findKey = key
                findMatches = []
                var searchStart = 0
                while searchStart < nsString.length, findMatches.count < 5000 {
                    let match = nsString.range(
                        of: query,
                        options: [.caseInsensitive],
                        range: NSRange(location: searchStart, length: nsString.length - searchStart)
                    )
                    guard match.location != NSNotFound, match.length > 0 else { break }
                    findMatches.append(match)
                    searchStart = NSMaxRange(match)
                }

                layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: fullRange)
                for match in findMatches {
                    layoutManager.addTemporaryAttribute(
                        .backgroundColor,
                        value: NSColor.systemYellow.withAlphaComponent(0.4),
                        forCharacterRange: match
                    )
                }
                let count = findMatches.count
                DispatchQueue.main.async { [weak self] in
                    self?.onFindResults?(count)
                }
            }

            guard !findMatches.isEmpty else { return }
            let normalized = ((activeIndex % findMatches.count) + findMatches.count) % findMatches.count
            let active = findMatches[normalized]

            // Re-tint: previous active back to yellow, current to orange.
            for match in findMatches {
                layoutManager.addTemporaryAttribute(
                    .backgroundColor,
                    value: NSColor.systemYellow.withAlphaComponent(0.4),
                    forCharacterRange: match
                )
            }
            layoutManager.addTemporaryAttribute(
                .backgroundColor,
                value: NSColor.systemOrange.withAlphaComponent(0.75),
                forCharacterRange: active
            )

            let scrollKey = "\(key)@\(normalized)"
            if scrollKey != lastFindScrollKey {
                lastFindScrollKey = scrollKey
                scrollToLine(lineNumber(at: active.location))
            }
        }

        /// Forwards commented row ranges to the container, which draws the left-edge marker
        /// bars that make commented code findable at a glance (click one to show its comment).
        func configureCommentMarkers(
            _ ranges: [ClosedRange<Int>],
            fontSize: CGFloat,
            onTap: ((ClosedRange<Int>) -> Void)?
        ) {
            guard let containerView else { return }
            let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            let rowHeight = textView?.layoutManager?.defaultLineHeight(for: font) ?? (fontSize * 1.3)
            containerView.setCommentMarkers(
                ranges,
                rowHeight: rowHeight,
                contentTopInset: textView?.textContainerInset.height ?? 8,
                onTap: onTap
            )
        }

        /// Forwards header-control models to the container, which draws and positions them.
        func configureSectionHeaders(
            _ models: [DiffSectionHeaderModel],
            fontSize: CGFloat,
            onToggle: ((String) -> Void)?,
            onOpen: ((String) -> Void)?
        ) {
            guard let containerView else { return }
            let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            let rowHeight = textView?.layoutManager?.defaultLineHeight(for: font) ?? (fontSize * 1.3)
            containerView.setSectionHeaders(
                models,
                rowHeight: rowHeight,
                headerRowCount: SideBySideDocument.headerRowCount,
                contentTopInset: textView?.textContainerInset.height ?? 8,
                onToggle: onToggle,
                onOpen: onOpen
            )
        }

        func setComposerAnchorLines(_ lines: ClosedRange<Int>?) {
            guard lines != composerAnchorLines else { return }
            composerAnchorLines = lines
            scheduleViewportCallbacks()
        }

        /// highlight.js runs in JavaScriptCore; above this size it takes seconds for no visible
        /// benefit, so bigger sources fall back to plain text (diff styling is native anyway).
        static let maxHighlightSize = 1_500_000

        deinit {
            if let observedClipView {
                NotificationCenter.default.removeObserver(
                    self,
                    name: NSView.boundsDidChangeNotification,
                    object: observedClipView
                )
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            emitSelection()
        }

        func observeScrollView(_ scrollView: NSScrollView) {
            guard observedClipView !== scrollView.contentView else { return }
            if let observedClipView {
                NotificationCenter.default.removeObserver(
                    self,
                    name: NSView.boundsDidChangeNotification,
                    object: observedClipView
                )
            }
            observedClipView = scrollView.contentView
            scrollView.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(scrollViewBoundsDidChange),
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView
            )
        }

        @objc func addComment() {
            onAddComment(currentSelectionContext() ?? lastSelectionContext)
        }

        @objc private func scrollViewBoundsDidChange(_ notification: Notification) {
            if let scrollView = textView?.enclosingScrollView {
                syncGroup?.mirror(from: scrollView)
            }
            // Header controls, comment markers, and the gutter track scrolling in the same
            // transaction — their positions are pure arithmetic (fixed row height), no
            // TextKit queries, so this is safe here.
            containerView?.layoutSectionHeaders()
            containerView?.layoutCommentMarkers()
            containerView?.refreshGutter()
            updateCommentButton()
            scheduleViewportCallbacks()
        }

        /// Defers scroll-spy and composer-anchor reporting to the next runloop turn. Bounds
        /// changes also fire *during* text-storage edits and layout passes; querying the layout
        /// manager synchronously from there is TextKit reentrancy (intermittent crashes), and
        /// reporting upward would mutate SwiftUI state mid-view-update. Deferring also
        /// coalesces per-frame scroll floods.
        func scheduleViewportCallbacks() {
            guard onFirstVisibleLineChange != nil || onComposerAnchorChange != nil else { return }
            guard !pendingTopLineEmit else { return }
            pendingTopLineEmit = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pendingTopLineEmit = false
                self.performPendingInitialXResetIfNeeded()
                self.emitFirstVisibleLineIfChanged()
                self.reportComposerAnchor()
            }
        }

        /// One-shot after a text load: rest the horizontal origin flush left of the gutter.
        /// The load-time scroll can run before the view has geometry, where constraining
        /// clamps x to 0 — which leaves the first characters hidden under the gutter.
        private func performPendingInitialXResetIfNeeded() {
            guard pendingInitialXReset, let textView,
                  let scrollView = textView.enclosingScrollView else { return }
            let clipView = scrollView.contentView
            guard clipView.bounds.width > 0 else { return } // not laid out yet; next pass
            pendingInitialXReset = false
            var origin = clipView.bounds.origin
            origin.x = -scrollView.contentInsets.left
            let constrained = clipView.constrainBoundsRect(
                NSRect(origin: origin, size: clipView.bounds.size)
            ).origin
            guard abs(constrained.x - clipView.bounds.origin.x) > 0.5 else { return }
            clipView.setBoundsOrigin(constrained)
            scrollView.reflectScrolledClipView(clipView)
        }

        private func reportComposerAnchor() {
            guard let onComposerAnchorChange else { return }
            let anchorRect = composerAnchorLines.flatMap { boundingRect(forLines: $0) }
            guard anchorRect != lastReportedAnchorRect else { return }
            lastReportedAnchorRect = anchorRect
            onComposerAnchorChange(anchorRect)
        }

        /// Union rect of the given lines, in the container's (flipped, SwiftUI-compatible)
        /// coordinates.
        private func boundingRect(forLines range: ClosedRange<Int>) -> CGRect? {
            guard
                let textView,
                let containerView,
                let layoutManager = textView.layoutManager,
                let textContainer = textView.textContainer
            else {
                return nil
            }
            let starts = lineStarts()
            let length = (textView.string as NSString).length
            guard range.lowerBound >= 1, range.lowerBound <= starts.count, length > 0 else { return nil }
            let startChar = starts[range.lowerBound - 1]
            let endChar = range.upperBound < starts.count ? starts[range.upperBound] - 1 : length
            guard endChar > startChar else { return nil }
            layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: min(endChar + 1, length)))
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: NSRange(location: startChar, length: endChar - startChar),
                actualCharacterRange: nil
            )
            var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            rect.origin.x += textView.textContainerOrigin.x
            rect.origin.y += textView.textContainerOrigin.y
            return textView.convert(rect, to: containerView)
        }

        private func emitFirstVisibleLineIfChanged() {
            guard
                let onFirstVisibleLineChange,
                let textView,
                let layoutManager = textView.layoutManager,
                let textContainer = textView.textContainer
            else {
                return
            }
            let length = (textView.string as NSString).length
            guard length > 0 else { return }
            guard let clipView = textView.enclosingScrollView?.contentView else { return }

            // Probe just below the floating header, in text-container coordinates. The clip
            // view's bounds origin is used (not visibleRect, which clamps at 0 and would
            // mis-report the top of the document by the header height).
            let probeY = clipView.bounds.minY + topInset + 1 - textView.textContainerOrigin.y
            let glyphIndex = layoutManager.glyphIndex(
                for: NSPoint(x: 0, y: max(probeY, 0)),
                in: textContainer
            )
            let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
            let line = lineNumber(at: min(characterIndex, length - 1))
            guard line != lastEmittedTopLine else { return }
            lastEmittedTopLine = line
            onFirstVisibleLineChange(line)
        }

        func updateCommentButton() {
            guard let containerView else { return }
            guard allowsCommenting else {
                containerView.updateCommentButton(selectionRect: nil, isVisible: false)
                return
            }
            let context = currentSelectionContext()
            let rect = currentSelectionRect()
            if let context, let rect {
                lastSelectionContext = context
                lastSelectionRect = rect
            }
            containerView.updateCommentButton(selectionRect: rect, isVisible: context != nil)
        }

        func render(
            _ text: String,
            language: String?,
            contentKind: CodeContentKind,
            fontSize: CGFloat,
            focusedLineRange: ClosedRange<Int>?,
            commentedLineRanges: [ClosedRange<Int>],
            rowKinds: [SideBySideDocument.RowKind],
            highlightSpans: [CodeHighlightSpan],
            primaryLineMap: [Int?],
            secondaryLineMap: [Int?],
            appearance: NSAppearance,
            resetScroll: Bool
        ) {
            let themeName = Self.themeName(for: appearance)
            let key = RenderKey(
                text: text,
                language: language,
                contentKind: contentKind,
                fontSize: fontSize,
                focusedLineRange: focusedLineRange,
                commentedLineRanges: commentedLineRanges,
                rowKinds: rowKinds,
                highlightSpans: highlightSpans,
                primaryLineMap: primaryLineMap,
                secondaryLineMap: secondaryLineMap,
                themeName: themeName
            )
            guard key != currentRenderKey else { return }
            currentRenderKey = key
            let textChanged = currentText != text
            if textChanged {
                lineStartsCache = nil
                lastEmittedTopLine = nil
                findKey = nil // stale match ranges; applyFind recomputes after this render
            }
            currentText = text
            rowKindsStore = rowKinds
            renderID += 1
            let renderID = renderID
            let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            let fontChanged = currentFontSize != fontSize
            currentFontSize = fontSize

            if let scrollView = textView?.enclosingScrollView, let container = containerView {
                // Counted from the incoming text (the text view still holds the previous
                // one here); only used for 1..n numbering when there are no line maps.
                var totalRows = 1
                for byte in text.utf8 where byte == 0x0A { totalRows += 1 }
                let thickness = container.setGutter(
                    fontSize: fontSize,
                    rowKinds: rowKinds,
                    primaryLines: primaryLineMap,
                    secondaryLines: secondaryLineMap,
                    totalRows: totalRows
                )
                // Reserve the gutter's width in the insets and keep the content visually
                // pinned when the width changes (digit growth, font size).
                if abs(scrollView.contentInsets.left - thickness) > 0.5 {
                    let delta = thickness - scrollView.contentInsets.left
                    var insets = scrollView.contentInsets
                    insets.left = thickness
                    scrollView.contentInsets = insets
                    let clipView = scrollView.contentView
                    var origin = clipView.bounds.origin
                    origin.x -= delta
                    let constrained = clipView.constrainBoundsRect(
                        NSRect(origin: origin, size: clipView.bounds.size)
                    ).origin
                    clipView.setBoundsOrigin(constrained)
                    scrollView.reflectScrolledClipView(clipView)
                }
            }

            if textChanged {
                pendingInitialXReset = true
                // Fast first paint: bare text only, so even a huge combined document appears
                // instantly. Line styling (and highlighting) lands asynchronously as an
                // attributes-only pass, which cannot disturb layout or scroll position.
                apply(
                    NSAttributedString(string: text, attributes: [
                        .font: font,
                        .foregroundColor: NSColor.textColor,
                    ]),
                    focusedLineRange: focusedLineRange,
                    resetScroll: resetScroll
                )
            } else {
                if fontChanged, let storage = textView?.textStorage, storage.length > 0 {
                    // Instant resize: swap the font over the whole storage right now (syntax
                    // colors are separate attributes and survive). The async pass re-applies
                    // full styling at the new size when it lands.
                    storage.addAttribute(.font, value: font, range: NSRange(location: 0, length: storage.length))
                }
                if let focusedLineRange {
                    // Same text, new focus (e.g. a comment was clicked): just move; the
                    // async pass will restyle in place.
                    scrollToLine(focusedLineRange.lowerBound)
                }
            }

            renderQueue.async { [weak self] in
                guard let self else { return }
                // Skip stale jobs before the heavy work: rapid font-size changes queue one
                // job per step on this serial queue, and only the newest can ever be applied.
                let isCurrent = DispatchQueue.main.sync { self.renderID == renderID }
                guard isCurrent else { return }
                // Sources highlight as one language; side-by-side diffs highlight per file
                // section. Oversized inputs stay plain — the row styling carries the diff.
                var highlighted: NSAttributedString?
                if contentKind == .source, text.utf8.count <= Self.maxHighlightSize {
                    highlighted = self.highlightedString(
                        text,
                        language: language,
                        font: font,
                        fontSize: fontSize,
                        themeName: themeName
                    )
                } else if contentKind == .diff, !highlightSpans.isEmpty {
                    highlighted = self.spanHighlightedString(
                        text,
                        spans: highlightSpans,
                        primaryLineMap: primaryLineMap,
                        secondaryLineMap: secondaryLineMap,
                        font: font,
                        fontSize: fontSize,
                        themeName: themeName
                    )
                }
                let base = highlighted ?? NSAttributedString(string: text, attributes: [
                    .font: font,
                    .foregroundColor: NSColor.textColor,
                ])
                let rendered = Self.withContentStyling(
                    base,
                    contentKind: contentKind,
                    focusedLineRange: focusedLineRange,
                    commentedLineRanges: commentedLineRanges,
                    rowKinds: rowKinds,
                    appearance: appearance,
                    baseFont: font
                )

                DispatchQueue.main.async { [weak self] in
                    guard let self, self.renderID == renderID else { return }
                    self.apply(rendered, focusedLineRange: nil, resetScroll: false)
                }
            }
        }

        /// Highlights each span and stitches the result back together, preserving the text
        /// byte-for-byte (row alignment depends on exact text).
        ///
        /// Spans that carry complete file contents are colored per row from the *whole file's*
        /// highlighting, located via the line maps: diff fragments start mid-construct and
        /// mislead lexers (a hunk opening inside a string or comment poisons everything after
        /// it), whole files never do. Any row whose text doesn't match its file line — and
        /// spans without file texts — fall back to highlighting the displayed chunk directly.
        private func spanHighlightedString(
            _ text: String,
            spans: [CodeHighlightSpan],
            primaryLineMap: [Int?],
            secondaryLineMap: [Int?],
            font: NSFont,
            fontSize: CGFloat,
            themeName: String
        ) -> NSAttributedString? {
            let highlighter = self.highlighter ?? Highlighter()
            guard let highlighter else { return nil }
            self.highlighter = highlighter
            highlighter.ignoreIllegals = true
            highlighter.setTheme(themeName, withFont: font.fontName, ofSize: fontSize)

            let plainAttributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.textColor,
            ]

            /// Whole-file highlight split into one attributed string per line.
            func attributedFileLines(_ fileText: String?, language: String) -> [NSAttributedString]? {
                guard let fileText, fileText.utf8.count <= Self.maxHighlightSize,
                      let styled = highlighter.highlight(fileText, as: language),
                      styled.string == fileText else {
                    return nil
                }
                let mutable = NSMutableAttributedString(attributedString: styled)
                mutable.addAttribute(.font, value: font, range: NSRange(location: 0, length: mutable.length))
                var result: [NSAttributedString] = []
                let nsString = mutable.string as NSString
                var location = 0
                while location < nsString.length {
                    let lineRange = nsString.lineRange(for: NSRange(location: location, length: 0))
                    var contentRange = lineRange
                    while contentRange.length > 0 {
                        let last = nsString.character(at: contentRange.location + contentRange.length - 1)
                        if last == 0x0A || last == 0x0D { contentRange.length -= 1 } else { break }
                    }
                    result.append(mutable.attributedSubstring(from: contentRange))
                    location = NSMaxRange(lineRange)
                }
                return result
            }

            func chunkHighlighted(_ chunk: String, language: String?) -> NSAttributedString {
                if let language, chunk.utf8.count <= Self.maxHighlightSize,
                   let styled = highlighter.highlight(chunk, as: language),
                   styled.string == chunk {
                    let mutable = NSMutableAttributedString(attributedString: styled)
                    mutable.addAttribute(.font, value: font, range: NSRange(location: 0, length: mutable.length))
                    return mutable
                }
                return NSAttributedString(string: chunk, attributes: plainAttributes)
            }

            let lines = text.components(separatedBy: "\n")

            // Cover 1...lines.count with alternating plain gaps and spans.
            var segments: [(range: ClosedRange<Int>, span: CodeHighlightSpan?)] = []
            var cursor = 1
            for span in spans.sorted(by: { $0.startLine < $1.startLine }) {
                let start = max(span.startLine, cursor)
                let end = min(span.endLine, lines.count)
                guard start <= end else { continue }
                if cursor < start {
                    segments.append((cursor...(start - 1), nil))
                }
                segments.append((start...end, span))
                cursor = end + 1
            }
            if cursor <= lines.count {
                segments.append((cursor...lines.count, nil))
            }

            let result = NSMutableAttributedString()
            let newline = NSAttributedString(string: "\n", attributes: plainAttributes)
            for (index, segment) in segments.enumerated() {
                defer {
                    if index < segments.count - 1 {
                        result.append(newline)
                    }
                }
                guard let span = segment.span else {
                    let gap = lines[(segment.range.lowerBound - 1)...(segment.range.upperBound - 1)]
                        .joined(separator: "\n")
                    result.append(NSAttributedString(string: gap, attributes: plainAttributes))
                    continue
                }

                let primaryLines = attributedFileLines(span.primaryText, language: span.language)
                let secondaryLines = attributedFileLines(span.secondaryText, language: span.language)

                guard primaryLines != nil || secondaryLines != nil else {
                    let chunk = lines[(segment.range.lowerBound - 1)...(segment.range.upperBound - 1)]
                        .joined(separator: "\n")
                    result.append(chunkHighlighted(chunk, language: span.language))
                    continue
                }

                // Line-mapped path: color each row from its real file line.
                for (rowOffset, row) in segment.range.enumerated() {
                    if rowOffset > 0 { result.append(newline) }
                    let displayed = lines[row - 1]
                    if displayed.isEmpty {
                        result.append(NSAttributedString(string: "", attributes: plainAttributes))
                        continue
                    }
                    func lookup(_ fileLines: [NSAttributedString]?, _ map: [Int?]) -> NSAttributedString? {
                        guard let fileLines, row <= map.count, let fileLine = map[row - 1],
                              fileLine >= 1, fileLine <= fileLines.count,
                              fileLines[fileLine - 1].string == displayed else { return nil }
                        return fileLines[fileLine - 1]
                    }
                    if let match = lookup(primaryLines, primaryLineMap) ?? lookup(secondaryLines, secondaryLineMap) {
                        result.append(match)
                    } else {
                        result.append(chunkHighlighted(displayed, language: span.language))
                    }
                }
            }

            return result.string == text ? result : nil
        }

        private func highlightedString(
            _ text: String,
            language: String?,
            font: NSFont,
            fontSize: CGFloat,
            themeName: String
        ) -> NSAttributedString? {
            let highlighter = self.highlighter ?? Highlighter()
            guard let highlighter else { return nil }
            self.highlighter = highlighter
            highlighter.ignoreIllegals = true
            highlighter.setTheme(themeName, withFont: font.fontName, ofSize: fontSize)

            let highlighted = highlighter.highlight(text, as: language)
                ?? highlighter.highlight(text)
            guard let highlighted else { return nil }

            let result = NSMutableAttributedString(attributedString: highlighted)
            result.addAttribute(.font, value: font, range: NSRange(location: 0, length: result.length))
            return result
        }

        private func apply(
            _ attributedString: NSAttributedString,
            focusedLineRange: ClosedRange<Int>?,
            resetScroll: Bool
        ) {
            guard let textView, let storage = textView.textStorage else { return }
            if storage.length > 0, storage.string == attributedString.string {
                // Restyle in place. Replacing the storage collapses layout for a moment,
                // which clamps (snaps) the scroll position on big documents — transferring
                // attributes leaves geometry untouched, so the viewport cannot move.
                storage.beginEditing()
                attributedString.enumerateAttributes(
                    in: NSRange(location: 0, length: attributedString.length)
                ) { attributes, range, _ in
                    storage.setAttributes(attributes, range: range)
                }
                storage.endEditing()
            } else {
                storage.setAttributedString(attributedString)
            }
            if let focusedLineRange {
                scrollToLine(focusedLineRange.lowerBound)
            } else if resetScroll {
                scroll(toDocumentY: 0)
            }
            emitSelection()
            scheduleViewportCallbacks()
        }

        // MARK: - Line geometry & scrolling

        /// 0-based character offsets of every line start, cached per text. Lets line-number
        /// lookups (selection, scroll-spy, jumps) binary-search instead of rescanning the
        /// whole string on every scroll tick.
        private func lineStarts() -> [Int] {
            if let lineStartsCache { return lineStartsCache }
            let nsString = (textView?.string ?? "") as NSString
            var starts: [Int] = [0]
            var location = 0
            while location < nsString.length {
                let lineRange = nsString.lineRange(for: NSRange(location: location, length: 0))
                location = NSMaxRange(lineRange)
                if location < nsString.length {
                    starts.append(location)
                }
            }
            lineStartsCache = starts
            return starts
        }

        private func lineNumber(at location: Int) -> Int {
            let starts = lineStarts()
            var low = 0
            var high = starts.count - 1
            while low < high {
                let mid = (low + high + 1) / 2
                if starts[mid] <= location {
                    low = mid
                } else {
                    high = mid - 1
                }
            }
            return low + 1
        }

        func handleScrollRequest(_ request: CodeScrollRequest?) {
            guard let request, request.id != handledScrollRequestID else { return }
            handledScrollRequestID = request.id
            scrollLineToTop(request.line)
        }

        // MARK: - Click routing

        /// ⌘-click: report (line, column, on-screen anchor) upward. Returns whether the
        /// click was consumed.
        func handleCommandClick(at insertionIndex: Int) -> Bool {
            guard let onCommandClick, let textView else { return false }
            let length = (textView.string as NSString).length
            guard length > 0 else { return false }
            let index = min(max(insertionIndex, 0), length - 1)
            let starts = lineStarts()
            let line = lineNumber(at: index)
            onCommandClick(line, index - starts[line - 1] + 1, anchorRect(forCharacterAt: index))
            return true
        }

        /// The clicked character's rect in the container's (top-left) coordinate space, so
        /// SwiftUI overlays can anchor next to the symbol. Falls back to zero when layout
        /// isn't available — the overlay then clamps to the top-left corner.
        private func anchorRect(forCharacterAt index: Int) -> CGRect {
            guard
                let textView,
                let containerView,
                let layoutManager = textView.layoutManager,
                let textContainer = textView.textContainer
            else {
                return .zero
            }
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: index)
            var rect = layoutManager.boundingRect(
                forGlyphRange: NSRange(location: glyphIndex, length: 1),
                in: textContainer
            )
            rect.origin.x += textView.textContainerOrigin.x
            rect.origin.y += textView.textContainerOrigin.y
            return textView.convert(rect, to: containerView)
        }

        /// Plain click on a combined-diff file header row toggles its collapse state (the
        /// header controls cover these rows on the right pane; this also serves the left).
        func handleHeaderClick(at insertionIndex: Int) -> Bool {
            guard let onHeaderLineToggle, contentKind == .diff, let textView else { return false }
            let nsString = textView.string as NSString
            guard nsString.length > 0 else { return false }
            let index = min(max(insertionIndex, 0), nsString.length - 1)
            let line = lineNumber(at: index)
            if !rowKindsStore.isEmpty {
                guard line <= rowKindsStore.count, rowKindsStore[line - 1] == .fileHeader else { return false }
            } else {
                let lineRange = nsString.lineRange(for: NSRange(location: index, length: 0))
                guard ChangeSetDocument.isHeaderLine(nsString.substring(with: lineRange)) else { return false }
            }
            onHeaderLineToggle(line)
            return true
        }

        /// Positions `line` directly below the floating header (used for file jumps).
        private func scrollLineToTop(_ line: Int) {
            guard let textView, let layoutManager = textView.layoutManager else { return }
            guard line > 1 else {
                scroll(toDocumentY: 0)
                return
            }
            let starts = lineStarts()
            guard line <= starts.count else { return }
            let characterIndex = starts[line - 1]
            let length = (textView.string as NSString).length
            layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: min(characterIndex + 1, length)))
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: characterIndex)
            let rect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            var targetY = rect.minY + textView.textContainerOrigin.y - 6
            // Non-header targets leave room for the sticky section bar overlaying the top.
            if line - 1 < rowKindsStore.count, rowKindsStore[line - 1] != .fileHeader,
               let font = textView.font {
                let rowHeight = layoutManager.defaultLineHeight(for: font)
                targetY -= rowHeight * CGFloat(SideBySideDocument.headerRowCount)
            }
            scroll(toDocumentY: targetY)
        }

        /// Scrolls so document coordinate `y` sits just below the floating header. Goes through
        /// the clip view (constrained) so the scroll-view content insets are respected — a plain
        /// `scroll(.zero)` parks the first lines *behind* the glass header.
        private func scroll(toDocumentY y: CGFloat) {
            guard let textView, let scrollView = textView.enclosingScrollView else { return }
            let clipView = scrollView.contentView
            let target = NSRect(
                // x rests at -left inset: fully scrolled left, clear of the number gutter.
                origin: NSPoint(x: -scrollView.contentInsets.left, y: y - scrollView.contentInsets.top),
                size: clipView.bounds.size
            )
            clipView.setBoundsOrigin(clipView.constrainBoundsRect(target).origin)
            scrollView.reflectScrolledClipView(clipView)
        }

        /// Brings `line` into view with generous context (used for definition/comment focus).
        private func scrollToLine(_ line: Int) {
            guard
                let textView,
                let layoutManager = textView.layoutManager
            else {
                return
            }
            let starts = lineStarts()
            guard line >= 1, line <= starts.count else { return }
            let characterIndex = starts[line - 1]
            let length = (textView.string as NSString).length
            layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: min(characterIndex + 1, length)))
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: characterIndex)
            var rect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            rect.origin.x += textView.textContainerOrigin.x
            rect.origin.y += textView.textContainerOrigin.y
            rect = rect.insetBy(dx: -16, dy: -90)
            textView.scrollToVisible(rect)
        }

        private func emitSelection() {
            onSelectionChange(currentSelectionContext())
            updateCommentButton()
        }

        private func currentSelectionContext() -> CodeSelectionContext? {
            guard let textView else { return nil }
            let nsString = textView.string as NSString
            guard nsString.length > 0 else { return nil }

            let selectedRange = textView.selectedRange()
            guard selectedRange.location != NSNotFound else { return nil }
            guard selectedRange.length > 0 else { return nil }

            let maxLocation = max(nsString.length - 1, 0)
            let startLocation = min(selectedRange.location, maxLocation)
            let endLocation = min(NSMaxRange(selectedRange) - 1, maxLocation)

            let startLineRange = nsString.lineRange(for: NSRange(location: startLocation, length: 0))
            let endLineRange = nsString.lineRange(for: NSRange(location: endLocation, length: 0))
            let lineRange = NSUnionRange(startLineRange, endLineRange)
            guard lineRange.location != NSNotFound, lineRange.length > 0 else { return nil }

            let text = nsString.substring(with: lineRange)
                .trimmingCharacters(in: .newlines)
            guard !text.isEmpty else { return nil }

            return CodeSelectionContext(
                fileURL: fileURL,
                contentKind: contentKind,
                startLine: lineNumber(at: lineRange.location),
                endLine: lineNumber(at: max(NSMaxRange(lineRange) - 1, lineRange.location)),
                text: text
            )
        }

        private func currentSelectionRect() -> NSRect? {
            guard
                let textView,
                let containerView,
                let layoutManager = textView.layoutManager,
                let textContainer = textView.textContainer
            else {
                return nil
            }

            let selectedRange = textView.selectedRange()
            guard selectedRange.location != NSNotFound, selectedRange.length > 0 else { return nil }

            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: selectedRange,
                actualCharacterRange: nil
            )
            guard glyphRange.length > 0 else { return nil }

            var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            rect.origin.x += textView.textContainerOrigin.x
            rect.origin.y += textView.textContainerOrigin.y
            rect = textView.convert(rect, to: containerView)
            guard rect.intersects(containerView.bounds.insetBy(dx: -60, dy: -60)) else { return nil }
            return rect
        }

        private static func withContentStyling(
            _ attributedString: NSAttributedString,
            contentKind: CodeContentKind,
            focusedLineRange: ClosedRange<Int>?,
            commentedLineRanges: [ClosedRange<Int>],
            rowKinds: [SideBySideDocument.RowKind],
            appearance: NSAppearance,
            baseFont: NSFont
        ) -> NSAttributedString {
            let result = NSMutableAttributedString(attributedString: attributedString)

            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            if contentKind == .diff {
                // Same point size as the body on purpose: the bare-text first paint and the
                // styled pass must produce identical layout, or scroll targets would drift.
                let headerAttributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .bold),
                    .foregroundColor: NSColor.labelColor,
                    .backgroundColor: NSColor.secondaryLabelColor.withAlphaComponent(isDark ? 0.14 : 0.08),
                ]
                let nsString = result.string as NSString
                var location = 0
                var row = 0

                while location < nsString.length {
                    let lineRange = nsString.lineRange(for: NSRange(location: location, length: 0))
                    row += 1
                    if row <= rowKinds.count {
                        applyRowStyle(
                            rowKinds[row - 1],
                            to: result,
                            range: lineRange,
                            headerAttributes: headerAttributes,
                            isDark: isDark
                        )
                    } else if rowKinds.isEmpty {
                        // Unified fallback: style by the patch's +/- prefixes.
                        let line = nsString.substring(with: lineRange)
                        if ChangeSetDocument.isHeaderLine(line) {
                            result.addAttributes(headerAttributes, range: lineRange)
                        } else {
                            applyDiffStyle(to: result, line: line, range: lineRange, isDark: isDark)
                        }
                    }
                    location = NSMaxRange(lineRange)
                }
            }

            // Commented code gets a solid teal band (plus the marker bar the container draws
            // at the left edge); syntax colors stay readable underneath.
            for range in commentedLineRanges {
                if let characterRange = characterRange(forLineRange: range, in: result.string as NSString) {
                    result.addAttribute(
                        .backgroundColor,
                        value: NSColor.systemTeal.withAlphaComponent(isDark ? 0.26 : 0.17),
                        range: characterRange
                    )
                }
            }

            // The focus flash (jumping to a comment) outranks the comment band.
            if let focusedLineRange,
               let characterRange = characterRange(forLineRange: focusedLineRange, in: result.string as NSString) {
                result.addAttribute(
                    .backgroundColor,
                    value: NSColor.systemYellow.withAlphaComponent(isDark ? 0.24 : 0.20),
                    range: characterRange
                )
            }

            return result
        }

        private static func characterRange(forLineRange lineRange: ClosedRange<Int>, in string: NSString) -> NSRange? {
            guard string.length > 0 else { return nil }
            let lower = max(lineRange.lowerBound, 1)
            let upper = max(lineRange.upperBound, lower)
            var line = 1
            var location = 0
            var start: Int?
            var end: Int?

            while location < string.length {
                let currentRange = string.lineRange(for: NSRange(location: location, length: 0))
                if line == lower {
                    start = currentRange.location
                }
                if line == upper {
                    end = NSMaxRange(currentRange)
                    break
                }
                location = NSMaxRange(currentRange)
                line += 1
            }

            guard let start else { return nil }
            return NSRange(location: start, length: max((end ?? string.length) - start, 0))
        }

        /// Side-by-side row backgrounds. Syntax colors from the highlighter stay; only the
        /// background communicates added/removed/filler.
        private static func applyRowStyle(
            _ kind: SideBySideDocument.RowKind,
            to result: NSMutableAttributedString,
            range: NSRange,
            headerAttributes: [NSAttributedString.Key: Any],
            isDark: Bool
        ) {
            switch kind {
            case .fileHeader:
                // Empty rows behind the real header control — just a quiet band.
                result.addAttribute(
                    .backgroundColor,
                    value: NSColor.secondaryLabelColor.withAlphaComponent(isDark ? 0.05 : 0.03),
                    range: range
                )
            case .hunkBreak:
                result.addAttributes([
                    .foregroundColor: NSColor.tertiaryLabelColor,
                    .backgroundColor: NSColor.secondaryLabelColor.withAlphaComponent(isDark ? 0.06 : 0.04),
                ], range: range)
            case .addition:
                result.addAttribute(
                    .backgroundColor,
                    value: NSColor.systemGreen.withAlphaComponent(isDark ? 0.15 : 0.10),
                    range: range
                )
            case .deletion:
                result.addAttribute(
                    .backgroundColor,
                    value: NSColor.systemRed.withAlphaComponent(isDark ? 0.16 : 0.10),
                    range: range
                )
            case .filler:
                result.addAttribute(
                    .backgroundColor,
                    value: NSColor.secondaryLabelColor.withAlphaComponent(isDark ? 0.07 : 0.045),
                    range: range
                )
            case .placeholder:
                result.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)
            case .context, .blank:
                break
            }
        }

        private static func applyDiffStyle(
            to result: NSMutableAttributedString,
            line: String,
            range: NSRange,
            isDark: Bool
        ) {
            let style = DiffLineStyle(line: line, isDark: isDark)
            result.addAttributes(style.attributes, range: range)
        }

        private struct DiffLineStyle {
            let attributes: [NSAttributedString.Key: Any]

            init(line: String, isDark: Bool) {
                if line.hasPrefix("+"), !line.hasPrefix("+++") {
                    attributes = [
                        .foregroundColor: NSColor.systemGreen,
                        .backgroundColor: NSColor.systemGreen.withAlphaComponent(isDark ? 0.18 : 0.12),
                    ]
                } else if line.hasPrefix("-"), !line.hasPrefix("---") {
                    attributes = [
                        .foregroundColor: NSColor.systemRed,
                        .backgroundColor: NSColor.systemRed.withAlphaComponent(isDark ? 0.20 : 0.12),
                    ]
                } else if line.hasPrefix("@@") {
                    attributes = [
                        .foregroundColor: NSColor.systemBlue,
                        .backgroundColor: NSColor.systemBlue.withAlphaComponent(isDark ? 0.18 : 0.10),
                    ]
                } else if Self.isMetadata(line) {
                    attributes = [
                        .foregroundColor: NSColor.secondaryLabelColor,
                        .backgroundColor: NSColor.secondaryLabelColor.withAlphaComponent(isDark ? 0.10 : 0.06),
                    ]
                } else {
                    attributes = [:]
                }
            }

            private static func isMetadata(_ line: String) -> Bool {
                line.hasPrefix("diff --git")
                    || line.hasPrefix("index ")
                    || line.hasPrefix("new file mode")
                    || line.hasPrefix("deleted file mode")
                    || line.hasPrefix("old mode")
                    || line.hasPrefix("new mode")
                    || line.hasPrefix("similarity index")
                    || line.hasPrefix("dissimilarity index")
                    || line.hasPrefix("rename from")
                    || line.hasPrefix("rename to")
                    || line.hasPrefix("---")
                    || line.hasPrefix("+++")
                    || line.hasPrefix("Binary files")
            }
        }

        private static func themeName(for appearance: NSAppearance) -> String {
            let bestMatch = appearance.bestMatch(from: [.darkAqua, .aqua])
            return bestMatch == .darkAqua ? "github-dark" : "github"
        }
    }

    private struct RenderKey: Equatable {
        let text: String
        let language: String?
        let contentKind: CodeContentKind
        let fontSize: CGFloat
        let focusedLineRange: ClosedRange<Int>?
        let commentedLineRanges: [ClosedRange<Int>]
        let rowKinds: [SideBySideDocument.RowKind]
        let highlightSpans: [CodeHighlightSpan]
        let primaryLineMap: [Int?]
        let secondaryLineMap: [Int?]
        let themeName: String
    }
}

/// NSTextView that routes ⌘-clicks (go to definition) and plain clicks on file-header lines
/// (collapse toggle) to closures before falling back to normal selection behavior.
final class ClickRoutingTextView: NSTextView {
    /// Return true to consume the click.
    var onCommandClick: ((Int) -> Bool)?
    var onPlainClick: ((Int) -> Bool)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        if event.modifierFlags.contains(.command) {
            if onCommandClick?(index) == true { return }
        } else if event.clickCount == 1, onPlainClick?(index) == true {
            return
        }
        super.mouseDown(with: event)
    }
}

/// Hosts the scroll view, the floating "add comment" button that trails the selection, and
/// the real section-header controls drawn over each file's header rows.
final class SelectionAskContainerView: NSView {
    /// Top-down coordinates so rects reported to SwiftUI overlays need no conversion.
    override var isFlipped: Bool { true }

    private let scrollViewSlot = NSView()
    private let commentButton = NSButton()
    private var selectionRect: NSRect?
    private let buttonSize: CGFloat = 30

    private weak var installedScrollView: NSScrollView?
    private var headerModels: [DiffSectionHeaderModel] = []
    private var headerRowHeight: CGFloat = 16
    private var headerRowCount = 2
    private var headerTopInset: CGFloat = 8
    private var headerToggle: ((String) -> Void)?
    private var headerOpen: ((String) -> Void)?
    private var headerViews: [String: NSHostingView<DiffSectionHeaderBar>] = [:]

    private let gutterView = LineNumberGutterView()

    private var commentMarkerRanges: [ClosedRange<Int>] = []
    private var commentMarkerRowHeight: CGFloat = 16
    private var commentMarkerTopInset: CGFloat = 8
    private var commentMarkerTap: ((ClosedRange<Int>) -> Void)?
    private var commentMarkerViews: [CommentMarkerBarView] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    func install(scrollView: NSScrollView, target: AnyObject, action: Selector) {
        installedScrollView = scrollView
        gutterView.scrollView = scrollView
        scrollViewSlot.subviews.forEach { $0.removeFromSuperview() }
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollViewSlot.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: scrollViewSlot.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: scrollViewSlot.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: scrollViewSlot.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: scrollViewSlot.bottomAnchor),
        ])

        commentButton.target = target
        commentButton.action = action
    }

    func updateCommentButton(selectionRect: NSRect?, isVisible: Bool) {
        self.selectionRect = selectionRect
        commentButton.isHidden = !isVisible || selectionRect == nil
        needsLayout = true
    }

    override func layout() {
        super.layout()
        layoutGutter()
        positionCommentButton()
        layoutSectionHeaders()
        layoutCommentMarkers()
    }

    // MARK: - Line-number gutter

    /// Configures the gutter and returns its width so the caller can reserve content insets.
    func setGutter(
        fontSize: CGFloat,
        rowKinds: [SideBySideDocument.RowKind],
        primaryLines: [Int?],
        secondaryLines: [Int?],
        totalRows: Int
    ) -> CGFloat {
        gutterView.configure(
            fontSize: fontSize,
            rowKinds: rowKinds,
            primaryLines: primaryLines,
            secondaryLines: secondaryLines,
            totalRows: totalRows
        )
        layoutGutter()
        return gutterView.thickness
    }

    private func layoutGutter() {
        gutterView.frame = NSRect(x: 0, y: 0, width: gutterView.thickness, height: bounds.height)
    }

    /// Scroll moved: the gutter's rows shift, so it redraws (cheap, visible rows only).
    func refreshGutter() {
        gutterView.needsDisplay = true
    }

    // MARK: - Comment marker bars

    func setCommentMarkers(
        _ ranges: [ClosedRange<Int>],
        rowHeight: CGFloat,
        contentTopInset: CGFloat,
        onTap: ((ClosedRange<Int>) -> Void)?
    ) {
        commentMarkerRowHeight = max(rowHeight, 1)
        commentMarkerTopInset = contentTopInset
        commentMarkerTap = onTap
        guard ranges != commentMarkerRanges else { return }
        commentMarkerRanges = ranges
        layoutCommentMarkers()
    }

    /// Positions one saturated teal bar along the left edge of each commented row range —
    /// pure arithmetic (fixed row height), cheap enough for every scroll tick.
    func layoutCommentMarkers() {
        while commentMarkerViews.count > commentMarkerRanges.count {
            commentMarkerViews.removeLast().removeFromSuperview()
        }
        while commentMarkerViews.count < commentMarkerRanges.count {
            let bar = CommentMarkerBarView()
            addSubview(bar, positioned: .below, relativeTo: commentButton)
            commentMarkerViews.append(bar)
        }
        guard !commentMarkerRanges.isEmpty, let scrollView = installedScrollView else { return }

        let clipOriginY = scrollView.contentView.bounds.origin.y
        for (index, range) in commentMarkerRanges.enumerated() {
            let bar = commentMarkerViews[index]
            let documentY = commentMarkerTopInset + CGFloat(range.lowerBound - 1) * commentMarkerRowHeight
            let y = documentY - clipOriginY
            let height = CGFloat(range.count) * commentMarkerRowHeight
            bar.isHidden = y + height < 0 || y > bounds.height
            bar.frame = NSRect(x: 0, y: y + 1, width: 8, height: max(height - 2, 2))
            bar.onClick = { [weak self] in self?.commentMarkerTap?(range) }
        }
    }

    // MARK: - Section header controls

    func setSectionHeaders(
        _ models: [DiffSectionHeaderModel],
        rowHeight: CGFloat,
        headerRowCount: Int,
        contentTopInset: CGFloat,
        onToggle: ((String) -> Void)?,
        onOpen: ((String) -> Void)?
    ) {
        headerToggle = onToggle
        headerOpen = onOpen
        headerRowHeight = max(rowHeight, 1)
        self.headerRowCount = headerRowCount
        headerTopInset = contentTopInset
        guard models != headerModels else { return }
        headerModels = models
        let validPaths = Set(models.map(\.path))
        for (path, view) in headerViews where !validPaths.contains(path) {
            view.removeFromSuperview()
            headerViews.removeValue(forKey: path)
        }
        layoutSectionHeaders()
    }

    /// Positions header controls with pure arithmetic (fixed row height), creating views only
    /// for headers near the viewport. Cheap enough to run on every scroll tick.
    func layoutSectionHeaders() {
        guard !headerModels.isEmpty, let scrollView = installedScrollView else {
            headerViews.values.forEach { $0.removeFromSuperview() }
            headerViews.removeAll()
            return
        }
        let clipOriginY = scrollView.contentView.bounds.origin.y
        let barHeight = headerRowHeight * CGFloat(headerRowCount) - 6
        let width = max(bounds.width - 16, 100)
        let visibleMargin: CGFloat = 300
        let stickyTop: CGFloat = 6

        for (index, model) in headerModels.enumerated() {
            // Document y of the header block → container y (flipped, so plain subtraction).
            let documentY = headerTopInset + CGFloat(model.row - 1) * headerRowHeight
            let naturalY = documentY - clipOriginY + 3

            // Sticky: the current section's bar pins below the top edge while its content
            // scrolls, and the next section's bar pushes it out as it arrives.
            var y = max(naturalY, stickyTop)
            if index + 1 < headerModels.count {
                let nextDocumentY = headerTopInset + CGFloat(headerModels[index + 1].row - 1) * headerRowHeight
                let nextNaturalY = nextDocumentY - clipOriginY + 3
                y = min(y, nextNaturalY - barHeight - 4)
            }

            let isNearViewport = y > -barHeight - visibleMargin
                && y < bounds.height + visibleMargin

            if isNearViewport {
                let bar = DiffSectionHeaderBar(
                    model: model,
                    onToggle: { [weak self] in self?.headerToggle?(model.path) },
                    onOpen: { [weak self] in self?.headerOpen?(model.path) }
                )
                let view: NSHostingView<DiffSectionHeaderBar>
                if let existing = headerViews[model.path] {
                    existing.rootView = bar
                    view = existing
                } else {
                    let created = NSHostingView(rootView: bar)
                    headerViews[model.path] = created
                    addSubview(created, positioned: .below, relativeTo: commentButton)
                    view = created
                }
                view.frame = NSRect(x: 8, y: y, width: width, height: barHeight)
            } else if let existing = headerViews[model.path] {
                existing.removeFromSuperview()
                headerViews.removeValue(forKey: model.path)
            }
        }
    }

    private func configure() {
        wantsLayer = true
        // Overlay chrome (header bars, comment markers) must never draw outside the pane
        // while scrolled off-screen.
        clipsToBounds = true

        scrollViewSlot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollViewSlot)
        NSLayoutConstraint.activate([
            scrollViewSlot.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollViewSlot.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollViewSlot.topAnchor.constraint(equalTo: topAnchor),
            scrollViewSlot.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        addSubview(gutterView, positioned: .above, relativeTo: scrollViewSlot)

        commentButton.isHidden = true
        commentButton.isBordered = false
        commentButton.bezelStyle = .circular
        commentButton.imagePosition = .imageOnly
        commentButton.image = NSImage(
            systemSymbolName: "plus.bubble",
            accessibilityDescription: "Add comment on selection"
        )
        commentButton.contentTintColor = .controlAccentColor
        commentButton.toolTip = "Add comment on selection"
        commentButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        commentButton.wantsLayer = true
        commentButton.layer?.cornerRadius = buttonSize / 2
        commentButton.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.92).cgColor
        commentButton.layer?.shadowColor = NSColor.black.cgColor
        commentButton.layer?.shadowOpacity = 0.18
        commentButton.layer?.shadowRadius = 8
        commentButton.layer?.shadowOffset = NSSize(width: 0, height: -1)
        commentButton.setAccessibilityIdentifier("add-comment-button")
        addSubview(commentButton)
    }

    private func positionCommentButton() {
        guard let selectionRect, !commentButton.isHidden else { return }
        let margin: CGFloat = 10
        let x = min(max(selectionRect.maxX + 8, margin), max(bounds.maxX - buttonSize - margin, margin))
        let y = min(
            max(selectionRect.midY - buttonSize / 2, margin),
            max(bounds.maxY - buttonSize - margin, margin)
        )
        commentButton.frame = NSRect(x: x, y: y, width: buttonSize, height: buttonSize)
    }

}

/// The left-edge indicator bar marking commented rows. It lives entirely in the text
/// container's left padding (glyphs start further right), so it can be a real click target —
/// click to select the comment — without costing any text selection. Draw-based so it adapts
/// to light/dark automatically.
final class CommentMarkerBarView: NSView {
    var onClick: (() -> Void)?
    private var isHovering = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
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
        toolTip = "Show this comment"
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func draw(_ dirtyRect: NSRect) {
        // Visual bar within the (slightly wider) hit area; grows a touch on hover.
        let barWidth: CGFloat = isHovering ? 5 : 3.5
        let rect = NSRect(x: 1.5, y: 0, width: barWidth, height: bounds.height)
        let path = NSBezierPath(roundedRect: rect, xRadius: 1.75, yRadius: 1.75)
        NSColor.systemTeal.withAlphaComponent(isHovering ? 1.0 : 0.9).setFill()
        path.fill()
    }
}

/// The clickable header control for one file section — a real control, not styled text.
/// Chevron + name toggle collapse; the trailing arrow opens the file in the Explorer.
struct DiffSectionHeaderBar: View {
    let model: DiffSectionHeaderModel
    let onToggle: () -> Void
    let onOpen: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: model.isCollapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 12)

            Text(model.fileName)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)

            if !model.directory.isEmpty {
                Text(model.directory)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 6)

            if model.isCollapsed {
                Text("\(model.hiddenLineCount) lines hidden")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                if model.additions > 0 {
                    Text("+\(model.additions)")
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.green)
                }
                if model.deletions > 0 {
                    Text("−\(model.deletions)")
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.red)
                }
            }

            if let statusLabel = model.statusLabel {
                Text(statusLabel)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(model.statusTint.color)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(model.statusTint.color.opacity(0.13)))
            }

            // GitHub's "Viewed" checkbox: reviewed == collapsed, one state either control
            // toggles. The checkbox names the *meaning* of collapsing a file.
            Toggle("Reviewed", isOn: Binding(
                get: { model.isCollapsed },
                set: { _ in onToggle() }
            ))
            .toggleStyle(.checkbox)
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .help(model.isCollapsed ? "Mark as not reviewed and expand" : "Mark as reviewed and collapse")
            .accessibilityIdentifier("reviewed-checkbox-\(model.path)")

            Button(action: onOpen) {
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Open file in Explorer")
            .opacity(isHovering ? 1 : 0.35)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(isHovering ? 0.98 : 0.9))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .help(model.isCollapsed ? "Expand \(model.fileName)" : "Collapse \(model.fileName)")
        .accessibilityIdentifier("section-header-\(model.path)")
    }
}

/// State of one find session (per code surface).
struct FindState: Equatable {
    var isActive = false
    var query = ""
    var activeIndex = 0
    var matchCount = 0
}

/// Compact glass find bar: type to highlight, ⏎/⇧⏎ to step through matches, Esc to dismiss.
struct CodeFindBar: View {
    @Binding var state: FindState
    let fontSize: CGFloat
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: max(fontSize - 2, 10)))
                .foregroundStyle(.secondary)

            TextField("Find", text: $state.query)
                .textFieldStyle(.plain)
                .font(.system(size: fontSize))
                .focused($isFieldFocused)
                .onSubmit { state.activeIndex += 1 }
                .accessibilityIdentifier("find-input")

            Text(countLabel)
                .font(.system(size: max(fontSize - 3, 9)))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)

            Button {
                state.activeIndex -= 1
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.return, modifiers: .shift)
            .disabled(state.matchCount == 0)
            .help("Previous match (⇧⏎)")

            Button {
                state.activeIndex += 1
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(state.matchCount == 0)
            .help("Next match (⏎)")

            Button {
                state = FindState()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close (esc)")
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .glassEffect(.regular, in: .rect(cornerRadius: 17))
        .shadow(color: .black.opacity(0.14), radius: 10, y: 3)
        .onAppear {
            DispatchQueue.main.async { isFieldFocused = true }
        }
        .onChange(of: state.query) { _, _ in
            state.activeIndex = 0
        }
        .accessibilityIdentifier("find-bar")
    }

    private var countLabel: String {
        if state.query.isEmpty { return "" }
        guard state.matchCount > 0 else { return "0" }
        let normalized = ((state.activeIndex % state.matchCount) + state.matchCount) % state.matchCount
        return "\(normalized + 1)/\(state.matchCount)"
    }
}

/// Line-number gutter for the code panes, hosted directly in the container (never an
/// `NSRulerView` — scroll-view ruler tiling with custom content insets is ambiguous across
/// configurations). The text content itself stays untouched: the gutter's width is reserved
/// via the scroll view's left content inset, and this opaque view overlays whatever scrolls
/// beneath it, Xcode-style.
///
/// Diff panes show one number column: the row's real file line — new-version numbering, with
/// removed rows falling back to their old-version number (tinted red like the row itself) —
/// plus a `+`/`-` marker for added/removed rows. Views without maps (source files in the
/// Explorer) get plain 1..n numbering. Rows that display no file line — headers, fillers,
/// hunk breaks — draw nothing.
///
/// All positioning is pure arithmetic on a fixed row height, the same assumption the section
/// header controls and comment marker bars already rely on.
final class LineNumberGutterView: NSView {
    weak var scrollView: NSScrollView?

    private var fontSize: CGFloat = FontSizes.default
    private var rowKinds: [SideBySideDocument.RowKind] = []
    private var primaryLines: [Int?] = []
    private var secondaryLines: [Int?] = []
    private var totalRows = 0
    private var charWidth: CGFloat = 7
    private var digits = 3
    private var rowHeight: CGFloat = 16
    private(set) var thickness: CGFloat = 0

    private let leadingPad: CGFloat = 10
    private let trailingPad: CGFloat = 6
    private let markerGap: CGFloat = 4
    private static let metricsLayoutManager = NSLayoutManager()

    override var isFlipped: Bool { true }

    /// Inert surface: clicks on the gutter should neither select hidden text nor beep.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    func configure(
        fontSize: CGFloat,
        rowKinds: [SideBySideDocument.RowKind],
        primaryLines: [Int?],
        secondaryLines: [Int?],
        totalRows: Int
    ) {
        self.fontSize = fontSize
        self.rowKinds = rowKinds
        self.primaryLines = primaryLines
        self.secondaryLines = secondaryLines
        self.totalRows = totalRows

        let rowFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        rowHeight = Self.metricsLayoutManager.defaultLineHeight(for: rowFont)
        charWidth = ceil(("8" as NSString).size(withAttributes: [.font: numberFont]).width)
        let maxShown: Int
        if primaryLines.isEmpty, secondaryLines.isEmpty {
            maxShown = totalRows
        } else {
            maxShown = max(
                primaryLines.compactMap { $0 }.max() ?? 1,
                secondaryLines.compactMap { $0 }.max() ?? 1
            )
        }
        digits = max(3, String(max(maxShown, 1)).count)

        var width = leadingPad + CGFloat(digits) * charWidth + trailingPad
        if !rowKinds.isEmpty {
            width += charWidth + markerGap
        }
        thickness = ceil(width)
        needsDisplay = true
    }

    private var numberFont: NSFont {
        .monospacedSystemFont(ofSize: max(fontSize - 2, 9), weight: .regular)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.withAlphaComponent(0.35).setFill()
        NSRect(x: bounds.maxX - 1, y: dirtyRect.minY, width: 1, height: dirtyRect.height).fill()

        guard rowHeight > 0 else { return }
        let rowCount = rowKinds.isEmpty ? totalRows : rowKinds.count
        guard rowCount > 0 else { return }

        // Rows positioned exactly like the text: container y = inset + row offset − clip y.
        let clipOriginY = scrollView?.contentView.bounds.origin.y ?? 0
        let contentInset: CGFloat = 8 // the text view's textContainerInset height
        let numberBaselineNudge = (rowHeight - numberFont.pointSize) / 2 - 1

        let visibleTop = clipOriginY - contentInset
        let firstRow = max(Int(floor(visibleTop / rowHeight)), 0) + 1
        let lastRow = min(Int(ceil((visibleTop + bounds.height) / rowHeight)) + 1, rowCount)
        guard firstRow <= lastRow else { return }

        let numberAttributes: [NSAttributedString.Key: Any] = [
            .font: numberFont,
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        // Removed rows have no new-version number; they show their old-version one, tinted
        // like the row so the different numbering scheme is legible.
        let oldNumberAttributes: [NSAttributedString.Key: Any] = [
            .font: numberFont,
            .foregroundColor: NSColor.systemRed.withAlphaComponent(0.55),
        ]
        let columnMaxX = leadingPad + CGFloat(digits) * charWidth

        for row in firstRow...lastRow {
            let y = contentInset + CGFloat(row - 1) * rowHeight - clipOriginY + numberBaselineNudge
            let index = row - 1

            var number: Int?
            var isOldNumber = false
            if primaryLines.isEmpty, secondaryLines.isEmpty {
                number = row // plain source: rows are lines
            } else if index < primaryLines.count, let primary = primaryLines[index] {
                number = primary
            } else if index < secondaryLines.count, let secondary = secondaryLines[index] {
                number = secondary
                isOldNumber = true
            }

            if let number {
                draw(
                    number: number,
                    rightEdge: columnMaxX,
                    y: y,
                    attributes: isOldNumber ? oldNumberAttributes : numberAttributes
                )
            }

            if index < rowKinds.count {
                let marker: (String, NSColor)?
                switch rowKinds[index] {
                case .addition:
                    marker = ("+", NSColor.systemGreen)
                case .deletion:
                    marker = ("-", NSColor.systemRed)
                default:
                    marker = nil
                }
                if let (symbol, color) = marker {
                    (symbol as NSString).draw(
                        at: NSPoint(x: columnMaxX + markerGap, y: y),
                        withAttributes: [
                            .font: numberFont,
                            .foregroundColor: color.withAlphaComponent(0.9),
                        ]
                    )
                }
            }
        }
    }

    private func draw(
        number: Int,
        rightEdge: CGFloat,
        y: CGFloat,
        attributes: [NSAttributedString.Key: Any]
    ) {
        let string = String(number) as NSString
        let width = string.size(withAttributes: attributes).width
        string.draw(at: NSPoint(x: rightEdge - width, y: y), withAttributes: attributes)
    }
}
