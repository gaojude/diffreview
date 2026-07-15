import AppKit
import Foundation
import MarginCore
import SwiftUI

/// Margin — review an agent's reply the way DiffReview reviews a branch. The window is the
/// reply; select any passage (character-granular, not just lines), press ⌘K, and the
/// comments collect in a pane whose Copy button emits one prompt-ready block. Reviews
/// persist per content hash and the latest one is pointed at by `last-review.json`, so an
/// agent can also collect the comments without the clipboard.
@main
struct MarginApp: App {
    @NSApplicationDelegateAdaptor(MarginAppDelegate.self) private var delegate
    @StateObject private var session: MarginSession

    @MainActor
    init() {
        if CommandLine.arguments.contains("--prose-review-self-test") {
            Self.runProseReviewSelfTest()
            Foundation.exit(0)
        }

        let session = MarginSession()
        _session = StateObject(wrappedValue: session)
        MarginWindowController.shared.register(session: session)
        if let fileURL = Self.fileArguments().last {
            session.open(fileURL: fileURL)
        }
        DispatchQueue.main.async {
            MarginWindowController.shared.openWindowIfNeeded(session: session)
        }
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Reply…") {
                    MarginWindowController.shared.chooseFile(session: session)
                }
                .keyboardShortcut("o", modifiers: .command)
            }

            // Menu-based shortcuts fire regardless of which view has focus.
            CommandMenu("Review") {
                Button("Comment on Selection") {
                    session.beginDraftFromSelection()
                }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(!session.canComment)

                Button("Copy Review") {
                    session.review.copyAllToPasteboard()
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(!session.review.canCopy)
            }

            CommandMenu("View") {
                Button("Increase Font Size") { session.increaseFontSize() }
                    .keyboardShortcut("+", modifiers: .command)
                Button("Decrease Font Size") { session.decreaseFontSize() }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Actual Size") { session.resetFontSize() }
                    .keyboardShortcut("0", modifiers: .command)
            }
        }
    }

    /// Direct binary launches (dev, the `margin` shim's `--args`) pass absolute file paths
    /// as argv. Open-events cover the packaged path (see the delegate).
    private static func fileArguments() -> [URL] {
        CommandLine.arguments.dropFirst().compactMap { argument in
            guard !argument.hasPrefix("-") else { return nil }
            let url = URL(fileURLWithPath: argument)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { return nil }
            return url
        }
    }

    /// Headless harness for the prose-review flow: drives the real controller through
    /// draft → commit → copy and lays out the pane, without a window or Accessibility
    /// permission. Run via `Margin --prose-review-self-test`; exits non-zero on failure.
    @MainActor
    private static func runProseReviewSelfTest() {
        func fail(_ message: String, code: Int32) -> Never {
            FileHandle.standardError.write(Data((message + "\n").utf8))
            Foundation.exit(code)
        }

        let text = "The quick brown fox\njumps over the lazy dog.\n"
        guard let selection = ProseGeometry.selection(
            in: text,
            utf16Range: NSRange(location: 4, length: 11) // "quick brown"
        ) else {
            fail("prose review: selection did not resolve", code: 2)
        }
        guard selection.text == "quick brown", selection.startLine == 1, selection.endLine == 1 else {
            fail("prose review: selection resolved wrong (\(selection.text))", code: 2)
        }

        let controller = MarginReviewController()
        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("margin-selftest-\(ProcessInfo.processInfo.processIdentifier)")
        defer { try? FileManager.default.removeItem(at: storageRoot) }
        controller.configurePersistence(
            store: ProseReviewStore(contentText: text, sourcePath: nil, storageRoot: storageRoot),
            documentTitle: "fixture"
        )

        controller.beginDraft(selection)
        controller.draftText = "   " // whitespace only must not commit
        guard controller.commitDraft() == nil, controller.draft != nil else {
            fail("prose review: empty comment was accepted", code: 3)
        }

        controller.draftText = "Name the animal precisely."
        guard let committed = controller.commitDraft(),
              controller.comments.count == 1,
              controller.selectedCommentID == committed.id else {
            fail("prose review: commit did not produce a selected comment", code: 4)
        }

        // Exercise the clipboard export, then put the user's clipboard back.
        let previousClipboard = NSPasteboard.general.string(forType: .string)
        controller.copyAllToPasteboard()
        let copied = NSPasteboard.general.string(forType: .string) ?? ""
        if let previousClipboard {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(previousClipboard, forType: .string)
        }
        guard copied.contains("quick brown"),
              copied.contains("Name the animal precisely."),
              copied.contains("line 1") else {
            fail("prose review: clipboard export missing content", code: 5)
        }

        let host = NSHostingView(rootView: MarginCommentsPane(controller: controller, fontSize: 13))
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 520)
        host.layoutSubtreeIfNeeded()
        guard host.fittingSize.width > 0, host.fittingSize.height > 0 else {
            fail("prose review: pane has no visible layout", code: 6)
        }

        controller.delete(committed.id)
        guard controller.comments.isEmpty else {
            fail("prose review: delete did not clear state", code: 7)
        }

        print("prose review ok size=\(Int(host.fittingSize.width))x\(Int(host.fittingSize.height))")
    }
}

