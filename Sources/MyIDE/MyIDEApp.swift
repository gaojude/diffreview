import Foundation
import SwiftUI
import AppKit
import MyIDECore

@main
struct MyIDEApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var session: AppSession

    @MainActor
    init() {
        if CommandLine.arguments.contains("--comments-pane-self-test") {
            Self.runCommentsPaneSelfTest()
            Foundation.exit(0)
        }

        if CommandLine.arguments.contains("--pr-probe") {
            Self.runPullRequestProbe()
            Foundation.exit(0)
        }

        if CommandLine.arguments.contains("--project-tabs-self-test") {
            Self.runProjectTabsSelfTest()
            Foundation.exit(0)
        }

        let initialRootURLs = Self.rootURLArguments()
        let session = AppSession(initialRootURLs: initialRootURLs)
        _session = StateObject(wrappedValue: session)
        // Registered synchronously so folders arriving as open-events (the `diffreview` shim
        // targets the running instance) always find the session, even before the window exists.
        ProjectWindowController.shared.register(session: session)
        DispatchQueue.main.async {
            ProjectWindowController.shared.openProjectWindowIfNeeded(session: session)
        }
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                // Attaches as a new tab (the first open is just a one-tab attach).
                Button("Open Project Folder…") {
                    ProjectWindowController.shared.chooseProjectFolder(session: session)
                }
                .keyboardShortcut("o", modifiers: .command)

                Divider()

                Button("Show Next Project") {
                    session.activateAdjacentProject(forward: true)
                }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(session.projects.count < 2)

                Button("Show Previous Project") {
                    session.activateAdjacentProject(forward: false)
                }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(session.projects.count < 2)

                Button("Close Project") {
                    if let id = session.roster.activeID {
                        session.closeProject(id: id)
                    }
                }
                .disabled(session.activeProject == nil)
            }

            CommandGroup(after: .appInfo) {
                Button(cliMenuTitle) {
                    if case .failed = session.cliInstaller.state {
                        session.cliInstaller.retryInstall()
                    } else {
                        session.cliInstaller.install()
                    }
                }
                    .disabled(!canInstallCLI)
            }

            // Menu-based shortcuts fire regardless of which view has focus.
            CommandMenu("View") {
                Button("Increase Font Size") { session.activeProject?.increaseFontSize() }
                    .keyboardShortcut("+", modifiers: .command)
                    .disabled(session.activeProject == nil)
                Button("Decrease Font Size") { session.activeProject?.decreaseFontSize() }
                    .keyboardShortcut("-", modifiers: .command)
                    .disabled(session.activeProject == nil)
                Button("Actual Size") { session.activeProject?.resetFontSize() }
                    .keyboardShortcut("0", modifiers: .command)
                    .disabled(session.activeProject == nil)
            }
        }
    }

    private var canInstallCLI: Bool {
        if case .available = session.cliInstaller.state { return true }
        if case .failed = session.cliInstaller.state { return true }
        return false
    }

    private var cliMenuTitle: String {
        if case .available(let existingCommand) = session.cliInstaller.state, existingCommand {
            return "Replace diffreview Command Line Tool…"
        }
        if case .installed = session.cliInstaller.state {
            return "diffreview Command Line Tool Installed"
        }
        if case .failed = session.cliInstaller.state {
            return "Retry diffreview Command Line Tool Installation…"
        }
        return "Install diffreview Command Line Tool…"
    }

    /// Headless probe for branch→PR detection: prints what the toolbar PR button would show
    /// for a directory, without opening a window. Run via `MyIDE --pr-probe /path/to/repo`.
    /// Needs `gh` and its login like the real feature — a manual check, not part of
    /// selftest.sh (which must stay network-free).
    @MainActor
    private static func runPullRequestProbe() {
        guard let flagIndex = CommandLine.arguments.firstIndex(of: "--pr-probe"),
              flagIndex + 1 < CommandLine.arguments.count else {
            FileHandle.standardError.write(Data("usage: MyIDE --pr-probe <directory>\n".utf8))
            Foundation.exit(2)
        }
        let directory = URL(fileURLWithPath: CommandLine.arguments[flagIndex + 1], isDirectory: true)
        guard let pullRequest = GitHubPullRequestLocator.detect(in: directory) else {
            print("no PR detected for \(directory.path)")
            return
        }
        print("PR #\(pullRequest.number) state=\(pullRequest.state) draft=\(pullRequest.isDraft)")
        print("title: \(pullRequest.title)")
        print("url: \(pullRequest.url.absoluteString)")
        print("button: \(RootView.pullRequestLabel(pullRequest))")
    }

    /// Headless harness for the multi-project window: drives the real `AppSession` through
    /// attach → re-attach → switch → close against temp directories, and lays out the tab
    /// strip in an `NSHostingView` — no window, no Accessibility permission. Run via
    /// `MyIDE --project-tabs-self-test`; exits non-zero on failure.
    @MainActor
    private static func runProjectTabsSelfTest() {
        func fail(_ message: String, code: Int32) -> Never {
            FileHandle.standardError.write(Data((message + "\n").utf8))
            Foundation.exit(code)
        }

        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("myide-project-tabs-\(ProcessInfo.processInfo.processIdentifier)")
        let dirA = base.appendingPathComponent("alpha", isDirectory: true)
        let dirB = base.appendingPathComponent("beta", isDirectory: true)
        let fileC = base.appendingPathComponent("not-a-directory.txt", isDirectory: false)
        do {
            try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: fileC)
        } catch {
            fail("project tabs: fixture setup failed: \(error)", code: 2)
        }
        defer { try? FileManager.default.removeItem(at: base) }

        let session = AppSession(initialRootURLs: [dirA])
        guard session.projects.count == 1, session.activeProject?.rootURL.path == dirA.resolvingSymlinksInPath().path else {
            fail("project tabs: initial attach failed", code: 3)
        }

        session.attachProject(dirB)
        guard session.projects.count == 2, session.activeProject?.displayName == "beta" else {
            fail("project tabs: second attach did not add and activate", code: 4)
        }

        session.attachProject(dirA) // re-attach switches, never duplicates
        guard session.projects.count == 2, session.activeProject?.displayName == "alpha" else {
            fail("project tabs: re-attach duplicated or failed to activate", code: 5)
        }

        // The open-event path must drop non-directories and attach the rest.
        ProjectWindowController.shared.register(session: session)
        ProjectWindowController.shared.attachProjects(from: [fileC])
        guard session.projects.count == 2 else {
            fail("project tabs: open-event attached a non-directory", code: 6)
        }

        session.activateAdjacentProject(forward: true)
        guard session.activeProject?.displayName == "beta" else {
            fail("project tabs: next-project switch failed", code: 7)
        }

        let host = NSHostingView(rootView: ProjectTabStrip(session: session, attachProject: {}))
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 40)
        host.layoutSubtreeIfNeeded()
        guard host.fittingSize.height > 0 else {
            fail("project tabs: strip has no visible layout", code: 8)
        }

        guard let activeID = session.roster.activeID else {
            fail("project tabs: no active project to close", code: 9)
        }
        session.closeProject(id: activeID)
        guard session.projects.count == 1, session.activeProject?.displayName == "alpha" else {
            fail("project tabs: closing the active project did not reveal its neighbor", code: 10)
        }
        session.closeProject(id: session.roster.activeID ?? "")
        guard session.projects.isEmpty, session.activeProject == nil else {
            fail("project tabs: closing the last project did not empty the window", code: 11)
        }

        print("project tabs ok strip=\(Int(host.fittingSize.width))x\(Int(host.fittingSize.height))")
    }

    /// Headless harness for the review-comments flow: drives the real controller through
    /// draft → commit → copy and lays out the pane, without needing a window or Accessibility
    /// permission. Run via `MyIDE --comments-pane-self-test`; exits non-zero on failure.
    @MainActor
    private static func runCommentsPaneSelfTest() {
        func fail(_ message: String, code: Int32) -> Never {
            FileHandle.standardError.write(Data((message + "\n").utf8))
            Foundation.exit(code)
        }

        let controller = ReviewCommentsController()
        controller.beginDraft(CommentDraft(
            filePath: "src/main.ts",
            origin: .diff,
            startLine: 2,
            endLine: 2,
            codeText: "+greet"
        ))
        guard controller.draft != nil else {
            fail("comments pane: draft did not start", code: 2)
        }

        controller.draftText = "   " // whitespace only must not commit
        guard controller.commitDraft() == nil, controller.draft != nil else {
            fail("comments pane: empty comment was accepted", code: 3)
        }

        controller.draftText = "Give this a doc comment."
        guard let committed = controller.commitDraft(),
              controller.comments.count == 1,
              controller.draft == nil,
              controller.selectedCommentID == committed.id else {
            fail("comments pane: commit did not produce a selected comment", code: 4)
        }

        // Exercise the clipboard export, then put the user's clipboard back.
        let previousClipboard = NSPasteboard.general.string(forType: .string)
        controller.copyAllToPasteboard()
        let copied = NSPasteboard.general.string(forType: .string) ?? ""
        if let previousClipboard {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(previousClipboard, forType: .string)
        }
        guard copied.contains("src/main.ts"),
              copied.contains("+greet"),
              copied.contains("Give this a doc comment.") else {
            fail("comments pane: clipboard export missing content", code: 5)
        }

        let host = NSHostingView(rootView: CommentsPaneView(controller: controller, fontSize: FontSizes.default))
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 520)
        host.layoutSubtreeIfNeeded()
        guard host.fittingSize.width > 0, host.fittingSize.height > 0 else {
            fail("comments pane: no visible layout", code: 6)
        }

        controller.delete(committed.id)
        guard controller.comments.isEmpty, controller.selectedCommentID == nil else {
            fail("comments pane: delete did not clear state", code: 7)
        }

        print("comments pane ok size=\(Int(host.fittingSize.width))x\(Int(host.fittingSize.height))")
    }

    private static func rootURLArguments() -> [URL] {
        // Direct binary launches (dev, e2e) pass absolute directories as argv; each becomes
        // an attached project. The packaged `diffreview` shim sends folders as open-events
        // instead (see AppDelegate), so a running instance gains tabs rather than a second
        // window. A Finder launch has neither and falls through to the welcome screen.
        let cwd = FileManager.default.currentDirectoryPath
        return FileSystem.resolveRootDirectoryArguments(
            arguments: CommandLine.arguments,
            currentDirectory: cwd
        )
    }

}

