import SwiftUI
import AppKit
import MyIDECore
import Highlighter

enum CodeContentKind: Equatable, Sendable {
    case source
    case diff
}

struct CodeSelectionContext: Equatable, Sendable {
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
    @ObservedObject var selectionChat: SelectionChatController
    var onSelectionChange: (CodeSelectionContext?) -> Void = { _ in }
    var onAskSelection: (CodeSelectionContext?) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SelectionAskContainerView {
        let container = SelectionAskContainerView()
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        // Reserve room for the floating glass header; the scroller tracks the inset too.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: topInset, left: 0, bottom: 0, right: 0)

        let textView = NSTextView()
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
        container.install(scrollView: scrollView, target: context.coordinator, action: #selector(Coordinator.askSelection))
        context.coordinator.textView = textView
        context.coordinator.containerView = container
        context.coordinator.observeScrollView(scrollView)
        context.coordinator.fileURL = fileURL
        context.coordinator.contentKind = contentKind
        context.coordinator.isAskActive = selectionChat.isOpen
        context.coordinator.isAskBusy = selectionChat.isBusy
        context.coordinator.onSelectionChange = onSelectionChange
        context.coordinator.onAskSelection = onAskSelection
        context.coordinator.updateAskButton()
        container.updateChatOverlay(chat: selectionChat)
        context.coordinator.render(
            text,
            language: language,
            contentKind: contentKind,
            fontSize: fontSize,
            appearance: textView.effectiveAppearance,
            resetScroll: true
        )
        return container
    }

    func updateNSView(_ nsView: SelectionAskContainerView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        context.coordinator.fileURL = fileURL
        context.coordinator.contentKind = contentKind
        context.coordinator.isAskActive = selectionChat.isOpen
        context.coordinator.isAskBusy = selectionChat.isBusy
        context.coordinator.onSelectionChange = onSelectionChange
        context.coordinator.onAskSelection = onAskSelection
        context.coordinator.updateAskButton()
        nsView.updateChatOverlay(chat: selectionChat)
        context.coordinator.render(
            text,
            language: language,
            contentKind: contentKind,
            fontSize: fontSize,
            appearance: textView.effectiveAppearance,
            resetScroll: context.coordinator.currentText != text
        )
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

        var fileURL: URL?
        var contentKind: CodeContentKind = .source
        var isAskActive = false
        var isAskBusy = false
        var onSelectionChange: (CodeSelectionContext?) -> Void = { _ in }
        var onAskSelection: (CodeSelectionContext?) -> Void = { _ in }
        var currentText: String?

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

        @objc func askSelection() {
            guard !isAskBusy else { return }
            onAskSelection(currentSelectionContext() ?? lastSelectionContext)
        }

        @objc private func scrollViewBoundsDidChange(_ notification: Notification) {
            updateAskButton()
        }

        func updateAskButton() {
            guard let containerView else { return }
            let context = currentSelectionContext()
            let rect = currentSelectionRect()
            if let context, let rect {
                lastSelectionContext = context
                lastSelectionRect = rect
            }
            let isVisible = context != nil || isAskActive
            containerView.updateAskButton(
                selectionRect: rect ?? (isAskActive ? lastSelectionRect : nil),
                isVisible: isVisible,
                isActive: isAskActive,
                isEnabled: !isAskBusy
            )
        }

        func render(
            _ text: String,
            language: String?,
            contentKind: CodeContentKind,
            fontSize: CGFloat,
            appearance: NSAppearance,
            resetScroll: Bool
        ) {
            let themeName = Self.themeName(for: appearance)
            let key = RenderKey(
                text: text,
                language: language,
                contentKind: contentKind,
                fontSize: fontSize,
                themeName: themeName
            )
            guard key != currentRenderKey else { return }
            currentRenderKey = key
            currentText = text
            renderID += 1
            let renderID = renderID
            let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)

            apply(Self.plainString(text, font: font, contentKind: contentKind, appearance: appearance), resetScroll: resetScroll)

            renderQueue.async { [weak self] in
                guard let self else { return }
                let highlighted = self.highlightedString(
                    text,
                    language: language,
                    font: font,
                    fontSize: fontSize,
                    themeName: themeName
                ) ?? Self.plainString(text, font: font, contentKind: contentKind, appearance: appearance)
                let rendered = Self.withContentStyling(
                    highlighted,
                    contentKind: contentKind,
                    appearance: appearance
                )

                DispatchQueue.main.async { [weak self] in
                    guard let self, self.renderID == renderID else { return }
                    self.apply(rendered, resetScroll: false)
                }
            }
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

        private func apply(_ attributedString: NSAttributedString, resetScroll: Bool) {
            guard let textView else { return }
            textView.textStorage?.setAttributedString(attributedString)
            if resetScroll {
                textView.scroll(.zero)
            }
            emitSelection()
        }

        private func emitSelection() {
            onSelectionChange(currentSelectionContext())
            updateAskButton()
        }

        private func currentSelectionContext() -> CodeSelectionContext? {
            guard let textView else { return nil }
            return Self.selectionContext(
                in: textView,
                fileURL: fileURL,
                contentKind: contentKind
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

        private static func selectionContext(
            in textView: NSTextView,
            fileURL: URL?,
            contentKind: CodeContentKind
        ) -> CodeSelectionContext? {
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
                startLine: lineNumber(in: nsString, at: lineRange.location),
                endLine: lineNumber(in: nsString, at: max(NSMaxRange(lineRange) - 1, lineRange.location)),
                text: text
            )
        }

        private static func lineNumber(in string: NSString, at location: Int) -> Int {
            let cappedLocation = min(max(location, 0), string.length)
            var line = 1
            var searchStart = 0

            while searchStart < cappedLocation {
                let range = string.range(
                    of: "\n",
                    options: [],
                    range: NSRange(location: searchStart, length: cappedLocation - searchStart)
                )
                guard range.location != NSNotFound else { break }
                line += 1
                searchStart = NSMaxRange(range)
            }

            return line
        }

        private static func plainString(
            _ text: String,
            font: NSFont,
            contentKind: CodeContentKind,
            appearance: NSAppearance
        ) -> NSAttributedString {
            let string = NSAttributedString(
                string: text,
                attributes: [
                    .font: font,
                    .foregroundColor: NSColor.textColor,
                ]
            )
            return withContentStyling(string, contentKind: contentKind, appearance: appearance)
        }

        private static func withContentStyling(
            _ attributedString: NSAttributedString,
            contentKind: CodeContentKind,
            appearance: NSAppearance
        ) -> NSAttributedString {
            guard contentKind == .diff else { return attributedString }

            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let result = NSMutableAttributedString(attributedString: attributedString)
            let nsString = result.string as NSString
            var location = 0

            while location < nsString.length {
                let lineRange = nsString.lineRange(for: NSRange(location: location, length: 0))
                let line = nsString.substring(with: lineRange)
                applyDiffStyle(to: result, line: line, range: lineRange, isDark: isDark)
                location = NSMaxRange(lineRange)
            }

            return result
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
        let themeName: String
    }
}

final class SelectionAskContainerView: NSView {
    private let scrollViewSlot = NSView()
    private let askButton = NSButton()
    private var selectionRect: NSRect?
    private var chatHost: NSHostingView<SelectionChatOverlayView>?
    private let buttonSize: CGFloat = 30

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    func install(scrollView: NSScrollView, target: AnyObject, action: Selector) {
        scrollViewSlot.subviews.forEach { $0.removeFromSuperview() }
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollViewSlot.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: scrollViewSlot.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: scrollViewSlot.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: scrollViewSlot.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: scrollViewSlot.bottomAnchor),
        ])

        askButton.target = target
        askButton.action = action
    }

