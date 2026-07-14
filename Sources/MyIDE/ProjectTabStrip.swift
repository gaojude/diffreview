import SwiftUI
import MyIDECore

/// The row of attached projects across the top of the window — one tab per PR/worktree.
/// Only rendered when at least two projects are attached, so the single-project window
/// looks exactly as before. Each tab names the project's folder and, once `gh` resolves
/// it, the PR number; the trailing ＋ attaches another folder.
struct ProjectTabStrip: View {
    @ObservedObject var session: AppSession
    /// Opens the folder chooser (same panel as ⌘O); the chosen folder attaches as a new tab.
    let attachProject: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(session.projects) { project in
                        ProjectTabView(
                            project: project,
                            isActive: project.id == session.roster.activeID,
                            activate: { session.activateProject(id: project.id) },
                            close: { session.closeProject(id: project.id) }
                        )
                    }
                }
                .padding(.horizontal, 8)
            }

            Button(action: attachProject) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("Attach another project to this window")
            .accessibilityIdentifier("attach-project")
            .padding(.trailing, 8)
        }
        .frame(height: 34)
        .background(.bar)
        .accessibilityIdentifier("project-tab-strip")
    }
}

/// One tab: folder name + PR label, with a close button. Observes its project directly so
/// the label updates in place when PR detection lands for a background tab.
private struct ProjectTabView: View {
    @ObservedObject var project: AppState
    let isActive: Bool
    let activate: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: activate) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.pull")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(project.pullRequest == nil ? .tertiary : .secondary)
                    Text(title)
                        .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)

            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Close \(project.displayName)")
            .accessibilityIdentifier("close-project-tab")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isActive ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear))
        )
        .foregroundStyle(isActive ? .primary : .secondary)
        .help(tooltip)
        .accessibilityIdentifier("project-tab")
    }

    /// "folder-name · #123 · Draft" once the PR resolves; just the folder name until then.
    private var title: String {
        guard let pullRequest = project.pullRequest else { return project.displayName }
        return "\(project.displayName) · \(RootView.pullRequestLabel(pullRequest))"
    }

    private var tooltip: String {
        guard let pullRequest = project.pullRequest else { return project.rootURL.path }
        return "\(project.rootURL.path)\nPR #\(pullRequest.number) — \(pullRequest.title)"
    }
}