/// Keeps the packaged app behaving like a normal foreground Mac app.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        ProjectWindowController.shared.revealProjectWindow(retries: 8)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        ProjectWindowController.shared.revealProjectWindow(retries: 2)
    }

    /// Folders sent by LaunchServices — the `diffreview` shim (`open -a … dir…`), a drop on
    /// the Dock icon, or Finder's Open With. Each attaches to the existing window as a tab;
    /// this is what makes a second `diffreview` invocation join the running review instead
    /// of spawning another window.
    func application(_ application: NSApplication, open urls: [URL]) {
        ProjectWindowController.shared.attachProjects(from: urls)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        ProjectWindowController.shared.revealProjectWindow(retries: 8)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        NSLog("MyIDE lifecycle: last window closed — terminating")
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSLog("MyIDE lifecycle: applicationWillTerminate (windows=%d)", NSApp.windows.count)
    }
}

/// Creates and reveals the project window explicitly. The app is packaged from a SwiftPM
/// executable target, and the SwiftUI scene lifecycle can launch without materializing a
/// visible window in that setup.
@MainActor
final class ProjectWindowController: NSObject, NSWindowDelegate {
    static let shared = ProjectWindowController()

    private static let projectWindowStyleMask: NSWindow.StyleMask = [
        .titled,
        .closable,
        .miniaturizable,
        .resizable,
        .fullSizeContentView,
    ]

