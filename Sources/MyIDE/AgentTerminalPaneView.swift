import SwiftUI
import MyIDECore

/// The session console: a terminal-styled transcript of the Claude session the
/// harness is running, with a plain-English status chip and a prompt field.
struct AgentTerminalPaneView: View {
    @ObservedObject var controller: AgentWorkspaceController
    @State private var showSaveLogin = false
    @State private var loginName = ""

    // Light theme.
    private static let background = Color(red: 0.97, green: 0.975, blue: 0.98)
    private static let inputFill = Color.white
    private static let inputStroke = Color(red: 0.80, green: 0.82, blue: 0.86)
    private static let accent = Color(red: 0.16, green: 0.46, blue: 0.95)
    private static let primaryText = Color(red: 0.13, green: 0.14, blue: 0.17)
    private static let secondaryText = Color(red: 0.42, green: 0.45, blue: 0.50)
    private static let userGreen = Color(red: 0.14, green: 0.55, blue: 0.30)
    private static let font = Font.system(size: 13, design: .monospaced)

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            if controller.supportsSavedLogins {
                Divider().overlay(Self.inputStroke.opacity(0.4))
                loginBar
            }
            Divider().overlay(Self.inputStroke.opacity(0.4))
            transcriptView
            Divider().overlay(Self.inputStroke.opacity(0.4))
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
                .foregroundStyle(Self.primaryText)
            if controller.mode == .mock {
                Text("demo")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Self.accent.opacity(0.15)))
                    .foregroundStyle(Self.accent)
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

    // MARK: - Saved logins (first-class)

    private var loginBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "key.fill")
                .font(.caption2)
                .foregroundStyle(Self.accent)
            if controller.savedSessions.isEmpty {
                Text("No saved logins yet")
                    .font(.caption)
                    .foregroundStyle(Self.secondaryText)
            } else {
                Menu {
                    ForEach(controller.savedSessions) { session in
                        Button("Restore “\(session.name)”") { controller.restoreLogin(session) }
                    }
                    Divider()
                    ForEach(controller.savedSessions) { session in
                        Button("Delete “\(session.name)”", role: .destructive) {
                            controller.deleteSavedLogin(session)
                        }
                    }
                } label: {
                    Text("Restore login")
                        .font(.caption.weight(.medium))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(controller.isBusy)
                .tint(Self.accent)
            }
            Spacer()
            Button {
                loginName = ""
                showSaveLogin = true
            } label: {
                Label("Save login", systemImage: "square.and.arrow.down")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.borderless)
            .tint(Self.accent)
            .disabled(controller.isSavingSession)
            .popover(isPresented: $showSaveLogin, arrowEdge: .bottom) {
                saveLoginForm
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var saveLoginForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Save this login")
                .font(.headline)
            Text("Sign in once in Chrome, then save it here. I'll restore it so you stay signed in — no password needed next time.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Name — e.g. QQ, Gmail, work portal", text: $loginName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .onSubmit(commitSaveLogin)
            HStack {
                Spacer()
                Button("Cancel") { showSaveLogin = false }
                Button("Save") { commitSaveLogin() }
                    .buttonStyle(.borderedProminent)
                    .disabled(loginName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
    }

    private func commitSaveLogin() {
        let name = loginName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        controller.saveLogin(name: name)
        showSaveLogin = false
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
            Text("\(Text("❯ ").foregroundStyle(Self.userGreen))\(Text(entry.text).foregroundStyle(Self.primaryText))")
                .font(Self.font.weight(.semibold))
                .textSelection(.enabled)
        case .assistant:
            Text(entry.text)
                .font(Self.font)
                .foregroundStyle(Self.primaryText)
                .textSelection(.enabled)
        case .tool(let ok):
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Text("⚙ ").foregroundStyle(Self.secondaryText))\(Text(entry.text).foregroundStyle(Self.secondaryText))\(Text(ok ? "  ✓" : "  ✗").foregroundStyle(ok ? Self.userGreen : Color.orange))")
                    .font(Self.font)
                if let detail = entry.detail {
                    Text("   → \(detail)")
                        .font(Self.font)
                        .foregroundStyle(ok ? Self.secondaryText : Color.orange)
                }
            }
            .textSelection(.enabled)
        case .status:
            Text(entry.text)
                .font(Self.font.italic())
                .foregroundStyle(Self.accent)
                .textSelection(.enabled)
        }
    }

    // MARK: - Input

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Tell me what to do…", text: $controller.input)
                .textFieldStyle(.plain)
                .font(Self.font)
                .foregroundStyle(Self.primaryText)
                .tint(Self.accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(Self.inputFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(Self.inputStroke, lineWidth: 1)
                )
                .onSubmit { controller.sendPrompt() }
            Button {
                controller.sendPrompt()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(
                Circle().fill(canSend ? Self.accent : Self.inputStroke)
            )
            .disabled(!canSend)
        }
        .padding(10)
    }

    private var canSend: Bool {
        controller.canSendPrompt && !controller.input.trimmingCharacters(in: .whitespaces).isEmpty
    }
}
