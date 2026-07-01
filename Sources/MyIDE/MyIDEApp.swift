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
        if CommandLine.arguments.contains("--selection-chat-pane-self-test") {
            Self.runSelectionChatPaneSelfTest()
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

    private static func rootURL() -> URL {
        // The `my-ide` shim passes an absolute directory as argv[1]; fall back to the
        // process working directory (and to that dir even if resolution fails).
        let cwd = FileManager.default.currentDirectoryPath
        return FileSystem.resolveRootDirectory(
            arguments: CommandLine.arguments,
            currentDirectory: cwd
        ) ?? URL(fileURLWithPath: cwd, isDirectory: true)
    }

    private static func runSelectionChatPaneSelfTest() {
        let chat = SelectionChatController()
        let rootURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let context = CodeSelectionContext(
            fileURL: rootURL.appendingPathComponent("src/index.ts"),
            contentKind: .source,
            startLine: 1,
            endLine: 3,
            text: "export function answer(value: number) {\n  return value * 2\n}"
        )
        chat.setContext(context: context, rootURL: rootURL)
        chat.draft = "What changed here?"
        guard chat.canSubmit else {
            writeSelfTestError("selection chat pane did not accept selected context")
            Foundation.exit(2)
        }

        let references = CodeReferenceParser.references(in: """
        See packages/next/src/client/components/router-reducer/ppr-navigations.ts:
        - `:1001-1003`
        """)
        guard references.contains(CodeReference(
            path: "packages/next/src/client/components/router-reducer/ppr-navigations.ts",
            startLine: 1001,
            endLine: 1003
        )) else {
            writeSelfTestError("selection chat code reference parser failed")
            Foundation.exit(3)
        }

        let tsxReferences = CodeReferenceParser.references(in: """
        <Link> clicks: packages/next/src/client/app-dir/link.tsx:303-313
        """)
        guard tsxReferences == [
            CodeReference(
                path: "packages/next/src/client/app-dir/link.tsx",
                startLine: 303,
                endLine: 313
            ),
        ] else {
            writeSelfTestError("selection chat tsx code reference parser failed: \(tsxReferences)")
            Foundation.exit(4)
        }

        let host = NSHostingView(rootView: SelectionChatPaneView(chat: chat, fontSize: FontSizes.default))
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 520)
        host.layoutSubtreeIfNeeded()
        guard host.fittingSize.width > 0, host.fittingSize.height > 0 else {
            writeSelfTestError("selection chat pane did not produce a visible layout")
            Foundation.exit(5)
        }

        print("selection chat pane ok size=\(Int(host.fittingSize.width))x\(Int(host.fittingSize.height))")
    }

    private static func writeSelfTestError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
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
        window.contentViewController = NSHostingController(rootView: content)
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
            projectWindow = nil
        }
    }
}
