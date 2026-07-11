import Foundation

/// Executes agent-browser commands against the REAL `agent-browser` CLI —
/// headed Chrome on real websites. Presents the same `execute(_:) ->
/// AgentBrowserCommandResult` surface as the mock engine, so the harness
/// protocol, transcript, recorder and replay all work unchanged; only the
/// pixels move from the in-app pane to an actual Chrome window.

// MARK: - Snapshot index

/// Parses real `agent-browser snapshot` output into a ref → (role, name) index.
/// Lines look like `- link "Research" [ref=e23]` or
/// `- button "Commitments" [expanded=false, ref=e25]`. Pure so the self-tests
/// can cover it without Chrome.
public struct RealSnapshotIndex: Sendable {
    public struct Entry: Equatable, Sendable {
        public var role: String
        public var name: String

        public init(role: String, name: String) {
            self.role = role
            self.name = name
        }
    }

    public private(set) var entries: [String: Entry] = [:]

    public init() {}

    public static func parse(_ snapshot: String) -> RealSnapshotIndex {
        var index = RealSnapshotIndex()
        for line in snapshot.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- ") else { continue }
            guard let refRange = trimmed.range(of: "ref=e[0-9]+", options: .regularExpression) else { continue }
            let ref = String(trimmed[refRange].dropFirst("ref=".count))
            let afterDash = trimmed.dropFirst(2)
            let role = String(afterDash.prefix(while: { $0 != " " }))
            var name = ""
            if let open = afterDash.firstIndex(of: "\"") {
                let rest = afterDash[afterDash.index(after: open)...]
                if let close = rest.firstIndex(of: "\"") {
                    name = String(rest[..<close])
                }
            }
            index.entries[ref] = Entry(role: role, name: name)
        }
        return index
    }

    /// Rewrites an `@eN`-targeted command to a semantic `find …` command that
    /// survives ref renumbering — what the recorder stores for replay.
    /// Returns nil when the ref is unknown or the element has no usable name.
    public func canonicalCommand(verb: String, ref: String, arguments: [String]) -> String? {
        guard let entry = entries[ref], !entry.name.isEmpty else { return nil }
        let inputRoles: Set<String> = ["textbox", "searchbox", "combobox", "checkbox", "radio", "slider", "spinbutton"]
        let locator = inputRoles.contains(entry.role) ? "label" : "text"
        var parts = ["find", locator, quoted(entry.name), verb]
        parts += arguments.map { $0.contains(" ") || $0.isEmpty ? quoted($0) : $0 }
        return parts.joined(separator: " ")
    }

    private func quoted(_ text: String) -> String { "\"\(text)\"" }
}

// MARK: - Real executor

public final class RealAgentBrowser {
    private let cliURL: URL
    private let sessionID: String
    /// CDP target ("9222" or a ws:// URL): link the session to an externally
    /// started Chrome. We do not own its lifecycle, so we cannot relaunch it.
    private let cdpTarget: String?
    /// Chrome profile name or path (e.g. "Default"): launch the managed browser
    /// with the user's real profile so their logins come along.
    private let chromeProfile: String?
    /// When set, the app OWNS a dedicated debug Chrome: it can detect the user
    /// closing it and relaunch — the recovery path a bare CDP attach can't do.
    private let chromeManager: ChromeProcessManager?
    /// Fires (off the calling thread) with plain-English notes worth surfacing,
    /// e.g. after the browser was reopened.
    public var onStatus: ((String) -> Void)?

    private var didConnectCDP = false
    private var hasSessionFlag = false

    /// True in either linked mode (external CDP or app-managed Chrome): `open`
    /// navigates the connected browser rather than launching a CLI one.
    private var isLinkedMode: Bool { cdpTarget != nil || chromeManager != nil }
    private var connectTarget: String? { cdpTarget ?? chromeManager.map { String($0.port) } }
    /// One CLI invocation at a time — commands are inherently sequential and
    /// the caller may be a background queue plus a replay task.
    private let lock = NSLock()
    private var snapshotIndex = RealSnapshotIndex()

