import Foundation
import Combine
import MyIDECore

/// Shared observable state for a window: the opened root folder and its branch change set.
@MainActor
final class AppState: ObservableObject {
    enum ChangeTreeState {
        case loading
        case notRepository(String)
        case loaded(GitChangeContext)
    }

    /// The directory the app was opened on (immutable for the window's lifetime).
    let rootURL: URL

    /// Which diff this window shows: the whole branch (default) or one commit picked from
    /// the commit menu. Changing it reloads the change tree.
    @Published private(set) var scope: GitDiffScope = .branch

    /// The branch's commits (newest first), offered by the toolbar commit picker.
    @Published private(set) var commits: [GitCommitSummary] = []

    /// Metadata for the branch/base currently shown by the content pane.
    @Published private(set) var changeTreeState: ChangeTreeState = .loading

    /// Durable user configuration. Adjusted via commands and persisted as a single settings blob.
    @Published private(set) var configuration: AppConfiguration {
        didSet { configurationStore.save(configuration) }
    }

    var fontSize: CGFloat { configuration.fontSize }
    var diffLayout: DiffLayoutMode { configuration.diffLayout }

    /// The window title doubles as the scope marker: it names the reviewed commit
    /// (`abc1234  subject`) or base ref, so what the document diffs is always visible.
    var navigationTitle: String {
        switch scope {
        case .branch:
            return "Branch Changes"
        case .since(let ref):
            return "Changes Since \(ref)"
        case .commit(let ref):
            if case .loaded(let context) = changeTreeState, let summary = context.commitSummary {
                return summary
            }
            if let commit = commits.first(where: { $0.sha == ref }) {
                return "\(commit.shortSHA)  \(commit.subject)"
            }
            return "Commit \(ref)"
        }
    }

    func setDiffLayout(_ layout: DiffLayoutMode) {
        updateConfiguration { $0.diffLayout = layout }
    }

    private let configurationStore: AppConfigurationStore
    private var hasLoadedChangeTree = false
    /// Guards against a slow earlier load landing after a newer scope selection.
    private var loadGeneration = 0

    init(rootURL: URL, configurationStore: AppConfigurationStore = .standard()) {
        self.rootURL = rootURL
        self.configurationStore = configurationStore
        self.configuration = configurationStore.load()
    }

    func loadChangeTreeIfNeeded() {
        guard !hasLoadedChangeTree else { return }
        hasLoadedChangeTree = true
        reloadChangeTree()

        let rootURL = self.rootURL
        Task { @MainActor in
            let listed = await Task.detached(priority: .userInitiated) {
                GitChangeSet.listCommits(for: rootURL)
            }.value
            commits = listed
        }
    }

    /// Switches the window between the whole-branch view and a single commit from the picker.
    func select(scope newScope: GitDiffScope) {
        guard newScope != scope else { return }
        scope = newScope
        reloadChangeTree()
    }

    private func reloadChangeTree() {
        changeTreeState = .loading
        loadGeneration += 1
        let generation = loadGeneration

        let rootURL = self.rootURL
        let scope = self.scope
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) {
                GitChangeSet.load(for: rootURL, scope: scope)
            }.value
            guard generation == loadGeneration else { return }
            apply(result)
        }
    }

    private func apply(_ result: GitChangeLoadResult) {
        switch result {
        case .repository(let context):
            changeTreeState = .loaded(context)
        case .notRepository(let message):
            changeTreeState = .notRepository(message)
        }
    }

    func increaseFontSize() {
        updateConfiguration { $0.fontSize = FontSizes.clamp($0.fontSize + FontSizes.step) }
    }

    func decreaseFontSize() {
        updateConfiguration { $0.fontSize = FontSizes.clamp($0.fontSize - FontSizes.step) }
    }

    func resetFontSize() {
        updateConfiguration { $0.fontSize = FontSizes.default }
    }

    private func updateConfiguration(_ update: (inout AppConfiguration) -> Void) {
        var next = configuration
        update(&next)
        configuration = next
    }
}
