import SwiftUI
import MyIDECore

/// The session console: a terminal-styled transcript of the Claude session the
/// harness is running, with a plain-English status chip and a prompt field.
struct AgentTerminalPaneView: View {
    @ObservedObject var controller: AgentWorkspaceController

    private static let background = Color(red: 0.09, green: 0.10, blue: 0.13)
    private static let font = Font.system(size: 12.5, design: .monospaced)

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            Divider()
            transcriptView
            Divider()
            inputBar
        }
        .background(Self.background)
        .accessibilityIdentifier("agent-terminal")
    }

    // MARK: - Status

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(controller.statusText)
                .font(.caption)
                .foregroundStyle(Color(white: 0.85))
            if controller.mode == .mock {
                Text("demo")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.blue.opacity(0.35)))
                    .foregroundStyle(Color(white: 0.9))
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var statusColor: Color {
        switch controller.phase {
        case .connecting: return .yellow
        case .ready: return .green
        case .working: return .orange
        case .replaying: return .blue
        case .offline: return .red
        }
    }

    // MARK: - Transcript

    private var transcriptView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(controller.transcript) { entry in
                        entryView(entry)
                    }
                    Color.clear.frame(height: 1).id("transcript-bottom")
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: controller.transcript.count) {
                proxy.scrollTo("transcript-bottom", anchor: .bottom)
            }
        }
    }

    @ViewBuilder
    private func entryView(_ entry: AgentTranscriptEntry) -> some View {
        switch entry.kind {
        case .user:
            Text("\(Text("❯ ").foregroundStyle(Color.green))\(Text(entry.text).foregroundStyle(Color.white))")
                .font(Self.font.weight(.semibold))
                .textSelection(.enabled)
        case .assistant:
            Text(entry.text)
                .font(Self.font)
                .foregroundStyle(Color(white: 0.88))
                .textSelection(.enabled)
        case .tool(let ok):
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Text("⚙ ").foregroundStyle(Color(white: 0.45)))\(Text(entry.text).foregroundStyle(Color(white: 0.6)))\(Text(ok ? "  ✓" : "  ✗").foregroundStyle(ok ? Color.green.opacity(0.8) : Color.orange))")
                    .font(Self.font)
                if let detail = entry.detail {
                    Text("   → \(detail)")
                        .font(Self.font)
                        .foregroundStyle(ok ? Color(white: 0.45) : Color.orange.opacity(0.9))
                }
            }
            .textSelection(.enabled)
        case .status:
            Text(entry.text)
                .font(Self.font.italic())
                .foregroundStyle(Color(red: 0.55, green: 0.7, blue: 0.95))
                .textSelection(.enabled)
        }
    }

    // MARK: - Input

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Tell me what to do — try: Submit my massage claim", text: $controller.input)
                .textFieldStyle(.plain)
                .font(Self.font)
                .foregroundStyle(Color.white)
                .onSubmit { controller.sendPrompt() }
            Button("Send") { controller.sendPrompt() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!controller.canSendPrompt || controller.input.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(10)
        .disabled(!controller.canSendPrompt)
    }
}
