import Foundation
import SwiftUI
import AppKit
import MyIDECore

@main
struct MyIDEApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var appState: AppState

    @MainActor
    init() {
        if CommandLine.arguments.contains("--comments-pane-self-test") {
            Self.runCommentsPaneSelfTest()
            Foundation.exit(0)
        }

        let rootURL = Self.rootURL()
        let appState = AppState(rootURL: rootURL)
        _appState = StateObject(wrappedValue: appState)
        DispatchQueue.main.async {
            ProjectWindowController.shared.openProjectWindowIfNeeded(rootURL: rootURL, appState: appState)
        }
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .newItem) { }

            // Menu-based shortcuts fire regardless of which view has focus.
            CommandMenu("View") {
                Button("Increase Font Size") { appState.increaseFontSize() }
                    .keyboardShortcut("+", modifiers: .command)
                Button("Decrease Font Size") { appState.decreaseFontSize() }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Actual Size") { appState.resetFontSize() }
                    .keyboardShortcut("0", modifiers: .command)
            }
        }
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

    private static func rootURL() -> URL {
        // The `my-ide` shim passes an absolute directory as argv[1]; fall back to the
        // process working directory (and to that dir even if resolution fails).
        let cwd = FileManager.default.currentDirectoryPath
        return FileSystem.resolveRootDirectory(
            arguments: CommandLine.arguments,
            currentDirectory: cwd
        ) ?? URL(fileURLWithPath: cwd, isDirectory: true)
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

    func openProjectWindowIfNeeded(rootURL: URL, appState: AppState) {
        guard projectWindow == nil else {
            revealProjectWindow(retries: 2)
            return
        }

        let content = RootView(appState: appState)
            .frame(minWidth: 1_060, minHeight: 520)

        let window = NSWindow(
            contentRect: Self.initialWindowContentRect(),
            styleMask: Self.projectWindowStyleMask,
            backing: .buffered,
            defer: false
        )
        window.title = "MyIDE"
        window.representedURL = rootURL
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
