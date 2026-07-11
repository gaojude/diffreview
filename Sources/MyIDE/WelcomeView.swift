import SwiftUI

struct WelcomeView: View {
    @ObservedObject var cliInstaller: CLIInstaller
    let openProject: () -> Void

    var body: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 24)

            VStack(spacing: 12) {
                Image(systemName: "pencil.and.outline")
                    .font(.system(size: 48, weight: .medium))
                    .foregroundStyle(.red)
                    .accessibilityHidden(true)
                Text("Welcome to DiffReview")
                    .font(.system(size: 30, weight: .bold))
                Text("Open a Git project to review your branch changes.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            Button(action: openProject) {
                Label("Open Project Folder…", systemImage: "folder")
                    .frame(minWidth: 190)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut("o", modifiers: .command)
            .accessibilityIdentifier("welcome-open-project")

            Divider()
                .frame(maxWidth: 520)

            HStack(spacing: 16) {
                Image(systemName: "terminal")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                    .frame(width: 40)

                VStack(alignment: .leading, spacing: 5) {
                    Text("Use DiffReview from Terminal")
                        .font(.headline)
                    Text(cliDescription)
                        .foregroundStyle(cliDescriptionIsError ? Color.red : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("diffreview .")
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                cliAction
            }
            .padding(20)
            .frame(maxWidth: 560)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))

            Spacer(minLength: 24)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var cliAction: some View {
        switch cliInstaller.state {
        case .available(let existingCommand):
            Button(existingCommand ? "Replace CLI" : "Install CLI") {
                cliInstaller.install()
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("install-diffreview-cli")
        case .installed:
            Label("Installed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .installing:
            ProgressView()
                .controlSize(.small)
        case .unavailable:
            EmptyView()
        case .failed:
            Button("Try Again") { cliInstaller.retryInstall() }
                .buttonStyle(.bordered)
        }
    }

    private var cliDescription: String {
        switch cliInstaller.state {
        case .available(let existingCommand):
            return existingCommand
                ? "Replace the existing /usr/local/bin/diffreview command with this copy."
                : "Install the diffreview command in /usr/local/bin so it’s available from any project."
        case .installed:
            return "The diffreview command is installed and ready to use."
        case .installing:
            return "Installing /usr/local/bin/diffreview…"
        case .unavailable(let message), .failed(let message):
            return message
        }
    }

    private var cliDescriptionIsError: Bool {
        if case .failed = cliInstaller.state { return true }
        return false
    }
}

struct AppRootView: View {
    @ObservedObject var session: AppSession
    let openProject: () -> Void

    var body: some View {
        Group {
            if let project = session.project {
                RootView(appState: project)
                    .id(project.rootURL.path)
            } else {
                WelcomeView(cliInstaller: session.cliInstaller, openProject: openProject)
            }
        }
    }
}