    func updateAskButton(
        selectionRect: NSRect?,
        isVisible: Bool,
        isActive: Bool,
        isEnabled: Bool
    ) {
        self.selectionRect = selectionRect
        askButton.isHidden = !isVisible || selectionRect == nil
        askButton.isEnabled = isEnabled
        askButton.image = NSImage(
            systemSymbolName: isActive ? "text.bubble.fill" : "text.bubble",
            accessibilityDescription: "Ask about selection"
        )
        askButton.contentTintColor = isActive ? .controlAccentColor : .secondaryLabelColor
        askButton.toolTip = "Ask about selection"
        needsLayout = true
    }

    func updateChatOverlay(chat: SelectionChatController) {
        guard chat.isOpen else {
            closeChatOverlay()
            return
        }

        let host: NSHostingView<SelectionChatOverlayView>
        if let existing = chatHost {
            host = existing
            host.rootView = SelectionChatOverlayView(chat: chat)
        } else {
            let created = NSHostingView(rootView: SelectionChatOverlayView(chat: chat))
            created.translatesAutoresizingMaskIntoConstraints = true
            created.setAccessibilityIdentifier("selection-chat-overlay")
            addSubview(created, positioned: .above, relativeTo: askButton)
            chatHost = created
            host = created
        }
        host.isHidden = false
        host.invalidateIntrinsicContentSize()
        needsLayout = true
    }

