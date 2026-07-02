import AppKit
import SwiftUI
import MyIDECore

/// Headless end-to-end check behind `--agent-workspace-self-test`: spawns the
/// real node harness in mock mode, lets it drive the in-process engine through
/// the whole demo insurance claim, then saves + replays the recording — the
/// exact loop the Assistant window runs, minus pixels. Ends with a layout smoke
/// of the workspace view. Exits 0 on success (or when node is unavailable).
enum AgentWorkspaceSelfTest {
    @MainActor
    static func run() -> Never {
        func fail(_ message: String, code: Int32) -> Never {
            FileHandle.standardError.write(Data(("✗ agent workspace self-test: " + message + "\n").utf8))
            Foundation.exit(code)
        }

        print("▸ agent workspace self-test")

        guard let node = AgentHarnessLocator.findNode() else {
            print("⚠ node not found — agent workspace self-test skipped")
            Foundation.exit(0)
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        var scriptStarts = [cwd]
        if let resources = Bundle.main.resourceURL {
            scriptStarts.append(resources)
        }
        scriptStarts.append(Bundle.main.bundleURL)
        guard let script = AgentHarnessLocator.findHarnessScript(startingFrom: scriptStarts) else {
            fail("could not locate harness/agent-harness.mjs from \(cwd.path)", code: 2)
        }
        let scenario = script.deletingLastPathComponent().appendingPathComponent("scenarios/insurance-claim.json")
        guard FileManager.default.fileExists(atPath: scenario.path) else {
            fail("missing demo scenario at \(scenario.path)", code: 2)
        }

        // MARK: Mock harness session end-to-end

        let portal = MapleLifePortal()
        let engine = AgentBrowserEngine(sites: [portal])
        let recorder = AutomationRecorder()
        recorder.start()

        let client = AgentHarnessClient()
        let done = DispatchSemaphore(value: 0)
        // Written only on the client's serial delivery queue; read on the main
        // thread strictly after the semaphore hand-off.
        nonisolated(unsafe) var texts = 0
        nonisolated(unsafe) var toolUses = 0
        nonisolated(unsafe) var fatalMessage: String?

        client.onMessage = { message in
            switch message {
            case .hello, .state:
                break
            case .text(let text):
                texts += 1
                print("  assistant: \(text.prefix(72))…")
            case .toolUse(let id, let command):
                toolUses += 1
                let result = engine.execute(command)
                recorder.observe(command: command, result: result, note: nil)
                client.send(.toolResult(id: id, ok: result.ok, output: result.output))
            case .turnEnd:
                done.signal()
            case .fatal(let message):
                fatalMessage = message
                done.signal()
            }
        }
        client.onTermination = { code in
            fatalMessage = fatalMessage ?? "harness exited early (code \(code))"
            done.signal()
        }

        let launch = client.launch(AgentHarnessClient.LaunchSpec(
            nodeURL: node,
            scriptURL: script,
            arguments: ["--mock", scenario.path, "--delay-ms", "5"]
        ))
        if case .failed(let message) = launch {
            fail("harness launch failed: \(message)", code: 3)
        }
        client.send(.user("Submit my massage claim, please"))

        if done.wait(timeout: .now() + 60) == .timedOut {
            fail("timed out waiting for the mock session to finish (stderr: \(client.recentStderr))", code: 4)
        }
        client.onTermination = nil
        client.stop()
        if let fatalMessage {
            fail("harness reported: \(fatalMessage)", code: 5)
        }

        if engine.currentURL != "https://portal.maplelife.example/claim/done" {
            fail("session ended on \(engine.currentURL ?? "no page"), expected the claim-done page", code: 6)
        }
        if portal.submittedClaimCount != 1 {
            fail("expected exactly one submitted claim, got \(portal.submittedClaimCount)", code: 6)
        }
        if texts < 2 || toolUses < 10 {
            fail("session looked too thin (texts=\(texts) tools=\(toolUses))", code: 6)
        }
        if recorder.steps.count < 8 {
            fail("expected ≥ 8 recorded steps, got \(recorder.steps.count)", code: 7)
        }
        print("✓ mock session submitted the demo claim (\(toolUses) tool calls, \(recorder.steps.count) recorded steps)")

        // MARK: Save + replay round-trip

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("myide-agent-workspace-selftest-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let store = AutomationStore(directory: scratch)
        let automation = Automation(
            name: "Submit a massage claim",
            slug: Automation.slug(from: "Submit a massage claim"),
            summary: "Files the demo massage claim on Maple Life.",
            createdAt: Date(),
            steps: recorder.steps
        )
        guard case .saved(let folder) = store.save(automation) else {
            fail("could not save the recorded automation", code: 8)
        }
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("SKILL.md").path) else {
            fail("SKILL.md was not generated", code: 8)
        }
        guard store.list().count == 1 else {
            fail("saved automation did not list back", code: 8)
        }

        engine.reset()
        let outcome = AutomationReplay.run(automation, on: engine)
        if !outcome.succeeded {
            fail("replay failed: \(outcome.failureMessage ?? "unknown")", code: 9)
        }
        if engine.currentURL != "https://portal.maplelife.example/claim/done" || portal.submittedClaimCount != 1 {
            fail("replay did not re-submit the claim", code: 9)
        }
        print("✓ recorded automation saved (with SKILL.md) and replayed to a fresh submission")

        // MARK: Layout smoke

        let controller = AgentWorkspaceController(store: store)
        let host = NSHostingView(rootView: AgentWorkspaceView(controller: controller))
        host.frame = NSRect(x: 0, y: 0, width: 1_000, height: 600)
        host.layoutSubtreeIfNeeded()
        guard host.fittingSize.width > 0, host.fittingSize.height > 0 else {
            fail("workspace view did not produce a visible layout", code: 10)
        }
        print("✓ workspace view lays out (fitting \(Int(host.fittingSize.width))x\(Int(host.fittingSize.height)))")

        print("✓ agent workspace self-test passed")
        Foundation.exit(0)
    }
}
