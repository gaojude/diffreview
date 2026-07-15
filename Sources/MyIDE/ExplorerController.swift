import Foundation
import SwiftUI
import AppKit
import MyIDECore

/// State for the Explorer: a navigation stack of source files, shown in a floating panel over
/// the main window. The diff underneath never moves — exploration is temporary and never
/// costs you your place in the review. Reference lists are NOT part of this stack: they show
/// as a dropdown anchored next to the ⌘-clicked symbol (see `SymbolReferencesPresentation`).
@MainActor
final class ExplorerController: ObservableObject {
    struct FileEntry: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        /// Root-relative path when the file is inside the project, else the file name.
        let displayPath: String
        var focusLineRange: ClosedRange<Int>?
        /// Top visible line captured when navigating away, restored on back.
        var savedTopLine: Int?
    }

    enum State: Equatable {
        case empty
        case loading
        case text(String)
        case message(String)
    }

    @Published private(set) var stack: [FileEntry] = []
    /// Load state for the file on top of the stack.
    @Published private(set) var state: State = .empty
    @Published private(set) var scrollRequest: CodeScrollRequest?
    /// Transient status shown in the panel header ("Resolving definition…", errors).
    @Published private(set) var status: String?
    /// References dropdown for a symbol ⌘-clicked inside the panel's file, anchored next to
    /// that symbol. Owned here so the panel view (recreated on every present) keeps it.
    @Published var referencesDropdown: SymbolReferencesPresentation?

    var current: FileEntry? { stack.last }
    var currentFileEntry: FileEntry? { stack.last }
    var canGoBack: Bool { stack.count > 1 }
    var hasContent: Bool { !stack.isEmpty }

    var panelTitle: String {
        guard let entry = stack.last else { return "Explorer" }
        return (entry.displayPath as NSString).lastPathComponent
    }

    private var currentTopLine = 1
    private var loadTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?

    func noteTopLine(_ line: Int) {
        currentTopLine = line
    }

    /// Opens a file on top of the stack. Re-opening the file already on top just moves
    /// the focus instead of growing the stack.
    func open(url: URL, displayPath: String, focus: ClosedRange<Int>?) {
        clearStatus()
        referencesDropdown = nil
        if let top = stack.last,
           top.url.standardizedFileURL.path == url.standardizedFileURL.path {
            stack[stack.count - 1] = FileEntry(
                url: top.url,
                displayPath: top.displayPath,
                focusLineRange: focus,
                savedTopLine: nil
            )
            if let focus {
                scrollRequest = CodeScrollRequest(line: max(focus.lowerBound - 3, 1))
            }
            return
        }

        rememberTopLineOnCurrent()
        stack.append(FileEntry(url: url, displayPath: displayPath, focusLineRange: focus, savedTopLine: nil))
        load(url: url, focus: focus, restoreTopLine: nil)
    }

    func goBack() {
        guard stack.count > 1 else { return }
        referencesDropdown = nil
        stack.removeLast()
        if let entry = stack.last {
            load(url: entry.url, focus: entry.focusLineRange, restoreTopLine: entry.savedTopLine)
        }
    }

    /// Clears the exploration when the panel closes, so the next journey starts fresh.
    func reset() {
        loadTask?.cancel()
        stack = []
        state = .empty
        status = nil
        referencesDropdown = nil
    }

    func showStatus(_ message: String, autoClears: Bool = true) {
        statusTask?.cancel()
        status = message
        guard autoClears else { return }
        statusTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            guard !Task.isCancelled else { return }
            status = nil
        }
    }

    func clearStatus() {
        statusTask?.cancel()
        status = nil
    }

    private func rememberTopLineOnCurrent() {
        guard let entry = stack.last else { return }
        var updated = entry
        updated.savedTopLine = currentTopLine
        stack[stack.count - 1] = updated
    }

    private func load(url: URL, focus: ClosedRange<Int>?, restoreTopLine: Int?) {
        state = .loading
        loadTask?.cancel()
        loadTask = Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) {
                FileSystem.loadForDisplay(url)
            }.value
            guard !Task.isCancelled else { return }
            switch result {
            case .text(let text):
                state = .text(text)
                if let restoreTopLine {
                    scrollRequest = CodeScrollRequest(line: restoreTopLine)
                } else if let focus {
                    scrollRequest = CodeScrollRequest(line: max(focus.lowerBound - 3, 1))
                }
            case .tooLarge(let bytes):
                let formatted = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
                state = .message("File is too large to preview (\(formatted)).")
            case .binary:
                state = .message("Binary file — not shown.")
            case .isDirectory:
                state = .message("That reference points at a folder.")
            case .unreadable(let message):
                state = .message("Can’t read file: \(message)")
            }
        }
    }
}

