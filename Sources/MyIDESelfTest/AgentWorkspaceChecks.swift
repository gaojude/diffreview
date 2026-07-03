import Foundation
import MyIDECore

/// Agent workspace logic checks: the mock agent-browser engine + demo portal,
/// automation record/replay, and the harness wire protocol. Called from
/// main.swift; uses its `section`/`check` helpers.
func runAgentWorkspaceChecks() {
    checkEngineAndPortal()
    checkAutomationRecordReplay()
    checkHarnessWire()
    checkLineBuffer()
    checkRealBrowserSupport()
}

private let portalBase = "https://portal.maplelife.example"

// MARK: - Engine + portal

private func checkEngineAndPortal() {
    section("Agent browser engine drives the demo portal")

    let portal = MapleLifePortal()
    let engine = AgentBrowserEngine(sites: [portal])

    check(!engine.execute("click \"Sign in\"").ok, "element commands require an open page")
    check(!engine.execute("open https://elsewhere.example/x").ok, "unknown hosts are rejected")

    let opened = engine.execute("open \(portalBase)/login")
    check(opened.ok, "opens the portal login page")
    check(opened.output.contains("Maple Life — Sign in"), "open reports the page title")

    let snapshot = engine.execute("snapshot")
    check(snapshot.ok, "snapshot succeeds")
    let expectedLines = [
        "Page: Maple Life — Sign in (\(portalBase)/login)",
        "- heading \"Sign in to Maple Life\" [ref=e1]",
        "- text \"Demo portal — any username and password will work.\" [ref=e2]",
        "- textbox \"Username\" [ref=e3]",
        "- textbox \"Password\" [ref=e4]",
        "- button \"Sign in\" [ref=e5]",
    ]
    check(snapshot.output == expectedLines.joined(separator: "\n"), "login snapshot matches the documented format exactly")

    check(!engine.execute("click @e99").ok, "unknown refs are rejected")
    check(!engine.execute("press @e3 Meta").ok, "unknown keys are rejected")

    let fillByRef = engine.execute("fill @e3 \"jude\"")
    check(fillByRef.ok, "fill by ref works")
    check(fillByRef.canonicalCommand == "fill \"Username\" \"jude\"", "fill canonicalizes to the quoted-label form")
    check(engine.execute("get value @e3").output == "jude", "get value reads back the typed text")

    let typed = engine.execute("type @e3 \"gao\"")
    check(typed.ok && engine.execute("get value @e3").output == "judegao", "type appends to the existing value")
    check(engine.execute("press @e3 Backspace").ok && engine.execute("get value @e3").output == "judega", "Backspace edits a textbox")
    check(engine.execute("fill @e3 \"jude\"").ok, "fill replaces the value outright")

    check(!engine.execute("click \"Sign in\"").ok, "sign-in requires both fields")
    check(engine.execute("fill \"Password\" \"demo\"").ok, "label selectors resolve without a snapshot")
    let signIn = engine.execute("click @e5")
    check(signIn.ok && signIn.output == "Signed in as jude", "sign-in navigates with a friendly message")
    check(engine.execute("get url").output == "\(portalBase)/overview", "sign-in lands on the overview")

    let stale = engine.execute("click @e5")
    check(!stale.ok && stale.output == "stale ref — take a new snapshot", "refs from before a navigation are stale")

    check(engine.execute("wait --load networkidle").output == "idle", "wait reports idle")
    check(engine.execute("sleep 2").ok, "sleep succeeds without blocking")
    check(engine.execute("screenshot").output.contains("Welcome back, jude"), "screenshot returns the current snapshot")

    check(engine.execute("click \"Make a claim\"").ok, "starts a claim")

    // The claimant dropdown is one of the portal's two "custom widget" gotchas.
    let comboFill = engine.execute("fill \"Claim for\" \"Jude Gao\"")
    check(!comboFill.ok && comboFill.output == "This is a custom dropdown — open it and use ArrowDown and Enter to choose.",
          "comboboxes reject fill with the teaching message")
    let closedEnter = engine.execute("press \"Claim for\" Enter")
    check(!closedEnter.ok && closedEnter.output == "The list isn't open — click it or press ArrowDown first.",
          "Enter on a closed combobox explains itself")
    let blockedContinue = engine.execute("click \"Continue\"")
    check(!blockedContinue.ok && blockedContinue.output == "\"Continue\" is disabled — choose who the claim is for first",
          "disabled Continue explains why")
    check(engine.execute("press \"Claim for\" ArrowDown").output == "Highlighted \"Jude Gao\"", "ArrowDown opens with the first option")
    check(engine.execute("press \"Claim for\" ArrowDown").output == "Highlighted \"Alex Gao\"", "ArrowDown moves the highlight")
    check(engine.execute("press \"Claim for\" ArrowDown").output == "Highlighted \"Alex Gao\"", "the highlight clamps at the last option")
    check(engine.execute("press \"Claim for\" ArrowUp").output == "Highlighted \"Jude Gao\"", "ArrowUp moves back up")
    check(engine.execute("press \"Claim for\" Enter").output == "Selected \"Jude Gao\"", "Enter commits the highlighted option")

    let openCombo = engine.execute("snapshot")
    check(!openCombo.output.contains("[highlighted]"), "committing closes the option list")
    check(openCombo.output.contains("- combobox \"Claim for\" [ref=e2] [value=Jude Gao]"), "the combobox shows its committed value")
    check(engine.execute("click \"Continue\"").ok, "Continue proceeds once a claimant is chosen")

    // Radios: the other signature quirk — clicks don't register, Space does.
    let radioClick = engine.execute("click \"Massage therapist\"")
    check(!radioClick.ok && radioClick.output == "The click didn't register on this custom radio. Focus it and press Space instead.",
          "radio clicks fail with the recovery hint")
    check(radioClick.canonicalCommand == nil, "failed commands have no canonical form")
    let categoryBlocked = engine.execute("click \"Continue\"")
    check(categoryBlocked.output == "\"Continue\" is disabled — select a category first", "category Continue is gated")
    check(engine.execute("press \"Massage therapist\" Space").output == "Selected \"Massage therapist\"", "Space selects the radio")
    check(engine.execute("snapshot").output.contains("- radio \"Massage therapist\" [ref=e2] [checked]"), "the selected radio renders as checked")
    check(engine.execute("click \"Continue\"").ok, "category Continue proceeds")

    // Expense validation, in the portal's declared order: visit type, date, amount.
    check(engine.execute("click \"Add expense\"").output == "Choose a visit type first.", "expense needs a visit type")
    check(engine.execute("press \"Visit type\" ArrowDown").output == "Highlighted \"Initial visit\"", "visit type opens on ArrowDown")
    check(engine.execute("press \"Visit type\" ArrowDown").output == "Highlighted \"Subsequent visit\"", "visit type steps to the second option")
    check(engine.execute("press \"Visit type\" Enter").output == "Selected \"Subsequent visit\"", "visit type commits")
    check(engine.execute("click \"Add expense\"").output == "Enter the date as YYYY-MM-DD.", "expense validates the date format")
    check(engine.execute("fill \"Service date (YYYY-MM-DD)\" \"2026-06-14\"").ok, "labels with spaces and parentheses resolve")
    check(engine.execute("click \"Add expense\"").output == "Enter the amount as a number, like 84.50.", "expense validates the amount")
    check(engine.execute("fill \"Amount\" \"84.50\"").ok, "fills the amount")
    check(engine.execute("click \"Add expense\"").output == "Added expense — $84.50", "adds the expense")
    let expenseSnapshot = engine.execute("snapshot").output
    check(expenseSnapshot.contains("- text \"1. 2026-06-14 — Subsequent visit — $84.50\""), "added expenses render as line items")
    check(!expenseSnapshot.contains("[value=2026-06-14]") && !expenseSnapshot.contains("[value=84.50]"),
          "expense fields clear after adding")

    check(engine.execute("click \"Continue\"").ok, "moves to review")
    let review = engine.execute("snapshot").output
    check(review.contains("- text \"For: Jude Gao\"") && review.contains("- text \"Care: Massage therapist\""), "review recaps the claim")
    check(review.contains("- text \"Total: $84.50\""), "review totals the expenses")

    check(engine.execute("click \"Submit claim\"").output == "Claim submitted — total $84.50", "submits the claim")
    check(engine.execute("get url").output == "\(portalBase)/claim/done", "lands on the done page")
    check(engine.execute("get title").output == "Claim submitted", "done page title")
    let done = engine.execute("snapshot").output
    check(done.contains("- heading \"Claim successfully submitted!\""), "done page confirms the claim")
    check(done.contains("We received your claim for $84.50."), "done page repeats the amount")
    check(portal.submittedClaimCount == 1, "the portal counted the submission")
    check(portal.lastSubmittedTotal == "$84.50", "the portal remembered the total")

    check(engine.execute("click \"Make another claim\"").ok, "can start another claim")
    check(engine.execute("get url").output == "\(portalBase)/claim/who", "another claim restarts the wizard")

    engine.reset()
    check(engine.currentURL == nil && portal.submittedClaimCount == 0, "reset clears the engine and the portal")

    let redirected = engine.execute("open \(portalBase)/claim/review")
    check(redirected.ok && engine.execute("get url").output == "\(portalBase)/login",
          "unauthenticated deep links land on the sign-in page")
    check(!engine.execute("open \(portalBase)/nope").ok, "unknown paths are a friendly 404")
}

