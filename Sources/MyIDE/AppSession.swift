import Combine
import Foundation

/// App-level state that exists before a project has been selected and survives when the user
/// switches projects. Project-specific state remains isolated in a fresh `AppState`.
@MainActor
final class AppSession: ObservableObject {
    @Published private(set) var project: AppState?
    let cliInstaller = CLIInstaller()
    private var cancellables: Set<AnyCancellable> = []

    init(initialRootURL: URL?) {
        if let initialRootURL {
            project = AppState(rootURL: initialRootURL)
        }
        cliInstaller.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    func openProject(_ rootURL: URL) {
        let resolved = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        project = AppState(rootURL: resolved)
    }
}
