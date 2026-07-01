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

                    if chat.isBusy {
                        AgentProgressCard(
                            activity: chat.currentActivity,
                            toolEvents: chat.toolEvents,
                            fontSize: fontSize
                        )
                    }

                    if !chat.answer.isEmpty {
                        AssistantAnswerBlock(text: chat.answer, fontSize: fontSize) { reference in
                            chat.openCodeReference(reference)
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
        !chat.submittedQuestion.isEmpty || !chat.answer.isEmpty || chat.isBusy
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

private struct AgentProgressCard: View {
    let activity: String
    let toolEvents: [AgentToolEvent]
    let fontSize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text(activity.isEmpty ? "Reading the code context" : activity)
                        .font(.system(size: fontSize, weight: .medium))
                    Text(summaryText)
                        .font(.system(size: max(fontSize - 3, 9)))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 6) {
                ForEach(progressSteps, id: \.self) { step in
                    Text(step)
                        .font(.system(size: max(fontSize - 4, 9), weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.84))
                        )
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.accentColor.opacity(0.24), lineWidth: 1)
        )
    }

    private var summaryText: String {
        let finished = toolEvents.filter { $0.status == .finished }.count
        if finished == 0 {
            return "Starting with the diff, then following only the relevant files."
        }
        let noun = finished == 1 ? "context step" : "context steps"
        return "\(finished) \(noun) checked. I’ll show the answer when it is ready."
    }

    private var progressSteps: [String] {
        var labels: [String] = []
        if toolEvents.contains(where: { $0.name == "get_git_diff" }) {
            labels.append("diff")
        }
        if toolEvents.contains(where: { $0.name == "search_text" || $0.name == "list_files" }) {
            labels.append("search")
        }
        if toolEvents.contains(where: { $0.name == "read_file" }) {
            labels.append("files")
        }
        return labels.isEmpty ? ["diff", "search", "files"] : labels
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
        var attributed = (try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
        applyCodeReferenceLinks(to: &attributed)
        return attributed
    }

    private func applyCodeReferenceLinks(to attributed: inout AttributedString) {
        let plainText = String(attributed.characters)
        var cursor = plainText.startIndex

        for segment in CodeReferenceParser.segments(in: plainText) {
            let nextCursor = plainText.index(cursor, offsetBy: segment.text.count, limitedBy: plainText.endIndex)
                ?? plainText.endIndex
            defer { cursor = nextCursor }

            guard let reference = segment.reference,
                  cursor < nextCursor,
                  let lower = AttributedString.Index(cursor, within: attributed),
                  let upper = AttributedString.Index(nextCursor, within: attributed) else {
                continue
            }

            attributed[lower..<upper].link = reference.url
        }
    }
}
