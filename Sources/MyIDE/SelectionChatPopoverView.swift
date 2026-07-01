import SwiftUI

struct SelectionChatPopoverView: View {
    @ObservedObject var chat: SelectionChatController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if !chat.answer.isEmpty || !chat.toolEvents.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if !chat.toolEvents.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(chat.toolEvents) { event in
                                    AgentToolEventRow(event: event)
                                }
                            }
                        }

                        if !chat.answer.isEmpty {
                            Text(chat.answer)
                                .font(.callout)
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: 260)
            }

            composer
        }
        .padding(12)
        .frame(width: 430)
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
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask about the selection", text: $chat.draft, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .disabled(chat.isBusy)
                .onSubmit {
                    chat.submit()
                }

            Button {
                chat.submit()
            } label: {
                Image(systemName: chat.isBusy ? "hourglass" : "paperplane.fill")
                    .frame(width: 18, height: 18)
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!chat.canSubmit)
            .help(chat.isBusy ? "Waiting for answer" : "Send")
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

private struct AgentToolEventRow: View {
    let event: AgentToolEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: event.status == .finished ? "checkmark.circle.fill" : "circle.dotted")
                    .foregroundStyle(event.status == .finished ? .green : .secondary)
                    .frame(width: 14)
                Text(event.name)
                    .font(.caption)
                    .fontWeight(.medium)
                    .monospaced()
                Spacer(minLength: 8)
                Text(event.status == .finished ? "done" : "running")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if !event.arguments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(event.arguments)
                    .font(.caption2)
                    .monospaced()
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

            if let outputPreview = event.outputPreview {
                Text(outputPreview)
                    .font(.caption2)
                    .monospaced()
                    .foregroundStyle(.tertiary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.72))
        )
    }
}
