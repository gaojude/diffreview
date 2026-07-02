# Agent Workspace — design spec

A new window in MyIDE: a **terminal pane** showing a Claude agent session (managed by a
harness sidecar built on the Claude Agent SDK) beside a **browser pane** showing the page
that agent is operating on. Every browser action the agent performs is **recorded** and can
be saved as a named **automation** — a replayable script plus a generated `SKILL.md`
playbook (the "insurance claim" pattern: a skill that is really a recorded automation).

**UX principle: grandma-simple.** The workspace opens to a list of saved automations with
big Run buttons; watching a replay requires zero technical knowledge. All status text is
plain English. Demo mode works offline with no API key and no npm install.

The browser is a **mock** that mimics the `agent-browser` CLI's API design (commands,
`@eN` accessibility refs, snapshot format, "refs go stale" semantics, and the custom-widget
gotchas real portals have). No real browser runs.

## Architecture

```
┌─ MyIDE window "Assistant" ──────────────────────────────────┐
│ Automations shelf │ Terminal pane      │ Browser pane       │
│ (Run/Save cards)  │ (session console)  │ (rendered mock page)│
└───────┬───────────────────┬───────────────────┬─────────────┘
        │            AgentWorkspaceController (@MainActor)
        │                   │                   │
  AutomationStore    AgentHarnessClient   AgentBrowserEngine ── MapleLifePortal
  (Core, disk)       (Core, spawns node)  (Core, pure logic)    (Core, mock site)
                            │ NDJSON stdio
                     harness/agent-harness.mjs
                     (mock mode: scripted scenario, zero deps)
                     (live mode: @anthropic-ai/claude-agent-sdk)
```

The app is the **tool server**: the harness sends `tool_use` requests (agent-browser
commands); the app executes them on the in-process engine (so the UI updates live and the
recorder sees everything) and replies with `tool_result`.

## Wire protocol (NDJSON over stdio, one JSON object per line)

Harness → app (stdout):
- `{"type":"hello","mode":"mock"|"live","version":1}`
- `{"type":"state","value":"idle"|"working"}`
- `{"type":"text","text":"..."}` — assistant prose
- `{"type":"tool_use","id":"t1","command":"click @e3"}`
- `{"type":"turn_end"}`
- `{"type":"fatal","message":"..."}`

App → harness (stdin):
- `{"type":"user","text":"..."}`
- `{"type":"tool_result","id":"t1","ok":true,"output":"..."}`
- `{"type":"shutdown"}`

Unknown message types are ignored (forward compatibility). Harness stderr is diagnostics
only.

## Command grammar (mimics agent-browser CLI)

Target = `@eN` (ref from the **last snapshot**) or `"Quoted Label"` (exact accessible-name
match, first in traversal order — the replayable form).

- `open <url>` · `snapshot` · `click <target>` · `fill <target> <text>` (replace) ·
  `type <target> <text>` (append) · `press <target> <Key>`
  (Space | Enter | ArrowDown | ArrowUp | Backspace | Tab) ·
  `get value <target>` | `get url` | `get title` · `wait [...]` (ok, "idle") ·
  `sleep <secs>` (ok, no block) · `screenshot` (ok, output = snapshot text)