    private var projectWindow: NSWindow?
    /// The session open-events attach into. Weakly held: the SwiftUI `App` owns it.
    private weak var session: AppSession?

    func register(session: AppSession) {
        self.session = session
    }

    /// Attaches folders arriving as open-events (CLI shim, Dock drop). Non-directories are
    /// ignored — the window only ever holds project roots.
    func attachProjects(from urls: [URL]) {
        guard let session else { return }
        let directories = urls.filter { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
        guard !directories.isEmpty else { return }
        session.attachProjects(directories)
        NSLog(
            "MyIDE lifecycle: open-event attached %d folder(s), window now holds %d project(s)",
            directories.count,
            session.projects.count
        )
        updateRepresentedProject(session.activeProject?.rootURL)
        revealProjectWindow(retries: 2)
    }

    /// Points the window's proxy icon at the project currently showing.
    func updateRepresentedProject(_ rootURL: URL?) {
        projectWindow?.representedURL = rootURL
    }

    func openProjectWindowIfNeeded(session: AppSession) {
        guard projectWindow == nil else {
            revealProjectWindow(retries: 2)
            return
        }

        let content = AppRootView(session: session) { [weak session] in
            guard let session else { return }
            ProjectWindowController.shared.chooseProjectFolder(session: session)
        }
            .frame(minWidth: 1_060, minHeight: 520)

        let window = NSWindow(
            contentRect: Self.initialWindowContentRect(),
            styleMask: Self.projectWindowStyleMask,
            backing: .buffered,
            defer: false
        )
        window.title = "DiffReview"
        window.representedURL = session.activeProject?.rootURL
        window.minSize = NSSize(width: 1_060, height: 520)
        window.toolbarStyle = .unified
        let hosting = NSHostingController(rootView: content)
        // The window is created manually (not by a SwiftUI scene), so the root view's
        // `.toolbar`/`.navigationTitle` need explicit bridging onto the NSWindow.
        hosting.sceneBridgingOptions = [.toolbars, .title]
        window.contentViewController = hosting
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrame(Self.initialWindowFrame(), display: false)

        projectWindow = window
        revealProjectWindow(retries: 8)
    }

    func chooseProjectFolder(session: AppSession) {
        let panel = NSOpenPanel()
        panel.title = "Open Project Folder"
        panel.message = "Choose Git projects to review in DiffReview. Each attaches as a tab."
        panel.prompt = "Open Project"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = true
        panel.directoryURL = session.activeProject?.rootURL

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self, weak session] response in
            guard response == .OK, !panel.urls.isEmpty, let session else { return }
            session.attachProjects(panel.urls)
            self?.projectWindow?.representedURL = session.activeProject?.rootURL
            self?.projectWindow?.title = "DiffReview"
            self?.revealProjectWindow(retries: 2)
        }

        if let projectWindow {
            panel.beginSheetModal(for: projectWindow, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }

    private static func initialWindowContentRect() -> NSRect {
        let fallbackFrame = NSRect(x: 0, y: 0, width: 1_280, height: 760)
        guard let screen = NSScreen.main else { return fallbackFrame }

        return NSWindow.contentRect(
            forFrameRect: screen.visibleFrame,
            styleMask: Self.projectWindowStyleMask
        )
    }

    private static func initialWindowFrame() -> NSRect {
        NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1_280, height: 760)
    }

    func revealProjectWindow(retries: Int) {
        DispatchQueue.main.async { [weak self] in
            self?.revealProjectWindowNow(retriesRemaining: retries)
        }
    }

    private func revealProjectWindowNow(retriesRemaining: Int) {
        NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)

        if let window = NSApp.windows.first(where: { $0.canBecomeKey }) {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        NSApp.activate(ignoringOtherApps: true)

        guard retriesRemaining > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
            self?.revealProjectWindowNow(retriesRemaining: retriesRemaining - 1)
        }
    }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === projectWindow {
            NSLog("MyIDE lifecycle: project window closing")
            projectWindow = nil
        }
    }
}
