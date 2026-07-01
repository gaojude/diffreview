import Foundation
import SwiftUI

struct SelectionChatOverlayView: View {
    @ObservedObject var chat: SelectionChatController
    @FocusState private var isComposerFocused: Bool

    private let bottomID = "selection-chat-bottom"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if hasTranscript {
                Divider()
                transcript
            }

            Divider()
            composer
        }
        .frame(width: 480)
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.24), radius: 18, x: 0, y: 8)
        .accessibilityIdentifier("selection-chat-overlay")
        .onAppear(perform: focusComposer)
        .onChange(of: chat.isBusy) { _, isBusy in
            if !isBusy {
                focusComposer()
            }
        }
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: statusIcon)
                .foregroundStyle(statusColor)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(chat.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let contextLabel = chat.contextLabel {
                    Text(contextLabel)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            Button {
                chat.close()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !chat.submittedQuestion.isEmpty {
                        UserQuestionBubble(text: chat.submittedQuestion)
                    }

                    if !chat.toolEvents.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(chat.toolEvents) { event in
                                AgentToolEventRow(event: event)
                            }
                        }
                    }

                    if !chat.answer.isEmpty {
                        AssistantAnswerBlock(text: chat.answer)
                    } else if chat.isBusy {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text(chat.currentActivity.isEmpty ? "Thinking" : chat.currentActivity)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(bottomID)
                }
                .padding(12)
            }
            .frame(maxHeight: 320)
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

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask about the selection", text: $chat.draft, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .focused($isComposerFocused)
                .disabled(chat.isBusy)
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

    private var statusIcon: String {
        switch chat.phase {
        case .closed:
            return "text.bubble"
        case .composing:
            return "text.bubble"
        case .thinking:
            return "sparkles"
        case .failed:
            return "exclamationmark.triangle"
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

    var body: some View {
        HStack(alignment: .top) {
            Spacer(minLength: 48)
            Text(text)
                .font(.callout)
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

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkles")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .padding(.top, 2)

            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct AgentToolEventRow: View {
    let event: AgentToolEvent
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                if !formattedArguments.isEmpty {
                    ToolDetailBlock(title: "Arguments", text: formattedArguments)
                }

                if let outputPreview = event.outputPreview {
                    ToolDetailBlock(title: "Output", text: outputPreview)
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
                    .font(.caption)
                    .fontWeight(.medium)
                    .monospaced()

                Spacer(minLength: 8)

                Text(event.status == .finished ? "done" : "running")
                    .font(.caption2)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.caption2)
                .monospaced()
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
                .lineLimit(8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
