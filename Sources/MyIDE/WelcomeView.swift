import SwiftUI
import MyIDECore

struct WelcomeView: View {
    @ObservedObject var cliInstaller: CLIInstaller
    var recentProjects: [RecentProject] = []
    let openProject: () -> Void
    var openRecent: (URL) -> Void = { _ in }

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

            if !recentProjects.isEmpty {
                recentsList
            }

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

    /// Recently opened project roots, one click from reviewing again. Stale paths are pruned
    /// at load, so every row here points at a directory that existed moments ago.
    private var recentsList: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Recent Projects")
                .font(.headline)
                .padding(.bottom, 6)
            ForEach(recentProjects, id: \.path) { recent in
                Button {
                    openRecent(URL(fileURLWithPath: recent.path, isDirectory: true))
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        Text(recent.displayName)
                            .fontWeight(.medium)
                            .lineLimit(1)
                        Text(recent.path)
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .help(recent.path)
                .accessibilityIdentifier("recent-project")
            }
        }
        .padding(14)
        .frame(maxWidth: 560, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityIdentifier("recent-projects")
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
        VStack(spacing: 0) {
            // The strip only exists once a second project is attached — a single-project
            // window keeps its familiar chrome.
            if session.projects.count > 1 {
                ProjectTabStrip(session: session, attachProject: openProject)
                Divider()
            }
            if let project = session.activeProject {
                // `.id` swaps the whole view tree per project; per-project review state
                // survives the swap because comments and reading position are disk-persisted
                // per repo+branch and reload on appearance.
                RootView(appState: project)
                    .id(project.id)
            } else {
                WelcomeView(
                    cliInstaller: session.cliInstaller,
                    recentProjects: session.recentProjects,
                    openProject: openProject,
                    openRecent: { session.attachProject($0) }
                )
            }
        }
        .onChange(of: session.roster.activeID) { _, _ in
            // Keep the window proxy icon pointing at the project being shown.
            ProjectWindowController.shared.updateRepresentedProject(session.activeProject?.rootURL)
        }
    }
}
