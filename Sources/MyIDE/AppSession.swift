import Combine
import Foundation
import MyIDECore

/// App-level state that exists before a project has been selected and survives when the user
/// switches projects. The window holds a roster of attached projects (one per PR/worktree);
/// each project's state stays isolated in its own `AppState` so switching tabs never mixes
/// diffs, scopes, or reviews.
@MainActor
final class AppSession: ObservableObject {
    /// Attach order + active selection. `AppState`s are kept alongside, keyed by roster id,
    /// so the roster stays the single source of truth for which projects exist.
    @Published private(set) var roster = ProjectRoster()
    private var projectsByID: [String: AppState] = [:]

    let cliInstaller = CLIInstaller()
    private let recentsStore: RecentProjectsStore
    private var cancellables: Set<AnyCancellable> = []

    /// What the welcome screen lists: every project root ever attached, most recent first,
    /// pruned of directories that no longer exist.
    @Published private(set) var recentProjects: [RecentProject] = []

    /// Attached projects in tab order.
    var projects: [AppState] { roster.ids.compactMap { projectsByID[$0] } }

    /// The project the window is currently showing, `nil` before anything is attached.
    var activeProject: AppState? { roster.activeID.flatMap { projectsByID[$0] } }

    init(initialRootURLs: [URL] = [], recentsStore: RecentProjectsStore = RecentProjectsStore()) {
        self.recentsStore = recentsStore
        self.recentProjects = recentsStore.load()
        attachProjects(initialRootURLs)
        cliInstaller.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    func attachProjects(_ rootURLs: [URL]) {
        for rootURL in rootURLs { attachProject(rootURL) }
    }

    /// Attaches a project and shows it. Re-attaching an already-open root (running
    /// `diffreview` on it again) just switches to the existing tab — its scope, comments,
    /// and reading position are untouched.
    func attachProject(_ rootURL: URL) {
        let resolved = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        recordRecent(resolved.path)
        guard roster.attach(resolved.path) else { return }
        let project = AppState(rootURL: resolved)
        projectsByID[resolved.path] = project
        // Load eagerly (all async, off-main) so an attached-but-not-yet-visited tab already
        // shows its PR number and has its diff ready when switched to.
        project.loadChangeTreeIfNeeded()
    }

    /// Every attach freshens the recents list — including re-attaches, which are the user
    /// coming back to a project. Saved off-main; a lost write costs one recents entry.
    private func recordRecent(_ path: String) {
        recentProjects = RecentProjects.adding(path, to: recentProjects)
        let snapshot = recentProjects
        let store = recentsStore
        Task.detached(priority: .utility) {
            store.save(snapshot)
        }
    }

    func activateProject(id: String) {
        roster.activate(id)
    }

    func activateAdjacentProject(forward: Bool) {
        roster.activateAdjacent(forward: forward)
    }

    /// Detaches a project from the window. Its review comments and reading position are
    /// disk-persisted per repo+branch, so closing a tab loses nothing.
    func closeProject(id: String) {
        roster.close(id)
        projectsByID[id] = nil
    }
}
