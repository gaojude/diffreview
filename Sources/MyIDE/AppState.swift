import Foundation
import Combine
import MyIDECore

/// Shared observable state for a window: the opened root folder, branch change tree, and selection.
@MainActor
final class AppState: ObservableObject {
    enum ChangeTreeState {
        case loading
        case notRepository(String)
        case loaded(GitChangeContext)
    }

    /// The directory the app was opened on (immutable for the window's lifetime).
    let rootURL: URL

    /// Currently selected file in the sidebar. Drives the content pane.
    @Published var selectedFileURL: URL?

    /// Sidebar tree scoped to the active branch/worktree change set.
    @Published private(set) var sidebarRoot: FileNode

    /// Metadata for the branch/base currently represented by the sidebar.
    @Published private(set) var changeTreeState: ChangeTreeState = .loading

    /// Durable user configuration. Adjusted via commands and persisted as a single settings blob.
    @Published private(set) var configuration: AppConfiguration {
        didSet { configurationStore.save(configuration) }
    }

    var fontSize: CGFloat { configuration.fontSize }
    var navigationTitle: String { "Branch Changes" }

    private let configurationStore: AppConfigurationStore
    private var hasLoadedChangeTree = false

    init(rootURL: URL, configurationStore: AppConfigurationStore = .standard()) {
        self.rootURL = rootURL
        self.configurationStore = configurationStore
        self.configuration = configurationStore.load()
        self.sidebarRoot = FileNode.emptyRoot(rootURL)
    }

    func loadChangeTreeIfNeeded() {
        guard !hasLoadedChangeTree else { return }
        hasLoadedChangeTree = true
        changeTreeState = .loading

        let rootURL = self.rootURL
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) {
                GitChangeSet.load(for: rootURL)
            }.value
            apply(result)
        }
    }

    private func apply(_ result: GitChangeLoadResult) {
        switch result {
        case .repository(let context):
            changeTreeState = .loaded(context)
            sidebarRoot = FileNode.changeRoot(rootURL, files: context.files)
            selectedFileURL = firstPreviewableFile(in: context)
        case .notRepository(let message):
            changeTreeState = .notRepository(message)
            sidebarRoot = FileNode.emptyRoot(rootURL)
            selectedFileURL = nil
        }
    }

    private func firstPreviewableFile(in context: GitChangeContext) -> URL? {
        context.files.first(where: { file in
            if case .deleted = file.status { return false }
            return true
        })?.url ?? context.files.first?.url
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