/// Keeps the packaged app behaving like a normal foreground Mac app, and routes files sent
/// by LaunchServices (the `margin` shim, Finder's Open With, Dock drops) into the session.
@MainActor
final class MarginAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        MarginWindowController.shared.revealWindow(retries: 8)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        MarginWindowController.shared.revealWindow(retries: 2)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MarginWindowController.shared.openFiles(urls)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MarginWindowController.shared.revealWindow(retries: 8)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

/// Creates and reveals the review window explicitly — the app is packaged from a SwiftPM
/// executable target, and the SwiftUI scene lifecycle can launch without materializing a
/// visible window in that setup (same arrangement as DiffReview's ProjectWindowController).
@MainActor
final class MarginWindowController: NSObject, NSWindowDelegate {
    static let shared = MarginWindowController()

    private static let windowStyleMask: NSWindow.StyleMask = [
        .titled,
        .closable,
        .miniaturizable,
        .resizable,
        .fullSizeContentView,
    ]

    private var window: NSWindow?
    /// Weakly held: the SwiftUI `App` owns it.
    private weak var session: MarginSession?

    func register(session: MarginSession) {
        self.session = session
    }

    func openFiles(_ urls: [URL]) {
        guard let session else { return }
        let files = urls.filter { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                && !isDirectory.boolValue
        }
        guard let file = files.last else { return }
        session.open(fileURL: file)
        window?.representedURL = file
        revealWindow(retries: 2)
    }

    func openWindowIfNeeded(session: MarginSession) {
        guard window == nil else {
            revealWindow(retries: 2)
            return
        }

        let content = MarginRootView(session: session)
            .frame(minWidth: 900, minHeight: 480)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_180, height: 760),
            styleMask: Self.windowStyleMask,
            backing: .buffered,
            defer: false
        )
        window.title = "Margin"
        window.representedURL = session.document?.sourceURL
        window.minSize = NSSize(width: 900, height: 480)
        window.toolbarStyle = .unified
        let hosting = NSHostingController(rootView: content)
        // The window is created manually (not by a SwiftUI scene), so the root view's
        // `.navigationTitle` needs explicit bridging onto the NSWindow.
        hosting.sceneBridgingOptions = [.toolbars, .title]
        window.contentViewController = hosting
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        self.window = window
        revealWindow(retries: 8)
    }

    func chooseFile(session: MarginSession) {
        let panel = NSOpenPanel()
        panel.title = "Open Reply"
        panel.message = "Choose a markdown or text file to review in Margin."
        panel.prompt = "Open"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self, weak session] response in
            guard response == .OK, let url = panel.urls.first, let session else { return }
            session.open(fileURL: url)
            self?.window?.representedURL = url
            self?.revealWindow(retries: 2)
        }

        if let window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }

    func revealWindow(retries: Int) {
        DispatchQueue.main.async { [weak self] in
            self?.revealWindowNow(retriesRemaining: retries)
        }
    }

    private func revealWindowNow(retriesRemaining: Int) {
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
            self?.revealWindowNow(retriesRemaining: retriesRemaining - 1)
        }
    }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === window {
            window = nil
        }
    }
}