// MARK: - Record + replay

private func checkAutomationRecordReplay() {
    section("Automations record, save and replay")

    check(Automation.slug(from: "Submit my massage claim!") == "submit-my-massage-claim", "slugs are kebab-case")
    check(Automation.slug(from: "  ¡¡!!  ") == "automation", "degenerate names still slug")

    let portal = MapleLifePortal()
    let engine = AgentBrowserEngine(sites: [portal])
    let recorder = AutomationRecorder()
    // Wire the recorder the way the app's controller does.
    engine.onEvent = { event in
        if case .commandExecuted(let command, let result) = event {
            recorder.observe(command: command, result: result, note: "step note")
        }
    }
    recorder.start()

    let session = [
        "open \(portalBase)/login",
        "snapshot",
        "fill \"Username\" \"jude\"",
        "fill \"Password\" \"demo\"",
        "click \"Sign in\"",
        "snapshot",
        "click \"Make a claim\"",
        "press \"Claim for\" ArrowDown",
        "press \"Claim for\" Enter",
        "click \"Continue\"",
        "click \"Massage therapist\"", // fails on purpose — must not be recorded
        "press \"Massage therapist\" Space",
        "click \"Continue\"",
        "fill \"Service date (YYYY-MM-DD)\" \"2026-06-14\"",
        "press \"Visit type\" ArrowDown",
        "press \"Visit type\" ArrowDown",
        "press \"Visit type\" Enter",
        "fill \"Amount\" \"84.50\"",
        "click \"Add expense\"",
        "click \"Continue\"",
        "get value \"Amount\"", // read-only — must not be recorded
        "click \"Submit claim\"",
    ]
    for command in session {
        engine.execute(command)
    }
    recorder.stop()

    check(engine.currentURL == "\(portalBase)/claim/done", "the recorded session reached the done page")
    check(recorder.steps.count == 18, "recorded exactly the mutating, successful commands")
    check(recorder.steps.first?.command == "open \(portalBase)/login", "open is kept verbatim")
    check(recorder.steps.allSatisfy { !$0.command.contains("@e") }, "no @eN refs survive into recorded steps")
    check(!recorder.steps.contains { $0.command == "click \"Massage therapist\"" }, "the failed radio click was skipped")
    check(recorder.steps.contains { $0.command == "press \"Massage therapist\" Space" }, "the working radio press was kept")
    check(recorder.steps.allSatisfy { $0.note == "step note" }, "notes ride along with steps")

    let automation = Automation(
        name: "Submit a massage claim",
        slug: Automation.slug(from: "Submit a massage claim"),
        summary: "Files a massage claim on the Maple Life demo portal.",
        createdAt: Date(),
        steps: recorder.steps
    )

    // Store round-trip in a scratch directory.
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("myide-automation-checks-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    let store = AutomationStore(directory: scratch)

    guard case .saved(let folder) = store.save(automation) else {
        check(false, "saves the automation")
        return
    }
    check(FileManager.default.fileExists(atPath: folder.appendingPathComponent("SKILL.md").path), "writes SKILL.md next to the script")

    let listed = store.list()
    check(listed.count == 1, "lists the saved automation")
    check(listed.first?.steps == automation.steps, "steps survive the disk round-trip")
    check(listed.first?.summary == automation.summary, "metadata survives the disk round-trip")

    let markdown = AutomationStore.skillMarkdown(for: automation)
    check(markdown.contains("# Submit a massage claim"), "SKILL.md carries the automation name")
    check(markdown.contains("description: Files a massage claim on the Maple Life demo portal."), "SKILL.md frontmatter has the summary")
    check(markdown.contains("1. `open \(portalBase)/login`"), "SKILL.md numbers the steps")
    check(markdown.contains("## Replay"), "SKILL.md explains how to replay")

    // Replay against a fresh portal: the whole point of label-form recording.
    engine.reset()
    var replayedSteps = 0
    let outcome = AutomationReplay.run(automation, on: engine) { _, _, result in
        if result.ok { replayedSteps += 1 }
    }
    check(outcome.succeeded, "replay completes: \(outcome.failureMessage ?? "ok")")
    check(outcome.completedSteps == automation.steps.count && replayedSteps == automation.steps.count, "replay ran every step")
    check(engine.currentURL == "\(portalBase)/claim/done", "replay reached the done page")
    check(portal.submittedClaimCount == 1 && portal.lastSubmittedTotal == "$84.50", "replay actually submitted the claim")

    // A stale recording fails loudly at the right step.
    let broken = Automation(
        name: "Broken", slug: "broken", summary: "Stale demo.", createdAt: Date(),
        steps: [AutomationStep(command: "open \(portalBase)/login"), AutomationStep(command: "click \"No such button\"")]
    )
    engine.reset()
    let brokenOutcome = AutomationReplay.run(broken, on: engine)
    check(!brokenOutcome.succeeded && brokenOutcome.completedSteps == 1, "replay stops at the first failing step")
    check(brokenOutcome.failureMessage?.contains("Step 2") == true, "the failure message names the step")

    check(store.delete(slug: automation.slug), "deletes the automation")
    check(store.list().isEmpty, "the list is empty after deleting")
}

// MARK: - Wire protocol

private func checkHarnessWire() {
    section("Harness wire protocol encodes and decodes")

    check(HarnessWire.decode("{\"type\":\"hello\",\"mode\":\"mock\",\"version\":1}") == .hello(mode: "mock"), "decodes hello")
    check(HarnessWire.decode("{\"type\":\"state\",\"value\":\"working\"}") == .state("working"), "decodes state")
    check(HarnessWire.decode("{\"type\":\"text\",\"text\":\"Hi there\"}") == .text("Hi there"), "decodes text")
    check(HarnessWire.decode("{\"type\":\"tool_use\",\"id\":\"t1\",\"command\":\"click @e3\"}") == .toolUse(id: "t1", command: "click @e3"),
          "decodes tool_use")
    check(HarnessWire.decode("{\"type\":\"turn_end\"}") == .turnEnd, "decodes turn_end")
    check(HarnessWire.decode("{\"type\":\"fatal\",\"message\":\"boom\"}") == .fatal("boom"), "decodes fatal")
    check(HarnessWire.decode("not json at all") == nil, "malformed lines decode to nil")
    check(HarnessWire.decode("{\"type\":\"wibble\"}") == nil, "unknown types decode to nil")
    check(HarnessWire.decode("{\"type\":\"tool_use\",\"id\":\"t1\"}") == nil, "missing fields decode to nil")

    func fields(of message: AppToHarnessMessage) -> [String: Any]? {
        let line = HarnessWire.encode(message)
        check(!line.contains("\n"), "encoded messages are single lines")
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    let user = fields(of: .user("Submit my claim"))
    check(user?["type"] as? String == "user" && user?["text"] as? String == "Submit my claim", "encodes user messages")
    let result = fields(of: .toolResult(id: "t7", ok: true, output: "Opened"))
    check(result?["type"] as? String == "tool_result" && result?["id"] as? String == "t7"
          && result?["ok"] as? Bool == true && result?["output"] as? String == "Opened", "encodes tool results")
    check(fields(of: .shutdown)?["type"] as? String == "shutdown", "encodes shutdown")
}

// MARK: - Real browser support

private func checkRealBrowserSupport() {
    section("Real agent-browser snapshot index and recorder rules")

    let snapshot = """
    Home \\ Anthropic
    - link "Skip to main content" [ref=e1]
    - heading "This site can't be reached" [level=1, ref=e2]
    - textbox "Email" [ref=e3]
    - button "Commitments" [expanded=false, ref=e25]
    - separator [ref=e9]
    not a snapshot line
    """
    let index = RealSnapshotIndex.parse(snapshot)
    check(index.entries.count == 5, "indexes every ref line")
    check(index.entries["e1"] == RealSnapshotIndex.Entry(role: "link", name: "Skip to main content"), "parses role and name")
    check(index.entries["e25"] == RealSnapshotIndex.Entry(role: "button", name: "Commitments"), "parses refs after other attributes")
    check(index.entries["e9"]?.name == "", "elements without a name index with an empty name")

    check(index.canonicalCommand(verb: "click", ref: "e25", arguments: []) == "find text \"Commitments\" click",
          "clicks canonicalize to find text")
    check(index.canonicalCommand(verb: "fill", ref: "e3", arguments: ["hello world"]) == "find label \"Email\" fill \"hello world\"",
          "input fills canonicalize to find label with quoted args")
    check(index.canonicalCommand(verb: "click", ref: "e99", arguments: []) == nil, "unknown refs cannot canonicalize")
    check(index.canonicalCommand(verb: "click", ref: "e9", arguments: []) == nil, "nameless elements cannot canonicalize")

    // Real recordings keep waits and the wider real-CLI verb set.
    let recorder = AutomationRecorder(readOnlyVerbs: AutomationRecorder.realBrowserReadOnlyVerbs)
    recorder.start()
    let ok = AgentBrowserCommandResult(ok: true, output: "✓")
    recorder.observe(command: "open --headed https://real.example", result: ok, note: nil)
    recorder.observe(command: "snapshot -i", result: ok, note: nil)
    recorder.observe(command: "wait --load networkidle", result: ok, note: nil)
    recorder.observe(command: "find text \"Sign In\" click", result: ok, note: nil)
    recorder.observe(command: "get title", result: ok, note: nil)
    check(recorder.steps.map(\.command) == [
        "open --headed https://real.example",
        "wait --load networkidle",
        "find text \"Sign In\" click",
    ], "real recordings keep open/wait/find and skip snapshot/get")
}

// MARK: - Line buffer

private func checkLineBuffer() {
    section("NDJSON line buffer reassembles chunked pipes")

    var buffer = NDJSONLineBuffer()
    check(buffer.append(Data("{\"type\":\"tu".utf8)).isEmpty, "holds a partial line")
    check(buffer.append(Data("rn_e".utf8)).isEmpty, "keeps holding across chunks")
    check(buffer.append(Data("nd\"}\n".utf8)) == ["{\"type\":\"turn_end\"}"], "emits the line once the newline arrives")

    let batch = buffer.append(Data("{\"a\":1}\r\n\n{\"b\":2}\n{\"c\":".utf8))
    check(batch == ["{\"a\":1}", "{\"b\":2}"], "strips \\r, skips blank lines, batches complete lines")
    check(buffer.append(Data("3}\n".utf8)) == ["{\"c\":3}"], "finishes the held tail")
}
