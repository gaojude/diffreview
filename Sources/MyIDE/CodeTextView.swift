import SwiftUI
import AppKit
import MyIDECore
import Highlighter

/// Read-only, monospaced code viewer backed by AppKit's `NSTextView`. Native text layout
/// handles large files far better than SwiftUI's `Text`, which is the point of using a
/// representable here.
struct CodeTextView: NSViewRepresentable {
    enum ContentKind: Equatable {
        case source
        case diff
    }

    let text: String
    let fileURL: URL?
    var contentKind: ContentKind = .source
    /// Space reserved at the top so content scrolls under the floating glass header.
    var topInset: CGFloat = 8
    /// Monospaced point size, driven by the View-menu font shortcuts.
    var fontSize: CGFloat = FontSizes.default

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
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

        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.render(
            text,
            language: language,
            contentKind: contentKind,
            fontSize: fontSize,
            appearance: textView.effectiveAppearance,
            resetScroll: true
        )
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
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

    final class Coordinator {
        weak var textView: NSTextView?
        private let renderQueue = DispatchQueue(label: "com.judegao.myide.syntax-highlighting", qos: .userInitiated)
        private var highlighter: Highlighter?
        private var renderID = 0
        private var currentRenderKey: RenderKey?

        var currentText: String?

        func render(
            _ text: String,
            language: String?,
            contentKind: ContentKind,
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
        }

        private static func plainString(
            _ text: String,
            font: NSFont,
            contentKind: ContentKind,
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
            contentKind: ContentKind,
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
        let contentKind: ContentKind
        let fontSize: CGFloat
        let themeName: String
    }
}
