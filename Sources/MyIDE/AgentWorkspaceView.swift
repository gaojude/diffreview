import SwiftUI

/// Root of the Assistant window: automations shelf | session terminal | browser.
struct AgentWorkspaceView: View {
    @ObservedObject var controller: AgentWorkspaceController

    var body: some View {
        HSplitView {
            AutomationShelfView(controller: controller)
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 360)
            AgentTerminalPaneView(controller: controller)
                .frame(minWidth: 360, idealWidth: 480, maxWidth: .infinity)
            AgentBrowserPaneView(controller: controller)
                .frame(minWidth: 320, idealWidth: 400, maxWidth: .infinity)
        }
        .task {
            controller.connect()
        }
    }
}