    func _debugChatOverlayFrame() -> NSRect? {
        chatHost?.frame
    }

    override func layout() {
        super.layout()
        positionAskButton()
        positionChatOverlay()
    }

    private func configure() {
        wantsLayer = true

        scrollViewSlot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollViewSlot)
        NSLayoutConstraint.activate([
            scrollViewSlot.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollViewSlot.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollViewSlot.topAnchor.constraint(equalTo: topAnchor),
            scrollViewSlot.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        askButton.isHidden = true
        askButton.isBordered = false
        askButton.bezelStyle = .circular
        askButton.imagePosition = .imageOnly
        askButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        askButton.wantsLayer = true
        askButton.layer?.cornerRadius = buttonSize / 2
        askButton.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.92).cgColor
        askButton.layer?.shadowColor = NSColor.black.cgColor
        askButton.layer?.shadowOpacity = 0.18
        askButton.layer?.shadowRadius = 8
        askButton.layer?.shadowOffset = NSSize(width: 0, height: -1)
        addSubview(askButton)
    }

    private func positionAskButton() {
        guard let selectionRect, !askButton.isHidden else { return }
        let margin: CGFloat = 10
        let x = min(max(selectionRect.maxX + 8, margin), max(bounds.maxX - buttonSize - margin, margin))
        let y = min(
            max(selectionRect.midY - buttonSize / 2, margin),
            max(bounds.maxY - buttonSize - margin, margin)
        )
        askButton.frame = NSRect(x: x, y: y, width: buttonSize, height: buttonSize)
    }

    private func closeChatOverlay() {
        chatHost?.removeFromSuperview()
        chatHost = nil
    }

    private func positionChatOverlay() {
        guard let host = chatHost, !host.isHidden else { return }
        let anchorRect = selectionRect ?? askButton.frame
        guard !anchorRect.isEmpty else { return }

        let margin: CGFloat = 12
        let fittingSize = host.fittingSize
        let maxWidth = max(bounds.width - margin * 2, 280)
        let maxHeight = max(bounds.height - margin * 2, 180)
        let width = min(max(fittingSize.width, 440), min(520, maxWidth))
        let height = min(max(fittingSize.height, 142), min(430, maxHeight))

        let rightX = anchorRect.maxX + 12
        let leftX = anchorRect.minX - width - 12
        let x: CGFloat
        if rightX + width <= bounds.maxX - margin {
            x = rightX
        } else if leftX >= margin {
            x = leftX
        } else {
            x = min(max(anchorRect.minX, margin), max(bounds.maxX - width - margin, margin))
        }

        let y = min(
            max(anchorRect.midY - height / 2, margin),
            max(bounds.maxY - height - margin, margin)
        )
        host.frame = NSRect(x: x, y: y, width: width, height: height)
    }
}
