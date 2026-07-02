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
        if CommandLine.arguments.contains("--selection-chat-agent-self-test") {
            Self.runSelectionChatAgentSelfTestAndExit()
        }
        if CommandLine.arguments.contains("--selection-chat-agent-live-test") {
            Self.runSelectionChatAgentLiveTestAndExit()
        }
        if CommandLine.arguments.contains("--agent-workspace-self-test") {
            AgentWorkspaceSelfTest.run()
        }

        let rootURL = Self.rootURL()
        let appState = AppState(rootURL: rootURL)
        _appState = StateObject(wrappedValue: appState)
        // `--assistant` launches straight into the agent workspace with no IDE window —
        // the whole point of that flag is a non-technical entry into saved automations.
        let assistantOnly = CommandLine.arguments.contains("--assistant")
        DispatchQueue.main.async {
            if assistantOnly {
                AgentWorkspaceWindowController.shared.openAgentWorkspace()
            } else {
                ProjectWindowController.shared.openProjectWindowIfNeeded(rootURL: rootURL, appState: appState)
            }
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

            CommandMenu("Assistant") {
                Button("Open Assistant") {
                    AgentWorkspaceWindowController.shared.openAgentWorkspace()
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])
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

    private static func runSelectionChatAgentSelfTestAndExit() -> Never {
        Task { @MainActor in
            let exitCode = await runSelectionChatAgentSelfTest()
            Foundation.exit(Int32(exitCode))
        }
        RunLoop.main.run()
        fatalError("RunLoop.main.run() unexpectedly returned")
    }

    private static func runSelectionChatAgentLiveTestAndExit() -> Never {
        Task { @MainActor in
            let exitCode = await runSelectionChatAgentLiveTest()
            Foundation.exit(Int32(exitCode))
        }
        RunLoop.main.run()
        fatalError("RunLoop.main.run() unexpectedly returned")
    }

    @MainActor
    private static func runSelectionChatAgentSelfTest() async -> Int {
        var failures = 0
        func check(_ condition: Bool, _ message: String) {
            if condition {
                print("ok \(message)")
            } else {
                failures += 1
                print("FAIL \(message)")
            }
        }

        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("myide-agent-selftest-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tmp) }

            let fileURL = tmp.appendingPathComponent("Example.swift")
            try """
            func pageShellEventName() -> String {
                "page_shell"
            }
            """.write(to: fileURL, atomically: true, encoding: .utf8)

            let context = CodeSelectionContext(
                fileURL: fileURL,
                contentKind: .source,
                startLine: 1,
                endLine: 3,
                text: "func pageShellEventName() -> String {\n    \"page_shell\"\n}"
            )

            let client = StreamingCodeAgentClient()
            var normalDeltas = ""
            var normalTools: [AgentToolEvent] = []
            let normalReply = try await client.ask(
                question: "Is this name misleading?",
                context: context,
                rootURL: tmp,
                onProgress: { _ in },
                onToolEvent: { event in normalTools.append(event) },
                onDelta: { delta in normalDeltas += delta }
            )
            check(normalReply.contains("instrumentation"), "mock chat returns final streamed answer")
            check(normalDeltas == normalReply, "streamed deltas match final answer")
            check(normalTools.contains(where: { $0.name == "get_git_diff" && $0.status == .finished }), "agent executes diff tool")

            var capturedProposal: AgentFixProposal?
            let fixReply = try await client.ask(
                question: "Please fix the misleading name.",
                context: context,
                rootURL: tmp,
                forceFixCapture: true,
                onProgress: { _ in },
                onToolEvent: { _ in },
                onDelta: { _ in },
                onFixProposal: { proposal in capturedProposal = proposal }
            )
            check(fixReply.contains("Captured"), "mock fix run returns final capture acknowledgement")
            check(capturedProposal?.prompt.contains("Rename") == true, "fix proposal comes from capture_fix tool")

            do {
                _ = try await client.ask(
                    question: "credit-error",
                    context: context,
                    rootURL: tmp,
                    onProgress: { _ in },
                    onToolEvent: { _ in },
                    onDelta: { _ in }
                )
                check(false, "provider stream errors surface")
            } catch {
                check(error.localizedDescription.contains("insufficient_quota"), "provider stream errors surface")
            }

            let snapshot = PromptFixSnapshot(
                rootURL: tmp,
                context: context,
                contextLabel: context.locationLabel,
                requestedChange: capturedProposal?.summary ?? "Rename it",
                exchanges: [
                    SelectionChatExchange(
                        question: "Please fix the misleading name.",
                        answer: fixReply,
                        contextLabel: context.locationLabel,
                        context: context
                    ),
                ]
            )
            let fix = PromptFixItem(
                proposal: capturedProposal ?? AgentFixProposal(
                    title: "Rename page shell instrumentation",
                    summary: "Rename the instrumentation label.",
                    prompt: "Rename the instrumentation label."
                ),
                snapshot: snapshot
            )
            let thread = SelectionChatThread(
                title: "Naming chat",
                contextLabel: context.locationLabel,
                exchanges: snapshot.exchanges
            )
            let storageRoot = tmp.appendingPathComponent("state", isDirectory: true)
            let featureStore = AssistantPersistenceStore(rootURL: tmp, branchName: "feature", storageRoot: storageRoot)
            featureStore.save(AssistantPersistedState(
                selectedThreadID: thread.id,
                threads: [thread],
                fixes: [fix]
            ))
            let loaded = featureStore.load()
            check(loaded.threads.first?.title == "Naming chat", "chat thread persists")
            check(loaded.fixes.first?.prompt == fix.prompt, "fix persists")

            let otherBranchStore = AssistantPersistenceStore(rootURL: tmp, branchName: "other", storageRoot: storageRoot)
            check(otherBranchStore.load().threads.isEmpty, "assistant state is branch-scoped")
        } catch {
            failures += 1
            print("FAIL agent self-test threw \(error)")
        }

        if failures == 0 {
            print("selection chat agent ok")
            return 0
        }
        print("selection chat agent failed: \(failures)")
        return 1
    }

    @MainActor
    private static func runSelectionChatAgentLiveTest() async -> Int {
        var failures = 0
        func check(_ condition: Bool, _ message: String) {
            if condition {
                print("ok \(message)")
            } else {
                failures += 1
                print("FAIL \(message)")
            }
        }

        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("myide-live-agent-test-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tmp) }

            let fileURL = tmp.appendingPathComponent("InstrumentationNaming.swift")
            try """
            enum InstrumentationNaming {
                static let pageShell = "page_shell"
            }
            """.write(to: fileURL, atomically: true, encoding: .utf8)

            let context = CodeSelectionContext(
                fileURL: fileURL,
                contentKind: .source,
                startLine: 1,
                endLine: 3,
                text: "enum InstrumentationNaming {\n    static let pageShell = \"page_shell\"\n}"
            )

            let client = StreamingCodeAgentClient()
            var answerDeltas = ""
            var toolEvents: [AgentToolEvent] = []
            let answer = try await client.ask(
                question: "In one concise sentence, say whether page shell sounds misleading for an instrumentation-only name.",
                context: context,
                rootURL: tmp,
                onProgress: { _ in },
                onToolEvent: { event in toolEvents.append(event) },
                onDelta: { delta in answerDeltas += delta }
            )
            check(!answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Claude returns a non-empty chat answer")
            check(answerDeltas == answer, "Claude answer streams through deltas")
            check(toolEvents.contains(where: { $0.name == "get_git_diff" && $0.status == .finished }), "Claude run executes get_git_diff")

            var proposal: AgentFixProposal?
            var fixToolEvents: [AgentToolEvent] = []
            let fixAnswer = try await client.ask(
                question: "Create a fix proposal for renaming this instrumentation-only page shell label.",
                context: context,
                rootURL: tmp,
                forceFixCapture: true,
                onProgress: { _ in },
                onToolEvent: { event in fixToolEvents.append(event) },
                onDelta: { _ in },
                onFixProposal: { proposal = $0 }
            )
            check(!fixAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Claude returns a final fix acknowledgement")
            check(fixToolEvents.contains(where: { $0.name == "capture_fix" && $0.status == .finished }), "Claude calls capture_fix")
            check(proposal?.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false, "Claude provides a fix title")
            check(proposal?.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false, "Claude provides a fix prompt")
        } catch {
            failures += 1
            print("FAIL live Claude agent test threw \(error.localizedDescription)")
        }

        if failures == 0 {
            print("selection chat live agent ok")
            return 0
        }
        print("selection chat live agent failed: \(failures)")
        return 1
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
