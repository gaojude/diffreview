import SwiftUI
import MyIDECore

/// The workspace's home column: saved automations as one-click Run cards, plus
/// the recording controls that turn the current session into a new automation.
/// Deliberately the least technical part of the app — anyone should be able to
/// open the Assistant and press Run.
struct AutomationShelfView: View {
    @ObservedObject var controller: AgentWorkspaceController
    @State private var showingSaveSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if controller.automations.isEmpty {
                emptyState
            } else {
                automationList
            }
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showingSaveSheet) {
            SaveAutomationSheet(controller: controller)
        }
        .accessibilityIdentifier("automation-shelf")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Things I can do for you")
                .font(.headline)
            Text("Press Run and watch the browser do the work.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("When the assistant finishes a task, save it here and replay it any time with one click.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var automationList: some View {
        ScrollView {
            VStack(spacing: 10) {
                ForEach(controller.automations, id: \.slug) { automation in
                    automationCard(automation)
                }
            }
            .padding(12)
        }
    }

    private func automationCard(_ automation: Automation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(automation.name)
                .font(.headline)
            Text(automation.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            HStack {
                Button {
                    controller.runAutomation(automation)
                } label: {
                    Label("Run", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(controller.isBusy)
            }
            Text("\(automation.steps.count) steps")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.quaternary.opacity(0.5))
        )
        .contextMenu {
            Button("Delete \"\(automation.name)\"", role: .destructive) {
                controller.deleteAutomation(automation)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if controller.mode != .none {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 7, height: 7)
                    Text("Remembering what the assistant does")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Button {
                showingSaveSheet = true
            } label: {
                Label("Save as automation…", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .disabled(!controller.canSaveAutomation)
        }
        .padding(12)
    }
}

/// Sheet for naming a freshly recorded automation. Two fields, no jargon.
private struct SaveAutomationSheet: View {
    @ObservedObject var controller: AgentWorkspaceController
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var summary = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Save as automation")
                .font(.headline)
            Text("Give it a name you'll recognize — next time it's one click.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Name — e.g. Submit my massage claim", text: $name)
                .textFieldStyle(.roundedBorder)
            TextField("What does it do? (one line)", text: $summary)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    controller.saveRecording(name: name, summary: summary)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 400)
    }
}
