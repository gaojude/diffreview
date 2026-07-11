import AppKit
import SwiftUI

/// Creates and reveals the Assistant window, mirroring `ProjectWindowController`:
/// the app's SwiftUI scene is deliberately inert, so windows are managed with
/// AppKit directly. One workspace (and one harness session) per app run.
@MainActor
final class AgentWorkspaceWindowController: NSObject, NSWindowDelegate {
    static let shared = AgentWorkspaceWindowController()

    private var window: NSWindow?
    private var workspaceController: AgentWorkspaceController?

    func openAgentWorkspace() {
        if let window {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = AgentWorkspaceController()
        let content = AgentWorkspaceView(controller: controller)
            .frame(minWidth: 320, minHeight: 400)

        // Deliberately small: a plugin-style chat companion, not an IDE pane —
        // the real browser window is where the action shows.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Assistant"
        window.minSize = NSSize(width: 320, height: 400)
        window.toolbarStyle = .unified
        window.contentViewController = NSHostingController(rootView: content)
        window.isReleasedWhenClosed = false
        window.delegate = self
        // Light theme throughout, regardless of the system appearance.
        window.appearance = NSAppearance(named: .aqua)
        // Float above other apps — this is a companion to the browser it's
        // driving, so it should stay visible over the Chrome window, and
        // follow the user across Spaces.
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.center()

        self.window = window
        self.workspaceController = controller

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        // Shut the harness down with the window; a fresh open gets a fresh session.
        workspaceController?.stop()
        workspaceController = nil
        window = nil
    }
}
