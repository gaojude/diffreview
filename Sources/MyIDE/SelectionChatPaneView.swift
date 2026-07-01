import Foundation
import SwiftUI

struct SelectionChatPaneView: View {
    @ObservedObject var chat: SelectionChatController
    let fontSize: CGFloat
    @FocusState private var isComposerFocused: Bool

    private let bottomID = "selection-chat-bottom"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()
            if hasTranscript {
                transcript
            } else {
                emptyState
            }

            Divider()
            composer
        }
        .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("selection-chat-pane")
        .onAppear(perform: focusComposer)
        .onChange(of: chat.isBusy) { _, isBusy in
            if !isBusy {
                focusComposer()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(statusColor)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text("Agent Chat")
                    .font(.system(size: fontSize, weight: .medium))
                    .lineLimit(1)
                Text(chat.statusText)
                    .font(.system(size: max(fontSize - 2, 10)))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if hasTranscript || !chat.draft.isEmpty {
                Button {
                    chat.clearTranscript()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Clear chat")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 56)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !chat.submittedQuestion.isEmpty {
                        UserQuestionBubble(text: chat.submittedQuestion, fontSize: fontSize)
                    }

                    if !chat.toolEvents.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(chat.toolEvents) { event in
                                AgentToolEventRow(event: event, fontSize: fontSize) { reference in
                                    chat.openCodeReference(reference)
                                }
                            }
                        }
                    }

                    if !chat.answer.isEmpty {
                        AssistantAnswerBlock(text: chat.answer, fontSize: fontSize) { reference in
                            chat.openCodeReference(reference)
                        }
                    } else if chat.isBusy {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text(chat.currentActivity.isEmpty ? "Thinking" : chat.currentActivity)
                                .font(.system(size: max(fontSize - 2, 10)))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(bottomID)
                }
                .padding(12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.42))
            .onChange(of: chat.answer) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: chat.toolEvents) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: chat.submittedQuestion) { _, _ in
                scrollToBottom(proxy)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: chat.hasContext ? "text.bubble" : "cursorarrow.rays")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(chat.hasContext ? "Ask about the current selection" : "Select code in the editor")
                .font(.system(size: fontSize))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let contextLabel = chat.contextLabel {
                Text(contextLabel)
                    .font(.system(size: max(fontSize - 2, 10)))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask about the selection", text: $chat.draft, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: fontSize))
                .focused($isComposerFocused)
                .disabled(chat.isBusy || !chat.hasContext)
                .submitLabel(.send)
                .onSubmit {
                    chat.submit()
                }
                .accessibilityIdentifier("selection-chat-input")

            if chat.isBusy {
                Button {
                    chat.cancelResponse()
                } label: {
                    Image(systemName: "stop.fill")
                        .frame(width: 18, height: 18)
                }
                .keyboardShortcut(".", modifiers: .command)
                .help("Stop")
            } else {
                Button {
                    chat.submit()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .frame(width: 18, height: 18)
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!chat.canSubmit)
                .help("Send")
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
    }

    private var hasTranscript: Bool {
        !chat.submittedQuestion.isEmpty || !chat.answer.isEmpty || !chat.toolEvents.isEmpty || chat.isBusy
    }

    private func focusComposer() {
        DispatchQueue.main.async {
            isComposerFocused = true
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.16)) {
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
        }
    }

    private var statusColor: Color {
        switch chat.phase {
        case .failed:
            return .red
        case .thinking:
            return .accentColor
        default:
            return .secondary
        }
    }
}

private struct UserQuestionBubble: View {
    let text: String
    let fontSize: CGFloat

    var body: some View {
        HStack(alignment: .top) {
            Spacer(minLength: 48)
            Text(text)
                .font(.system(size: fontSize))
                .foregroundStyle(.white)
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.accentColor)
                )
        }
    }
}

private struct AssistantAnswerBlock: View {
    let text: String
    let fontSize: CGFloat
    let onOpenReference: (CodeReference) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: max(fontSize - 2, 10)))
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .padding(.top, 2)

            CodeLinkedMarkdownText(
                text: text,
                fontSize: fontSize,
                monospaced: false,
                lineLimit: nil,
                onOpenReference: onOpenReference
            )
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct AgentToolEventRow: View {
    let event: AgentToolEvent
    let fontSize: CGFloat
    let onOpenReference: (CodeReference) -> Void
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                if !formattedArguments.isEmpty {
                    ToolDetailBlock(
                        title: "Arguments",
                        text: formattedArguments,
                        fontSize: fontSize,
                        onOpenReference: onOpenReference
                    )
                }

                if let outputPreview = event.outputPreview {
                    ToolDetailBlock(
                        title: "Output",
                        text: outputPreview,
                        fontSize: fontSize,
                        onOpenReference: onOpenReference
                    )
                }
            }
            .padding(.top, 4)
        } label: {
            HStack(spacing: 7) {
                if event.status == .finished {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .frame(width: 14)
                } else {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 14)
                }

                Text(event.name)
                    .font(.system(size: max(fontSize - 2, 10)))
                    .fontWeight(.medium)
                    .monospaced()

                Spacer(minLength: 8)

                Text(event.status == .finished ? "done" : "running")
                    .font(.system(size: max(fontSize - 3, 9)))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.72))
        )
    }

    private var formattedArguments: String {
        let trimmed = event.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let data = trimmed.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            JSONSerialization.isValidJSONObject(object),
            let formatted = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
            let text = String(data: formatted, encoding: .utf8)
        else {
            return trimmed
        }
        return text
    }
}

private struct ToolDetailBlock: View {
    let title: String
    let text: String
    let fontSize: CGFloat
    let onOpenReference: (CodeReference) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: max(fontSize - 3, 9)))
                .foregroundStyle(.secondary)
            CodeLinkedMarkdownText(
                text: text,
                fontSize: max(fontSize - 3, 9),
                monospaced: true,
                lineLimit: 8,
                onOpenReference: onOpenReference
            )
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct CodeLinkedMarkdownText: View {
    let text: String
    let fontSize: CGFloat
    let monospaced: Bool
    let lineLimit: Int?
    let onOpenReference: (CodeReference) -> Void

    var body: some View {
        Text(attributedText)
            .font(monospaced ? .system(size: fontSize, design: .monospaced) : .system(size: fontSize))
            .lineLimit(lineLimit)
            .textSelection(.enabled)
            .environment(\.openURL, OpenURLAction { url in
                guard let reference = CodeReference(url: url) else { return .systemAction }
                onOpenReference(reference)
                return .handled
            })
    }

    private var attributedText: AttributedString {
        let linkedMarkdown = markdownWithCodeLinks(text)
        if let attributed = try? AttributedString(
            markdown: linkedMarkdown,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return attributed
        }
        return AttributedString(text)
    }

    private func markdownWithCodeLinks(_ text: String) -> String {
        let markdown = CodeReferenceParser.segments(in: text)
            .map { segment in
                guard let reference = segment.reference else { return segment.text }
                return "[\(escapeMarkdownLinkLabel(segment.text))](\(reference.url.absoluteString))"
            }
            .joined()
        return unwrapCodeSpansAroundGeneratedLinks(markdown)
    }

    private func escapeMarkdownLinkLabel(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
    }

    private func unwrapCodeSpansAroundGeneratedLinks(_ markdown: String) -> String {
        let pattern = #"`(\[[^\]]+\]\(myide-code-ref://[^)]+\))`"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return markdown }
        let range = NSRange(location: 0, length: (markdown as NSString).length)
        return regex.stringByReplacingMatches(in: markdown, options: [], range: range, withTemplate: "$1")
    }
}