/// Owns the floating Explorer panel: a utility window above the main one, sized/positioned
/// persistently, closed with Esc or its close button.
@MainActor
final class ExplorerPanelController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    var onClosed: (() -> Void)?

    func present(_ content: ExplorerPanelView, title: String) {
        let panel = ensurePanel(with: content)
        panel.title = title
        if let hosting = panel.contentViewController as? NSHostingController<ExplorerPanelView> {
            hosting.rootView = content
        }
        panel.makeKeyAndOrderFront(nil)
    }

    func updateTitle(_ title: String) {
        panel?.title = title
    }

    func close() {
        panel?.close()
    }

    private func ensurePanel(with content: ExplorerPanelView) -> NSPanel {
        if let panel {
            return panel
        }
        let created = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 640),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        created.level = .floating
        created.hidesOnDeactivate = true
        created.isReleasedWhenClosed = false
        created.minSize = NSSize(width: 480, height: 320)
        created.contentViewController = NSHostingController(rootView: content)
        created.setFrameAutosaveName("MyIDEExplorerPanel")
        if created.frame.origin == .zero {
            created.center()
        }
        created.delegate = self
        panel = created
        return created
    }

    func windowWillClose(_ notification: Notification) {
        onClosed?()
    }
}

/// Lazily spawns and caches the tsserver-backed language service for the project. Discovery
/// and lookups run off the main thread; the server is recreated if it dies.
@MainActor
final class DefinitionController: ObservableObject {
    private var server: TSServer?
    private var consecutiveTimeouts = 0
    /// A crashed tsserver already respawns via `.notRunning`; a WEDGED one (alive but never
    /// answering) used to degrade every lookup to a 12s timeout until app restart. After
    /// this many timeouts in a row, the instance is presumed wedged and replaced.
    private static let timeoutsBeforeRespawn = 2

    func definition(rootURL: URL, fileURL: URL, line: Int, column: Int) async -> Result<[TSFileSpan], TSServerError> {
        guard let server = await ensureServer(rootURL: rootURL) else {
            return .failure(.toolchainNotFound(
                "TypeScript service not found — needs node and typescript (npm i -D typescript)."
            ))
        }
        let path = fileURL.standardizedFileURL.resolvingSymlinksInPath().path
        let result = await Task.detached(priority: .userInitiated) {
            server.definition(file: path, line: line, offset: column)
        }.value
        noteOutcome(of: result.map { _ in () })
        return result
    }

    func references(
        rootURL: URL,
        fileURL: URL,
        line: Int,
        column: Int
    ) async -> Result<(symbolName: String?, references: [TSReference]), TSServerError> {
        guard let server = await ensureServer(rootURL: rootURL) else {
            return .failure(.toolchainNotFound(
                "TypeScript service not found — needs node and typescript (npm i -D typescript)."
            ))
        }
        let path = fileURL.standardizedFileURL.resolvingSymlinksInPath().path
        let result = await Task.detached(priority: .userInitiated) {
            server.references(file: path, line: line, offset: column)
        }.value
        noteOutcome(of: result.map { _ in () })
        return result
    }

    /// Shared crash/wedge bookkeeping for both lookup kinds.
    private func noteOutcome(of result: Result<Void, TSServerError>) {
        switch result {
        case .success:
            consecutiveTimeouts = 0
        case .failure(.notRunning):
            consecutiveTimeouts = 0
            server = nil // crashed: respawn on next attempt
        case .failure(.timedOut):
            consecutiveTimeouts += 1
            if consecutiveTimeouts >= Self.timeoutsBeforeRespawn {
                consecutiveTimeouts = 0
                server?.shutdown() // unblocks any writer stuck on the full stdin pipe
                server = nil
            }
        case .failure:
            consecutiveTimeouts = 0
        }
    }

    func shutdown() {
        server?.shutdown()
        server = nil
    }

    private func ensureServer(rootURL: URL) async -> TSServer? {
        if let server {
            return server
        }
        let root = rootURL
        let created = await Task.detached(priority: .userInitiated) { () -> TSServer? in
            guard let toolchain = TSServer.discoverToolchain(projectRoot: root) else { return nil }
            return try? TSServer(toolchain: toolchain)
        }.value
        server = created
        return created
    }
}
