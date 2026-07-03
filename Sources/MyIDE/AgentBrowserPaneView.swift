import SwiftUI
import MyIDECore

/// A read-only rendering of the page the agent is working on: fake browser
/// chrome over native controls drawn from the engine's `BrowserPage`. The agent
/// drives; the person watches — the element the agent just touched flashes an
/// accent ring so the eye can follow along.
struct AgentBrowserPaneView: View {
    @ObservedObject var controller: AgentWorkspaceController

    @State private var flashElementID: String?
    @State private var flashOpacity: Double = 0

    var body: some View {
        VStack(spacing: 0) {
            chromeBar
            Divider()
            pageBody
            if case .replaying(let step, let of) = controller.phase {
                Divider()
                replayFooter(step: step, of: of)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onChange(of: controller.actionRevision) {
            flashElementID = controller.lastActedElementID
            flashOpacity = 1
            withAnimation(.easeOut(duration: 1.0)) {
                flashOpacity = 0
            }
        }
        .accessibilityIdentifier("agent-browser-pane")
    }

    // MARK: - Chrome

    private var chromeBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Circle().fill(Color(red: 0.98, green: 0.37, blue: 0.34)).frame(width: 10, height: 10)
                Circle().fill(Color(red: 0.99, green: 0.74, blue: 0.18)).frame(width: 10, height: 10)
                Circle().fill(Color(red: 0.22, green: 0.78, blue: 0.25)).frame(width: 10, height: 10)
            }
            Text(controller.browserIsReal
                ? (controller.currentRealURL ?? "real Chrome — no page yet")
                : (controller.page?.url ?? "about:blank"))
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity)
                .background(Capsule().fill(.quaternary.opacity(0.6)))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.bar)
    }

    // MARK: - Page

    @ViewBuilder
    private var pageBody: some View {
        if controller.browserIsReal {
            realSessionCard
        } else if let page = controller.page {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(page.elements.enumerated()), id: \.offset) { _, element in
                        elementView(element)
                            .overlay {
                                if element.id == flashElementID {
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(Color.accentColor, lineWidth: 3)
                                        .padding(-6)
                                        .opacity(flashOpacity)
                                }
                            }
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "globe")
                    .font(.system(size: 36))
                    .foregroundStyle(.tertiary)
                Text("The browser lights up here when the assistant starts working.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
        }
    }

    /// Real-Chrome sessions: the browser is an actual window on screen, so
    /// this pane becomes the live action feed instead of a rendered page.
    private var realSessionCard: some View {
        VStack(spacing: 14) {
            Image(systemName: "macwindow.on.rectangle")
                .font(.system(size: 34))
                .foregroundStyle(Color.accentColor)
            Text("Real Chrome session")
                .font(.headline)
            Text("The assistant is driving an actual Chrome window — watch it work there. If a site asks for a password, you type it in Chrome yourself.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let action = controller.lastRealAction {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        if controller.isExecutingCommand {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                        Text(controller.isExecutingCommand ? "Running" : "Last action")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(action)
                        .font(.caption.monospaced())
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func elementView(_ element: BrowserElement) -> some View {
        switch element.role {
        case .heading:
            Text(element.label)
                .font(.title2.weight(.semibold))
        case .text:
            Text(element.label)
                .foregroundStyle(.secondary)
        case .link:
            Text(element.label)
                .foregroundStyle(Color.accentColor)
                .underline()
        case .textbox:
            VStack(alignment: .leading, spacing: 4) {
                Text(element.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(element.value.isEmpty ? " " : element.value)
                    .font(.body.monospaced())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(width: 280, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(Color(nsColor: .separatorColor))
                    )
            }
        case .button:
            Text(element.label)
                .font(.body.weight(.medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(Capsule().fill(element.disabled ? Color.gray.opacity(0.25) : Color.accentColor))
                .foregroundStyle(element.disabled ? Color.secondary : Color.white)
        case .radio:
            HStack(spacing: 8) {
                Image(systemName: element.checked ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(element.checked ? Color.accentColor : Color.secondary)
                Text(element.label)
            }
        case .combobox:
            VStack(alignment: .leading, spacing: 4) {
                Text(element.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Text(element.value.isEmpty ? "Choose…" : element.value)
                        .foregroundStyle(element.value.isEmpty ? .secondary : .primary)
                    Spacer()
                    Image(systemName: element.children.isEmpty ? "chevron.down" : "chevron.up")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(width: 280)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Color(nsColor: .separatorColor))
                )
                if !element.children.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(element.children.enumerated()), id: \.offset) { _, option in
                            optionRow(option)
                        }
                    }
                    .frame(width: 280, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Color(nsColor: .controlBackgroundColor))
                            .shadow(radius: 3, y: 2)
                    )
                }
            }
        case .option:
            optionRow(element)
        }
    }

    /// Option rows are rendered by a separate builder — `elementView` calling
    /// itself would make its opaque return type recursive.
    private func optionRow(_ element: BrowserElement) -> some View {
        HStack {
            Text(element.label)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(element.highlighted ? Color.accentColor.opacity(0.22) : Color.clear)
    }

    // MARK: - Replay progress

    private func replayFooter(step: Int, of: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: Double(step), total: Double(max(of, 1)))
            Text("Step \(step) of \(of)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
    }
}
