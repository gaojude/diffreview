import AppKit
import MarginCore
import SwiftUI

/// The reviewed reply as one selectable, read-only text document. Selection is native
/// NSTextView selection — character-granular by construction — reported upward so the ⌘K
/// menu command can turn it into a comment draft. Commented ranges get a teal band down to
/// the exact characters; clicking inside one focuses its card in the pane.
struct ProseTextView: NSViewRepresentable {
    let text: String
    let fontSize: CGFloat
    let comments: [ProseComment]
    let selectedCommentID: UUID?
    /// Bumping the token scrolls the comment's range into view and pulses the selection.
    let focusRequest: (comment: ProseComment, token: Int)?
    var onSelectionChange: (ProseSelection?) -> Void = { _ in }
    /// The selection's bounding rect (in this view's top-left coordinate space) — the
    /// composer anchors under it. Nil when there is no selection.
    var onSelectionRectChange: (CGRect?) -> Void = { _ in }
    var onClickAtOffset: (Int) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.automaticallyAdjustsContentInsets = true

        let textView = ClickReportingTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 28, height: 24)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.delegate = context.coordinator
        textView.onClickAtOffset = { offset in
            context.coordinator.onClickAtOffset?(offset)
        }

        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onSelectionChange = onSelectionChange
        coordinator.onSelectionRectChange = onSelectionRectChange
        coordinator.onClickAtOffset = onClickAtOffset

        guard let textView = coordinator.textView else { return }

        if coordinator.renderedText != text || coordinator.renderedFontSize != fontSize {
            coordinator.renderedText = text
            coordinator.renderedFontSize = fontSize
            textView.textStorage?.setAttributedString(Self.attributedText(text, fontSize: fontSize))
            coordinator.renderedBands = []
            // Deferred: this runs inside a SwiftUI view update, and the callbacks publish
            // session state.
            DispatchQueue.main.async { [weak coordinator] in
                coordinator?.onSelectionChange?(nil)
                coordinator?.onSelectionRectChange?(nil)
            }
        }

        coordinator.applyCommentBands(comments: comments, selectedCommentID: selectedCommentID)

        if let focusRequest, coordinator.handledFocusToken != focusRequest.token {
            coordinator.handledFocusToken = focusRequest.token
            coordinator.reveal(comment: focusRequest.comment)
        }
    }

    /// Plain monospace document — the reply is reviewed as source, like a file, so what
    /// gets quoted is exactly what the agent wrote.
    private static func attributedText(_ text: String, fontSize: CGFloat) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.28
        return NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
                .foregroundColor: NSColor.textColor,
                .paragraphStyle: paragraph,
            ]
        )
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var textView: ClickReportingTextView?
        var renderedText: String?
        var renderedFontSize: CGFloat?
        var renderedBands: [Band] = []
        var handledFocusToken = 0
        var onSelectionChange: ((ProseSelection?) -> Void)?
        var onSelectionRectChange: ((CGRect?) -> Void)?
        var onClickAtOffset: ((Int) -> Void)?
        private var pendingSelectionReport = false

        struct Band: Equatable {
            let range: NSRange
            let emphasized: Bool
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            // Defer one runloop turn: during drags this fires per mouse move, and the rect
            // needs completed layout. Mirrors DiffReview's scroll-spy deferral.
            guard !pendingSelectionReport else { return }
            pendingSelectionReport = true
            DispatchQueue.main.async { [weak self] in
                self?.pendingSelectionReport = false
                self?.reportSelection()
            }
        }

        private func reportSelection() {
            guard let textView else { return }
            let range = textView.selectedRange()
            guard range.length > 0,
                  let selection = ProseGeometry.selection(in: textView.string, utf16Range: range) else {
                onSelectionChange?(nil)
                onSelectionRectChange?(nil)
                return
            }
            onSelectionChange?(selection)
            onSelectionRectChange?(rect(for: NSRange(
                location: selection.startOffset,
                length: selection.endOffset - selection.startOffset
            )))
        }

        /// The range's bounding rect in the scroll view's coordinate space (top-left origin),
        /// so SwiftUI can overlay the composer directly under the selection.
        private func rect(for range: NSRange) -> CGRect? {
            guard let textView,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer,
                  let scrollView = textView.enclosingScrollView else { return nil }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            rect.origin.x += textView.textContainerInset.width
            rect.origin.y += textView.textContainerInset.height
            let inScroll = textView.convert(rect, to: scrollView)
            return inScroll.intersection(scrollView.bounds).isNull ? nil : inScroll
        }

        /// Tints every commented range down to the exact characters; the focused comment
        /// gets a stronger band. Temporary attributes: they never touch the text storage.
        func applyCommentBands(comments: [ProseComment], selectedCommentID: UUID?) {
            guard let textView, let layoutManager = textView.layoutManager else { return }
            let length = (textView.string as NSString).length
            let bands: [Band] = comments.compactMap { comment in
                guard let range = comment.utf16Range(clampedToLength: length) else { return nil }
                return Band(range: range, emphasized: comment.id == selectedCommentID)
            }
            guard bands != renderedBands else { return }

            let fullRange = NSRange(location: 0, length: length)
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: fullRange)
            let isDark = textView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            for band in bands {
                let alpha: CGFloat = band.emphasized ? (isDark ? 0.42 : 0.30) : (isDark ? 0.26 : 0.17)
                layoutManager.addTemporaryAttribute(
                    .backgroundColor,
                    value: NSColor.systemTeal.withAlphaComponent(alpha),
                    forCharacterRange: band.range
                )
            }
            renderedBands = bands
        }

        /// Scrolls a comment's range into view and selects it, so "jump back to the text"
        /// from the pane lands exactly on the quoted characters.
        func reveal(comment: ProseComment) {
            guard let textView else { return }
            let length = (textView.string as NSString).length
            guard let range = comment.utf16Range(clampedToLength: length) else { return }
            textView.scrollRangeToVisible(range)
            textView.setSelectedRange(range)
            textView.window?.makeFirstResponder(textView)
        }
    }
}

/// NSTextView that reports plain clicks (no drag, no selection) with the character offset
/// under the cursor — how clicking a highlighted passage focuses its comment card.
final class ClickReportingTextView: NSTextView {
    var onClickAtOffset: ((Int) -> Void)?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        // After super returns, a click (as opposed to a drag-selection) leaves an empty
        // selection at the click location.
        guard selectedRange().length == 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let adjusted = NSPoint(
            x: point.x - textContainerInset.width,
            y: point.y - textContainerInset.height
        )
        guard let layoutManager, let textContainer else { return }
        let glyphIndex = layoutManager.glyphIndex(for: adjusted, in: textContainer)
        let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        onClickAtOffset?(characterIndex)
    }
}
