import SwiftUI
import MyIDECore

/// Top-level window layout: the diff content pane fills the window — there is no file-tree
/// sidebar. The toolbar button that used to toggle the sidebar now shows/hides the
/// review-comments column instead (rendered as the leading column of the content pane).
struct RootView: View {
    @ObservedObject var appState: AppState
    /// Comments column visibility. Auto-shown by the content pane when the first comment is
    /// written; this toolbar state lets the reviewer bring it back or tuck it away anytime.
    @State private var showCommentsPanel = false
    /// One-shot jump command consumed by the content pane; fresh identity per press.
    @State private var changeJumpRequest: ChangeJumpRequest?

    var body: some View {
        ContentPaneView(
            rootURL: appState.rootURL,
            changeTreeState: appState.changeTreeState,
            fontSize: appState.fontSize,
            diffLayout: appState.diffLayout,
            onDiffLayoutChange: { appState.setDiffLayout($0) },
            showCommentsPanel: $showCommentsPanel,
            changeJumpRequest: changeJumpRequest
        )
        .navigationTitle(appState.navigationTitle)
        .toolbar {
            // Lives where the sidebar toggle used to be; macOS 26 renders toolbar buttons
            // with the Liquid Glass treatment.
            ToolbarItem(placement: .navigation) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showCommentsPanel.toggle() }
                } label: {
                    Label(
                        showCommentsPanel ? "Hide Comments" : "Show Comments",
                        systemImage: "sidebar.leading"
                    )
                }
                .help(showCommentsPanel ? "Hide the review comments" : "Show the review comments")
                .accessibilityIdentifier("comments-panel-toggle")
            }
            // Jump between change blocks without scrolling through diff context.
            ToolbarItem(placement: .primaryAction) {
                ControlGroup {
                    Button {
                        changeJumpRequest = ChangeJumpRequest(forward: false)
                    } label: {
                        Label("Previous Change", systemImage: "chevron.up")
                    }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                    .help("Jump to the previous change (⌥⌘↑)")
                    .accessibilityIdentifier("jump-previous-change")

                    Button {
                        changeJumpRequest = ChangeJumpRequest(forward: true)
                    } label: {
                        Label("Next Change", systemImage: "chevron.down")
                    }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                    .help("Jump to the next change (⌥⌘↓)")
                    .accessibilityIdentifier("jump-next-change")
                }
            }

            // Which diff the document shows: the whole branch, or one commit picked from
            // the branch's history — the GitHub "Changes from" menu, as a native control.
            ToolbarItem(placement: .primaryAction) {
                if !appState.commits.isEmpty {
                    Menu {
                        Picker("Commits", selection: Binding(
                            get: { appState.scope },
                            set: { appState.select(scope: $0) }
                        )) {
                            Text("All branch changes").tag(GitDiffScope.branch)
                            Divider()
                            ForEach(appState.commits) { commit in
                                Text("\(commit.shortSHA)  \(commit.subject)")
                                    .tag(GitDiffScope.commit(commit.sha))
                            }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Label(commitMenuLabel, systemImage: "clock.arrow.circlepath")
                    }
                    .help("Choose which commit's changes to review")
                    .accessibilityIdentifier("commit-scope-picker")
                }
            }
            // Split vs unified layout, out of the content's way.
            ToolbarItem(placement: .primaryAction) {
                Picker("Diff Layout", selection: Binding(
                    get: { appState.diffLayout },
                    set: { appState.setDiffLayout($0) }
                )) {
                    Image(systemName: "rectangle.split.2x1")
                        .tag(DiffLayoutMode.split)
                        .help("Split view")
                    Image(systemName: "text.justify")
                        .tag(DiffLayoutMode.unified)
                        .help("Unified view")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier("diff-layout-picker")
            }
        }
        .task { appState.loadChangeTreeIfNeeded() }
    }

    /// Compact label for the commit menu: the picked commit's short SHA, or the whole branch.
    private var commitMenuLabel: String {
        if case .commit(let sha) = appState.scope {
            return appState.commits.first(where: { $0.sha == sha })?.shortSHA
                ?? String(sha.prefix(7))
        }
        return "All commits"
    }
}