Refs go stale exactly like the real tool: refs resolve against the render captured at
`snapshot` time; after navigation every old ref errors ("stale ref — take a new
snapshot"), and a ref whose element no longer exists errors ("element not found").

Snapshot format (`Page:` header, two-space indent per depth, attrs only when meaningful):

```
Page: Make a claim — Who (https://portal.maplelife.example/claim/who)
- heading "Who is this claim for?" [ref=e1]
- combobox "Claim for" [ref=e2] [value=Jude Gao]
  - option "Jude Gao" [ref=e3] [highlighted]
- button "Continue" [ref=e4] [disabled]
```

`[value=…]` only when non-empty · `[checked]` · `[disabled]` · `[highlighted]` (open
combobox options only). Successful element-targeted commands also return a
`canonicalCommand` in label form (`click "Sign in"`) — that is what the recorder stores,
which is why replays survive ref renumbering.

## MyIDECore public API (exact contracts)

`Sources/MyIDECore/AgentBrowser.swift` — engine, command parsing, snapshot rendering:

```swift
public struct BrowserElement: Equatable, Sendable {
    public enum Role: String, Sendable { case heading, text, textbox, button, radio, combobox, option, link }
    public var id: String        // stable semantic id, e.g. "login.username"
    public var role: Role
    public var label: String
    public var value: String     // "" when none
    public var checked: Bool
    public var disabled: Bool
    public var highlighted: Bool
    public var children: [BrowserElement]
    public init(id:role:label:value:checked:disabled:highlighted:children:) // all but id/role/label defaulted
}
public struct BrowserPage: Equatable, Sendable { public var url: String; public var title: String; public var elements: [BrowserElement]; public init(...) }
public enum BrowserKey: String, Sendable { case space = "Space", enter = "Enter", arrowDown = "ArrowDown", arrowUp = "ArrowUp", backspace = "Backspace", tab = "Tab" }
public enum BrowserAction: Equatable, Sendable { case click, setValue(String), press(BrowserKey) }
public struct BrowserActionOutcome { public var ok: Bool; public var message: String; public var navigateTo: String?; public init(...) }
public protocol MockWebSite: AnyObject {
    var host: String { get }          // "portal.maplelife.example"
    func page(for url: String) -> BrowserPage?          // nil = not found; handles auth redirects
    func perform(_ action: BrowserAction, on elementID: String) -> BrowserActionOutcome
    func reset()
}
public struct AgentBrowserCommandResult: Equatable, Sendable {
    public var ok: Bool
    public var output: String
    public var canonicalCommand: String?   // label form; nil for non-element or failed commands
    public init(...)
}
public enum AgentBrowserEngineEvent { case pageChanged, commandExecuted(command: String, result: AgentBrowserCommandResult) }
public final class AgentBrowserEngine {   // not thread-safe; callers confine (controller = main actor)
    public init(sites: [MockWebSite])
    public private(set) var currentURL: String?
    public var currentPage: BrowserPage? { get }        // fresh render
    public private(set) var lastActedElementID: String?
    public var onEvent: ((AgentBrowserEngineEvent) -> Void)?
    @discardableResult public func execute(_ commandLine: String) -> AgentBrowserCommandResult
    public func reset()
}
```

Engine translates `fill` → `.setValue(text)`, `type` → `.setValue(current + text)`,
`press Backspace` on a textbox → `.setValue(String(current.dropLast()))`; other keys pass
through as `.press`. Command parsing tolerates double-quoted args with spaces. Errors are
`ok=false` with a helpful message (never fatal).

`Sources/MyIDECore/MapleLifePortal.swift` — the demo site (state machine; pages are pure
renders of state). `public final class MapleLifePortal: MockWebSite` with
`public private(set) var submittedClaimCount: Int` and
`public private(set) var lastSubmittedTotal: String?` for tests.

`Sources/MyIDECore/Automation.swift`:

```swift
public struct AutomationStep: Codable, Equatable, Sendable { public var command: String; public var note: String?; public init(command:note:) }
public struct Automation: Codable, Equatable, Sendable {
    public var name: String; public var slug: String; public var summary: String
    public var createdAt: Date; public var steps: [AutomationStep]
    public init(...); public static func slug(from name: String) -> String
}
public final class AutomationRecorder {
    public init(); public private(set) var isRecording: Bool; public private(set) var steps: [AutomationStep]
    public func start(); public func stop(); public func clear()
    public func observe(command: String, result: AgentBrowserCommandResult, note: String?)
}
public struct AutomationStore {
    public init(directory: URL); public static func defaultDirectory() -> URL   // ~/Library/Application Support/MyIDE/Automations
    public func list() -> [Automation]
    public enum SaveResult { case saved(URL), failed(String) }
    @discardableResult public func save(_ automation: Automation) -> SaveResult  // <slug>/automation.json + <slug>/SKILL.md
    @discardableResult public func delete(slug: String) -> Bool
    public static func skillMarkdown(for automation: Automation) -> String
}
public enum AutomationReplay {
    public struct Outcome: Equatable { public var completedSteps: Int; public var failureMessage: String?; public var succeeded: Bool { get } }
    public static func run(_ automation: Automation, on engine: AgentBrowserEngine,
                           onStep: ((Int, AutomationStep, AgentBrowserCommandResult) -> Void)?) -> Outcome
}
```

Recorder rules: only successful, state-mutating commands (`open/click/fill/type/press`)
are recorded, in `canonicalCommand` (label) form — `open` keeps its URL form. Read-only
verbs (`snapshot/get/wait/sleep/screenshot`) and failures are skipped. `note` = the most
recent assistant text (controller truncates to 140 chars). JSON on disk: `.prettyPrinted,
.sortedKeys`, atomic. `SKILL.md` mirrors the house skill shape: frontmatter
(`name`, `description`), "## What this automation does", "## Steps" (numbered
`command` + note), "## Replay" (open Assistant → Automations → Run).

`Sources/MyIDECore/AgentHarnessProtocol.swift`:

```swift
public enum HarnessMessage: Equatable, Sendable { case hello(mode: String), state(String), text(String), toolUse(id: String, command: String), turnEnd, fatal(String) }
public enum AppToHarnessMessage: Equatable, Sendable { case user(String), toolResult(id: String, ok: Bool, output: String), shutdown }
public enum HarnessWire {
    public static func decode(_ line: String) -> HarnessMessage?   // nil on malformed/unknown
    public static func encode(_ message: AppToHarnessMessage) -> String  // one line, no trailing \n
}
public struct NDJSONLineBuffer: Sendable {  // pure, chunk-boundary-safe (mirrors TSServerMessageBuffer)
    public init(); public mutating func append(_ chunk: Data) -> [String]
}
```

`Sources/MyIDECore/AgentHarnessClient.swift` — subprocess supervisor (model on
`TypeScriptServer` at working-tree HEAD of the main checkout; drain pipes via
readabilityHandler, never let a pipe fill before `waitUntilExit`):

```swift
public final class AgentHarnessClient {
    public struct LaunchSpec { public var nodeURL: URL; public var scriptURL: URL; public var arguments: [String]; public var environment: [String: String]?; public init(...) }
    public enum LaunchResult: Equatable { case running, failed(String) }
    public init()
    public var onMessage: ((HarnessMessage) -> Void)?   // serial utility queue
    public var onTermination: ((Int32) -> Void)?
    public var isRunning: Bool { get }
    public func launch(_ spec: LaunchSpec) -> LaunchResult
    public func send(_ message: AppToHarnessMessage)
    public func stop()
}
public enum AgentHarnessLocator {
    public static func findNode(environment: [String: String]) -> URL?          // PATH + /opt/homebrew/bin, /usr/local/bin, ~/.volta/bin, ~/.nvm/versions/node/*/bin (newest), ~/.local/*/bin
    public static func findHarnessScript(startingFrom directories: [URL]) -> URL?  // walk up ≤12 levels looking for harness/agent-harness.mjs
}
```

No `throws` on public API anywhere (house rule): result enums / optionals with
user-facing message strings. `///` doc comments explain *why*; `// MARK: -` sections.

## MapleLifePortal — exact site spec (single source of truth)

Host `portal.maplelife.example`; URLs below are `https://portal.maplelife.example<path>`.
Unauthenticated access to any non-login path renders the login page (the rendered page's
URL becomes `/login` — pages are pure renders of state). `open` with unknown host → ok=false "This demo can only
open https://portal.maplelife.example pages." Unknown path on the right host → ok=false
"Page not found: <url>". Amounts: parse `^\d+(\.\d{1,2})?$`, render `$%.2f`. Dates:
`^\d{4}-\d{2}-\d{2}$`.

| Path | Title | Elements (role "Label" — id) |
|---|---|---|
| `/login` | `Maple Life — Sign in` | heading "Sign in to Maple Life" — login.heading · text "Demo portal — any username and password will work." — login.hint · textbox "Username" — login.username · textbox "Password" — login.password · button "Sign in" — login.submit |
| `/overview` | `My Maple Life` | heading "Welcome back, <username>" — overview.heading · text "Your benefits at a glance." — overview.blurb · button "Make a claim" — overview.makeClaim · button "Sign out" — overview.signOut |
| `/claim/who` | `Make a claim — Who` | heading "Who is this claim for?" — who.heading · combobox "Claim for" (options "Jude Gao", "Alex Gao"; ids who.claimant, who.claimant.option.0/1) · button "Continue" — who.continue |
| `/claim/category` | `Make a claim — Category` | heading "What kind of care did you receive?" — category.heading · radio "Massage therapist" — category.massage · radio "Physiotherapist" — category.physio · radio "Chiropractor" — category.chiro · button "Continue" — category.continue |
| `/claim/expense` | `Make a claim — Expenses` | heading "Add your expenses" — expense.heading · textbox "Service date (YYYY-MM-DD)" — expense.date · combobox "Visit type" (options "Initial visit", "Subsequent visit"; ids expense.visitType, expense.visitType.option.0/1) · textbox "Amount" — expense.amount · button "Add expense" — expense.add · one text per added expense "N. <date> — <visit type> — $<amount>" — expense.item.N · button "Continue" — expense.continue |
| `/claim/review` | `Make a claim — Review` | heading "Review your claim" — review.heading · text "For: <claimant>" — review.for · text "Care: <category>" — review.care · expense line texts — review.item.N · text "Total: $<total>" — review.total · button "Submit claim" — review.submit |
| `/claim/done` | `Claim submitted` | heading "Claim successfully submitted!" — done.heading · text "We received your claim for $<total>. You'll hear from us within 2 business days." — done.blurb · button "Make another claim" — done.again |

Behaviors:
- **Sign in** click: both fields non-empty → nav `/overview`, "Signed in as <username>";
  else ok=false "Enter your username and password first." **Sign out** → clears all state,
  nav `/login`.
- **Radios** (the gotcha, mimicking OmniStudio): `click` → ok=false "The click didn't
  register on this custom radio. Focus it and press Space instead." `press Space` →
  exclusive-select, "Selected \"<label>\"".
- **Comboboxes** (the other gotcha): `click` toggles open · `ArrowDown` opens with first
  option highlighted, or moves down when open · `ArrowUp` moves up · `Enter` when open
  commits + closes ("Selected \"<option>\""), when closed → ok=false "The list isn't open —
  click it or press ArrowDown first." · `fill`/`type` → ok=false "This is a custom
  dropdown — open it and use ArrowDown and Enter to choose." · clicking an option commits.
- **Continue** buttons are `[disabled]` until valid; clicking disabled → ok=false
  "\"Continue\" is disabled — <reason>" (reasons: "choose who the claim is for first" /
  "select a category first" / "add at least one expense first").
- **Add expense**: validates visit type chosen ("Choose a visit type first."), date
  ("Enter the date as YYYY-MM-DD."), amount ("Enter the amount as a number, like 84.50.");
  success appends, clears the three inputs, "Added expense — $<amount>".
- **Submit claim** → nav `/claim/done`, increments `submittedClaimCount`, sets
  `lastSubmittedTotal`, "Claim submitted — total $<total>". **Make another claim** →
  clears claim fields (keeps login), nav `/claim/who`.

## Harness (harness/)

`agent-harness.mjs` (Node ≥ 20, ESM):
- `--mock <scenario.json> [--delay-ms N]` (default 150): **zero dependencies**. Emits
  `hello(mock)`, then per user message plays the next scenario turn: each emit item is
  either `{"text": "..."}` (→ `text`) or `{"tool": "<command>"}` (→ `tool_use`, then
  **wait** for the matching `tool_result` before continuing). Then `state idle` +
  `turn_end`. User turns beyond the script → text "That's everything I know how to do in
  demo mode — but you can replay this any time from the Automations list." + `turn_end`.
- live mode (no `--mock`): dynamic `import('@anthropic-ai/claude-agent-sdk')`; on failure →
  `fatal` "Live mode needs the Claude Agent SDK — run: cd harness && npm install". Uses
  `query()` with streaming input fed from stdin `user` messages, an in-process MCP server
  (`createSdkMcpServer`) exposing one tool `agent_browser({command: string})` whose handler
  round-trips through `tool_use`/`tool_result` over stdio, `permissionMode:
  'bypassPermissions'`, `maxTurns: 50`, and a system prompt teaching the agent-browser
  workflow (snapshot first; refs go stale after actions; radios may need focus+Space;
  custom dropdowns use ArrowDown/Enter; prefer quoted-label commands when repeating a
  known flow). Assistant text blocks → `text`; result message → `state idle` + `turn_end`.
  Be version-tolerant reading SDK stream shapes.
- Both modes: read stdin line-buffered NDJSON; `shutdown` → exit 0; write NDJSON to stdout
  (flush per line); diagnostics to stderr.
- `package.json`: name `my-ide-agent-harness`, private, `"dependencies":
  {"@anthropic-ai/claude-agent-sdk": "^0.1.0", "zod": "^3.23.0"}` (mock mode never needs
  them installed).
- `scenarios/insurance-claim.json`: one scripted turn that walks the portal spec above
  end-to-end in quoted-label commands — open portal, snapshot, fill Username "jude", fill
  Password "demo", click "Sign in", snapshot, click "Make a claim", snapshot, click
  "Claim for", press ArrowDown, press Enter (→ Jude Gao), click "Continue", snapshot,
  click "Massage therapist" (**deliberately fails**), a text noting the gotcha and the
  recovery, press "Massage therapist" Space, click "Continue", snapshot, fill date
  "2026-06-14", press "Visit type" ArrowDown ×2 + Enter (→ Subsequent visit), fill
  "Amount" "84.50", click "Add expense", click "Continue", snapshot, click "Submit claim",
  snapshot, closing text with the $84.50 confirmation and a nudge to save the automation.
  Interleave short assistant texts so the terminal reads like a narrated session.

## UI (Sources/MyIDE/, all new files)

- `AgentWorkspaceWindow.swift`: `AgentWorkspaceWindowController` singleton modeled on
  `ProjectWindowController` (manual `NSWindow` + `NSHostingController`,
  `isReleasedWhenClosed = false`, min 980×560, unified toolbar style, title "Assistant");
  `openAgentWorkspace()` creates once, then fronts + activates. Root `AgentWorkspaceView`.
- `AgentWorkspaceController.swift`: `@MainActor final class AgentWorkspaceController:
  ObservableObject`. Owns engine (+ portal), recorder, store, `AgentHarnessClient`.
  Published: `transcript: [TranscriptEntry]` (`enum Kind { user, assistant, tool, status }`,
  text, ok flag for tool lines), `page: BrowserPage?`, `lastActedElementID`, `automations`,
  `phase` (`ready/working/replaying(step:of:)/offline`), `mode` (`mock/live/none`),
  `canSaveAutomation`, `input`. Actions: `connect()` (locate node+script — collect candidates
  from env `MYIDE_HARNESS_DIR`, bundle Resources, and walk-up, preferring one with the Agent
  SDK installed next to it, since the bundle ships a lean mock-only copy; `MYIDE_AGENT_MOCK=1`
  or missing SDK → mock args with the bundled scenario; env `MYIDE_ASSISTANT_PROMPT` sends
  itself as the first user message once connected — scripted/no-typing entry), `sendPrompt()`,
  `runAutomation(_:)` (no harness needed — steps through `AutomationReplay` with ~350 ms
  `Task.sleep` between steps, updating progress + highlight), `saveRecording(name:summary:)`,
  `deleteAutomation(_:)`, `stop()`. Harness `tool_use` → `engine.execute` → transcript line
  `agent-browser <command> → ok|error` → `recorder.observe(note: last assistant text)` →
  `send(.toolResult(...))`. Client callbacks hop to main actor.
- `AgentTerminalPaneView.swift`: dark console (monospaced, ~13 pt): "You:" lines bold,
  assistant prose plain, tool lines dimmed with `⚙` prefix and green ✓ / orange ✗ suffix;
  auto-scrolls; bottom input `TextField` (placeholder "Tell me what to do — try: Submit my
  massage claim") + Send, disabled while working; plain-English status chip ("Ready" /
  "Thinking…" / "Working in the browser…" / "Replaying — step 3 of 14" / "Demo mode").
- `AgentBrowserPaneView.swift`: fake browser chrome (three dots + URL pill + page title)
  over a scrollable render of `BrowserPage`: headings `.title2.bold()`, texts `.body`,
  textboxes as rounded read-only fields with floating label, buttons as
  `.borderedProminent` (disabled state respected), radios as circle/checkmark rows,
  comboboxes as a labeled value row that expands to an option list when open; the
  `lastActedElementID` element gets an accent ring that fades (~1 s animation). A footer
  progress bar during replay ("Step N of M"). Everything read-only — the agent drives.
- `AutomationShelfView.swift`: left column (~300 pt). Header "Things I can do for you".
  Cards: name (headline), summary (caption), big `▶ Run` button; context-menu Delete.
  Empty state: "When the assistant finishes a task, save it here and replay it any time
  with one click." Footer: red `●` "Recording" indicator while a session captures steps,
  and a "Save as automation…" button (enabled when `canSaveAutomation`) opening a sheet:
  Name + one-line "What does it do?" + Save.
- `AgentWorkspaceSelfTest.swift`: `enum AgentWorkspaceSelfTest { static func run() -> Never }`
  headless harness for the `--agent-workspace-self-test` flag: engine+client+recorder
  end-to-end against the mock scenario (locate node via `AgentHarnessLocator`; if node
  missing print `⚠ node not found — agent workspace self-test skipped` and `exit(0)`);
  asserts final URL `/claim/done`, ≥ 8 recorded steps, save→list→replay on a fresh portal
  succeeds, `SKILL.md` exists; then lays out `AgentWorkspaceView` in an `NSHostingView`
  (600×400 offscreen) as a smoke check; numbered exit codes via local
  `func fail(_ message: String, code: Int32) -> Never`. Accessibility identifiers:
  `agent-terminal`, `agent-browser-pane`, `automation-shelf`.

Wiring (done by the integrator, not implementer agents): one
`if CommandLine.arguments.contains("--agent-workspace-self-test")` block in
`MyIDEApp.init`; a `CommandMenu("Assistant")` with "Open Assistant" (⇧⌘A); `--assistant`
launch flag opens the workspace window on start; `build.sh` copies `harness/` (minus
`node_modules`) into `Contents/Resources/`.

## Tests (Sources/MyIDESelfTest/AgentWorkspaceChecks.swift)

`func runAgentWorkspaceChecks()` using the module-global `section(_:)` / `check(_:_:)`
helpers from `main.swift` (call added at end of `main.swift` by the integrator). Cover:
snapshot format + ref assignment; stale-ref after navigation; label selectors; quoted-arg
parsing; radio click gotcha + press Space; combobox open/ArrowDown/Enter + fill rejection;
disabled Continue reasons; expense validation messages; full wizard walk to
"Claim successfully submitted!" with correct total; recorder canonical-label rewriting and
read-only/failure skipping; store save/list/delete round-trip in a temp dir; generated
SKILL.md content; `AutomationReplay` end-to-end on a fresh portal; `HarnessWire`
encode/decode round-trips + malformed-line tolerance; `NDJSONLineBuffer` split-chunk
reassembly. Pure logic only — no processes, no UI.
