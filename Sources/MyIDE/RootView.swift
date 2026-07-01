import SwiftUI

/// Top-level window layout: a native sidebar/detail split. Sidebar = file tree, detail =
/// content pane. `NavigationSplitView` provides the standard collapsible, resizable columns.
struct RootView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        NavigationSplitView {
            FileTreeView(
                rootNode: appState.sidebarRoot,
                changeTreeState: appState.changeTreeState,
                selection: $appState.selectedFileURL
            )
                .navigationTitle(appState.navigationTitle)
                .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 460)
        } detail: {
            ContentPaneView(
                rootURL: appState.rootURL,
                fileURL: appState.selectedFileURL,
                changeTreeState: appState.changeTreeState,
                fontSize: appState.fontSize
            )
                .navigationSplitViewColumnWidth(min: 420, ideal: 720)
        }
        .task { appState.loadChangeTreeIfNeeded() }
    }
}
