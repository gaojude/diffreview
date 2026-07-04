import SwiftUI

/// Root of the Assistant window. Currently chat-only by design: a compact,
/// plugin-style companion — the agent's browser work happens in the real
/// Chrome window, so the session console is the whole story. The automations
/// shelf and the mock-browser pane still exist in the codebase
/// (AutomationShelfView / AgentBrowserPaneView) but are not mounted for now.
struct AgentWorkspaceView: View {
    @ObservedObject var controller: AgentWorkspaceController

    var body: some View {
        AgentTerminalPaneView(controller: controller)
            .task {
                controller.connect()
            }
    }
}
