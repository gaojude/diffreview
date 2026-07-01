import SwiftUI
import AppKit
import MyIDECore

@main
struct MyIDEApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var appState: AppState

    @MainActor
    init() {
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
        true
    }
}

/// Creates and reveals the project window explicitly. The app is packaged from a SwiftPM
/// executable target, and the SwiftUI scene lifecycle can launch without materializing a
/// visible window in that setup.
@MainActor
final class ProjectWindowController: NSObject, NSWindowDelegate {
    static let shared = ProjectWindowController()

    private var projectWindow: NSWindow?

    func openProjectWindowIfNeeded(rootURL: URL, appState: AppState) {
        guard projectWindow == nil else {
            revealProjectWindow(retries: 2)
            return
        }

        let content = RootView(appState: appState)
            .frame(minWidth: 760, minHeight: 480)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "MyIDE"
        window.representedURL = rootURL
        window.minSize = NSSize(width: 760, height: 480)
        window.toolbarStyle = .unified
        window.contentViewController = NSHostingController(rootView: content)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        projectWindow = window
        revealProjectWindow(retries: 8)
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
            projectWindow = nil
        }
    }
}