    /// True once an `open` or CDP attach succeeded — i.e. `get url`/`get title`
    /// can be asked without triggering the CLI's browser auto-launch.
    public var hasActiveSession: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasSessionFlag
    }

    /// Command verbs that never make sense from an in-app agent session:
    /// credential and vault management stay with the human, and lifecycle /
    /// plugin commands would fight the app's own session management.
    private static let refusedVerbs: Set<String> = ["auth", "install", "plugin", "mcp", "skills", "daemon"]

    /// Element-targeted verbs whose `@eN` form gets canonicalized for replay.
    private static let elementVerbs: Set<String> = [
        "click", "dblclick", "hover", "focus", "fill", "type", "check", "uncheck",
        "select", "upload", "scrollintoview",
    ]

    public init(
        cliURL: URL,
        sessionID: String = "myide-assistant",
        cdpTarget: String? = nil,
        chromeProfile: String? = nil,
        chromeManager: ChromeProcessManager? = nil
    ) {
        self.cliURL = cliURL
        self.sessionID = sessionID
        self.cdpTarget = cdpTarget
        self.chromeProfile = chromeProfile
        self.chromeManager = chromeManager
    }

    /// Blocking — run off the main thread. Output is capped so a huge page
    /// can't blow up the transcript or the model context.
    @discardableResult
    public func execute(_ commandLine: String) -> AgentBrowserCommandResult {
        lock.lock()
        defer { lock.unlock() }

        var tokens = AgentBrowserEngine.tokenize(commandLine)
        guard let verb = tokens.first else {
            return AgentBrowserCommandResult(ok: false, output: "Empty command.")
        }
        if Self.refusedVerbs.contains(verb) {
            return AgentBrowserCommandResult(
                ok: false,
                output: "\"\(verb)\" is disabled here. For sign-ins, ask the user to log in manually in the Chrome window, then continue."
            )
        }

        // Linked-to-real-Chrome mode: make sure the browser is up and attached
        // before the command. `connect` itself is exempt (it IS the attach).
        if isLinkedMode, verb != "connect" {
            if let error = ensureConnectedLocked() {
                return AgentBrowserCommandResult(ok: false, output: error)
            }
        } else if verb == "open" {
            // CLI-launched real browser (no link): a window the user can watch.
            if !tokens.contains("--headed"), !tokens.contains("--headless") {
                tokens.insert("--headed", at: 1)
            }
            if let profile = chromeProfile, !tokens.contains("--profile") {
                tokens.append(contentsOf: ["--profile", profile])
            }
        }

        var result = run(arguments: ["--session", sessionID] + tokens)

        // Recover from a browser the user closed mid-session: if a managed
        // Chrome's port went dark, relaunch, reconnect, and retry once.
        if !result.ok, chromeManager != nil, !chromeManager!.isRunning(), verb != "connect" {
            didConnectCDP = false
            hasSessionFlag = false
            if ensureConnectedLocked() == nil {
                result = run(arguments: ["--session", sessionID] + tokens)
            }
        }

        if result.ok {
            if verb == "open" { hasSessionFlag = true }
            if verb == "close" { hasSessionFlag = false }
        }
        if verb == "snapshot", result.ok {
            snapshotIndex = RealSnapshotIndex.parse(result.output)
        }

        var canonical: String? = tokens.joined(separator: " ")
        if Self.elementVerbs.contains(verb), tokens.count >= 2, tokens[1].hasPrefix("@") {
            canonical = snapshotIndex.canonicalCommand(
                verb: verb,
                ref: String(tokens[1].dropFirst()),
                arguments: Array(tokens.dropFirst(2))
            ) ?? commandLine
        }

        return AgentBrowserCommandResult(
            ok: result.ok,
            output: result.output,
            canonicalCommand: result.ok ? canonical : nil
        )
    }

    /// Ends the CLI's browser session (used on window close and before replays).
    /// In any linked mode (external CDP or app-managed Chrome) this is a no-op —
    /// we never close a browser we want to persist across the session.
    public func closeSession() {
        guard !isLinkedMode else { return }
        _ = execute("close")
    }

    /// The current browser URL, or nil if none/unavailable — a cheap way for
    /// callers to check "is a page actually open right now?".
    public func currentURL() -> String? {
        let result = execute("get url")
        guard result.ok, !result.output.isEmpty, result.output != "about:blank" else { return nil }
        return result.output
    }

    // MARK: - Connection management

    /// Ensures the linked browser is running and attached. In managed mode this
    /// relaunches a Chrome the user closed; in external-CDP mode it can only
    /// (re)attach. Returns nil on success, or a user-facing error. Lock held.
    private func ensureConnectedLocked() -> String? {
        // Managed Chrome: relaunch if the user closed it.
        if let manager = chromeManager {
            if !manager.isRunning() {
                didConnectCDP = false
                hasSessionFlag = false
                switch manager.ensureRunning() {
                case .failed(let message):
                    return "I couldn't open Chrome: \(message)"
                case .launched:
                    onStatus?("The browser wasn't open, so I opened a fresh Chrome window for you.")
                case .alreadyRunning:
                    break
                }
            }
        }

        guard !didConnectCDP, let target = connectTarget else { return nil }
        let connect = run(arguments: ["--session", sessionID, "connect", target])
        guard connect.ok else {
            if cdpTarget != nil {
                return "Could not attach to your Chrome at \(target): \(connect.output)\nStart Chrome with remote debugging: open -a \"Google Chrome\" --args --remote-debugging-port=\(target)"
            }
            return "Could not connect to the browser: \(connect.output)"
        }
        didConnectCDP = true
        hasSessionFlag = true
        return nil
    }

    // MARK: - Login state (save / restore)

    /// Saves the live browser's cookies + storage to `fileURL` via
    /// `agent-browser state save`. Blocking — run off the main thread.
    public func saveState(to fileURL: URL) -> AgentBrowserCommandResult {
        lock.lock()
        defer { lock.unlock() }
        if isLinkedMode {
            if let error = ensureConnectedLocked() {
                return AgentBrowserCommandResult(ok: false, output: error)
            }
        } else if !hasSessionFlag {
            return AgentBrowserCommandResult(ok: false, output: "Open a page first, then save the login.")
        }
        let result = run(arguments: ["--session", sessionID, "state", "save", fileURL.path])
        return AgentBrowserCommandResult(ok: result.ok, output: result.output)
    }

    /// Restores cookies + storage from `fileURL` into the current session, then
    /// reloads so the page reflects the restored login. Ensures a page exists
    /// first (the CLI needs a live context to load state into).
    public func loadState(from fileURL: URL) -> AgentBrowserCommandResult {
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return AgentBrowserCommandResult(ok: false, output: "That saved login is missing on disk.")
        }
        // Attach/launch as needed so there's a context to load into.
        if isLinkedMode {
            if let error = ensureConnectedLocked() {
                return AgentBrowserCommandResult(ok: false, output: error)
            }
        } else if !hasSessionFlag {
            var open = ["--session", sessionID, "open", "--headed"]
            if let profile = chromeProfile { open += ["--profile", profile] }
            let opened = run(arguments: open)
            guard opened.ok else {
                return AgentBrowserCommandResult(ok: false, output: "Could not open a browser to restore into: \(opened.output)")
            }
            hasSessionFlag = true
        }
        let load = run(arguments: ["--session", sessionID, "state", "load", fileURL.path])
        guard load.ok else { return AgentBrowserCommandResult(ok: false, output: load.output) }
        _ = run(arguments: ["--session", sessionID, "reload"])
        return AgentBrowserCommandResult(ok: true, output: "Login restored.")
    }

    // MARK: - Process plumbing

    private struct CLIResult {
        var ok: Bool
        var output: String
    }

    private func run(arguments: [String]) -> CLIResult {
        let process = Process()
        process.executableURL = cliURL
        process.arguments = arguments
        // Immediate EOF on stdin: a command that tries to read (eval --stdin)
        // fails fast instead of hanging the session.
        process.standardInput = FileHandle.nullDevice

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        // Drain both pipes off-thread before waiting — the ~64 KB pipe buffer
        // deadlocks the child on big snapshots otherwise.
        var stdoutData = Data()
        var stderrData = Data()
        let drained = DispatchGroup()
        drained.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
            drained.leave()
        }
        drained.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
            drained.leave()
        }

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }

        do {
            try process.run()
        } catch {
            return CLIResult(ok: false, output: "Could not run agent-browser: \(error.localizedDescription)")
        }

        // The CLI's own waits time out at 25 s; 90 s means something is stuck.
        if finished.wait(timeout: .now() + 90) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 5)
            return CLIResult(ok: false, output: "agent-browser timed out after 90s — the browser may be stuck; try a snapshot or reload.")
        }
        drained.wait()

        let out = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let err = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let ok = process.terminationStatus == 0
        var output = out
        if !ok || output.isEmpty {
            output = [out, err].filter { !$0.isEmpty }.joined(separator: "\n")
        }
        if output.isEmpty {
            output = ok ? "ok" : "agent-browser exited with code \(process.terminationStatus)"
        }
        if output.count > 16_000 {
            output = String(output.prefix(16_000)) + "\n… [truncated]"
        }
        return CLIResult(ok: ok, output: output)
    }
}
