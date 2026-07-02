import Foundation

/// A mock of the `agent-browser` CLI's API surface: commands (`open`, `snapshot`,
/// `click`, `fill`, `type`, `press`, `get`, …), accessibility-tree snapshots with
/// compact `@eN` element refs, and the ref-staleness semantics agents have to cope
/// with on real pages. Foundation-only so `MyIDESelfTest` can exercise every
/// behavior — the SwiftUI browser pane is just a renderer over `BrowserPage`.

// MARK: - Page model

public struct BrowserElement: Equatable, Sendable {
    public enum Role: String, Sendable {
        case heading, text, textbox, button, radio, combobox, option, link
    }

    /// Stable semantic id (e.g. `login.username`). Refs are ephemeral; ids are how
    /// the mock site addresses elements across renders.
    public var id: String
    public var role: Role
    public var label: String
    public var value: String
    public var checked: Bool
    public var disabled: Bool
    public var highlighted: Bool
    public var children: [BrowserElement]

    public init(
        id: String,
        role: Role,
        label: String,
        value: String = "",
        checked: Bool = false,
        disabled: Bool = false,
        highlighted: Bool = false,
        children: [BrowserElement] = []
    ) {
        self.id = id
        self.role = role
        self.label = label
        self.value = value
        self.checked = checked
        self.disabled = disabled
        self.highlighted = highlighted
        self.children = children
    }
}

public struct BrowserPage: Equatable, Sendable {
    public var url: String
    public var title: String
    public var elements: [BrowserElement]

    public init(url: String, title: String, elements: [BrowserElement]) {
        self.url = url
        self.title = title
        self.elements = elements
    }
}

// MARK: - Actions

public enum BrowserKey: String, Sendable {
    case space = "Space"
    case enter = "Enter"
    case arrowDown = "ArrowDown"
    case arrowUp = "ArrowUp"
    case backspace = "Backspace"
    case tab = "Tab"
}

public enum BrowserAction: Equatable, Sendable {
    case click
    case setValue(String)
    case press(BrowserKey)
}

public struct BrowserActionOutcome {
    public var ok: Bool
    public var message: String
    /// Absolute URL to navigate to after a successful action (e.g. a submit).
    public var navigateTo: String?

    public init(ok: Bool, message: String, navigateTo: String? = nil) {
        self.ok = ok
        self.message = message
        self.navigateTo = navigateTo
    }
}

/// A deterministic fake web site: pages are pure renders of the site's internal
/// state, and actions mutate that state. Class-bound because sites are stateful.
public protocol MockWebSite: AnyObject {
    /// Host this site answers for, e.g. `portal.maplelife.example`.
    var host: String { get }
    /// Render the page at `url`, or nil when the path does not exist. Sites handle
    /// their own auth redirects here (the returned page's `url` is authoritative).
    func page(for url: String) -> BrowserPage?
    func perform(_ action: BrowserAction, on elementID: String) -> BrowserActionOutcome
    func reset()
}

// MARK: - Command results

public struct AgentBrowserCommandResult: Equatable, Sendable {
    public var ok: Bool
    public var output: String
    /// The quoted-label form of a successful element-targeted command
    /// (`click "Sign in"`). Refs renumber on every snapshot, so this — not the
    /// `@eN` form the agent typed — is what recorded automations store.
    public var canonicalCommand: String?

    public init(ok: Bool, output: String, canonicalCommand: String? = nil) {
        self.ok = ok
        self.output = output
        self.canonicalCommand = canonicalCommand
    }
}

public enum AgentBrowserEngineEvent {
    case pageChanged
    case commandExecuted(command: String, result: AgentBrowserCommandResult)
}

// MARK: - Engine

/// Executes agent-browser command lines against mock sites. Not thread-safe;
/// callers confine it (the app's controller keeps it on the main actor).
public final class AgentBrowserEngine {
    private let sites: [MockWebSite]
    public private(set) var currentURL: String?
    public private(set) var lastActedElementID: String?
    public var onEvent: ((AgentBrowserEngineEvent) -> Void)?

    /// Refs handed out by the last `snapshot`, mapped to element ids, plus the URL
    /// they were captured against — the staleness check mimics the real CLI.
    private var snapshotRefs: [String: String] = [:]
    private var snapshotURL: String?

    public init(sites: [MockWebSite]) {
        self.sites = sites
    }

    /// A fresh render of the current page (pages are functions of site state, so
    /// this is recomputed on every access).
    public var currentPage: BrowserPage? {
        guard let url = currentURL, let site = site(for: url) else { return nil }
        return site.page(for: url)
    }

    public func reset() {
        for site in sites { site.reset() }
        currentURL = nil
        lastActedElementID = nil
        snapshotRefs = [:]
        snapshotURL = nil
    }

    // MARK: - Command execution

    @discardableResult
    public func execute(_ commandLine: String) -> AgentBrowserCommandResult {
        let result = run(commandLine)
        onEvent?(.commandExecuted(command: commandLine, result: result))
        return result
    }

    private func run(_ commandLine: String) -> AgentBrowserCommandResult {
        let tokens = Self.tokenize(commandLine)
        guard let verb = tokens.first else {
            return AgentBrowserCommandResult(ok: false, output: "Empty command.")
        }

        switch verb {
        case "open":
            guard tokens.count >= 2 else {
                return AgentBrowserCommandResult(ok: false, output: "Usage: open <url>")
            }
            return open(tokens[1])
        case "snapshot":
            return snapshotCommand()
        case "screenshot":
            // The mock has no pixels; the accessibility snapshot is the picture.
            return snapshotCommand()
        case "click":
            return elementCommand(tokens: tokens, argCount: 0) { element, _ in
                (.click, "click \(Self.quote(element.label))")
            }
        case "fill":
            return elementCommand(tokens: tokens, argCount: 1) { element, args in
                (.setValue(args[0]), "fill \(Self.quote(element.label)) \(Self.quote(args[0]))")
            }
        case "type":
            return elementCommand(tokens: tokens, argCount: 1) { element, args in
                (.setValue(element.value + args[0]), "type \(Self.quote(element.label)) \(Self.quote(args[0]))")
            }
        case "press":
            guard tokens.count >= 3 else {
                return AgentBrowserCommandResult(ok: false, output: "Usage: press <target> <Key>")
            }
            guard let key = BrowserKey(rawValue: tokens[2]) else {
                return AgentBrowserCommandResult(
                    ok: false,
                    output: "Unknown key \"\(tokens[2])\" — use Space, Enter, ArrowDown, ArrowUp, Backspace or Tab."
                )
            }
            return elementCommand(tokens: tokens, argCount: 1) { element, _ in
                // Backspace edits textboxes directly; everything else reaches the
                // site as a key press so custom widgets can implement their quirks.
                if key == .backspace, element.role == .textbox {
                    return (.setValue(String(element.value.dropLast())), "press \(Self.quote(element.label)) \(key.rawValue)")
                }
                return (.press(key), "press \(Self.quote(element.label)) \(key.rawValue)")
            }
        case "get":
            return get(tokens: tokens)
        case "wait":
            return AgentBrowserCommandResult(ok: true, output: "idle")
        case "sleep":
            // Recorded sessions should not actually block the engine; the delay is
            // cosmetic in a deterministic mock.
            let seconds = tokens.count > 1 ? tokens[1] : "0"
            return AgentBrowserCommandResult(ok: true, output: "slept \(seconds)s")
        default:
            return AgentBrowserCommandResult(
                ok: false,
                output: "Unknown command \"\(verb)\" — try open, snapshot, click, fill, type, press, get, wait, sleep or screenshot."
            )
        }
    }

    // MARK: - Individual commands

    private func open(_ rawURL: String) -> AgentBrowserCommandResult {
        guard let site = site(for: rawURL) else {
            let hosts = sites.map { "https://\($0.host)" }.joined(separator: ", ")
            return AgentBrowserCommandResult(ok: false, output: "This demo can only open \(hosts) pages.")
        }
        guard let page = site.page(for: rawURL) else {
            return AgentBrowserCommandResult(ok: false, output: "Page not found: \(rawURL)")
        }
        // The rendered page's URL is authoritative — sites redirect internally
        // (e.g. unauthenticated paths render the sign-in page).
        currentURL = page.url
        onEvent?(.pageChanged)
        return AgentBrowserCommandResult(ok: true, output: "Opened \(page.url) — \(page.title)")
    }

    private func snapshotCommand() -> AgentBrowserCommandResult {
        guard currentPage != nil else {
            return AgentBrowserCommandResult(ok: false, output: "No page open — use open <url> first.")
        }
        return AgentBrowserCommandResult(ok: true, output: renderSnapshot())
    }

    private func get(tokens: [String]) -> AgentBrowserCommandResult {
        guard tokens.count >= 2 else {
            return AgentBrowserCommandResult(ok: false, output: "Usage: get value <target> | get url | get title")
        }
        switch tokens[1] {
        case "url":
            guard let url = currentURL else {
                return AgentBrowserCommandResult(ok: false, output: "No page open — use open <url> first.")
            }
            return AgentBrowserCommandResult(ok: true, output: url)
        case "title":
            guard let page = currentPage else {
                return AgentBrowserCommandResult(ok: false, output: "No page open — use open <url> first.")
            }
            return AgentBrowserCommandResult(ok: true, output: page.title)
        case "value":
            guard tokens.count >= 3 else {
                return AgentBrowserCommandResult(ok: false, output: "Usage: get value <target>")
            }
            switch resolveTarget(tokens[2]) {
            case .failure(let message):
                return AgentBrowserCommandResult(ok: false, output: message)
            case .success(let element):
                return AgentBrowserCommandResult(ok: true, output: element.value)
            }
        default:
            return AgentBrowserCommandResult(ok: false, output: "Usage: get value <target> | get url | get title")
        }
    }

    /// Shared shape of click/fill/type/press: resolve the target, ask the builder
    /// for the site action + canonical form, perform, and translate the outcome.
    private func elementCommand(
        tokens: [String],
        argCount: Int,
        build: (BrowserElement, [String]) -> (BrowserAction, String)
    ) -> AgentBrowserCommandResult {
        guard tokens.count >= 2 + argCount else {
            return AgentBrowserCommandResult(ok: false, output: "Missing target — use @eN from the last snapshot or a \"Quoted Label\".")
        }
        guard let url = currentURL, let site = site(for: url) else {
            return AgentBrowserCommandResult(ok: false, output: "No page open — use open <url> first.")
        }
        switch resolveTarget(tokens[1]) {
        case .failure(let message):
            return AgentBrowserCommandResult(ok: false, output: message)
        case .success(let element):
            let (action, canonical) = build(element, Array(tokens.dropFirst(2)))
            lastActedElementID = element.id
            let outcome = site.perform(action, on: element.id)
            if let destination = outcome.navigateTo {
                currentURL = destination
            }
            if outcome.ok {
                onEvent?(.pageChanged)
            }
            return AgentBrowserCommandResult(
                ok: outcome.ok,
                output: outcome.message,
                canonicalCommand: outcome.ok ? canonical : nil
            )
        }
    }

    // MARK: - Target resolution

    private enum TargetResolution {
        case success(BrowserElement)
        case failure(String)
    }

    private func resolveTarget(_ token: String) -> TargetResolution {
        guard let page = currentPage else {
            return .failure("No page open — use open <url> first.")
        }
        if token.hasPrefix("@") {
            let ref = String(token.dropFirst())
            guard snapshotURL != nil else {
                return .failure("No snapshot yet — run snapshot to get element refs.")
            }
            guard snapshotURL == currentURL else {
                return .failure("stale ref — take a new snapshot")
            }
            guard let elementID = snapshotRefs[ref] else {
                return .failure("Unknown ref @\(ref) — take a new snapshot.")
            }
            guard let element = Self.findElement(id: elementID, in: page.elements) else {
                return .failure("element not found — the page changed; take a new snapshot")
            }
            return .success(element)
        }
        guard let element = Self.findElement(label: token, in: page.elements) else {
            return .failure("No element labeled \(Self.quote(token)) on this page.")
        }
        return .success(element)
    }

    // MARK: - Snapshot rendering

    /// Renders the accessibility snapshot and hands out fresh `@eN` refs — the
    /// only moment refs are (re)assigned, exactly like the real CLI.
    public func renderSnapshot() -> String {
        guard let page = currentPage else { return "" }
        snapshotRefs = [:]
        snapshotURL = currentURL
        var lines = ["Page: \(page.title) (\(page.url))"]
        var nextRef = 1
        func walk(_ elements: [BrowserElement], depth: Int) {
            for element in elements {
                let ref = "e\(nextRef)"
                nextRef += 1
                snapshotRefs[ref] = element.id
                var line = String(repeating: "  ", count: depth)
                line += "- \(element.role.rawValue) \(Self.quote(element.label)) [ref=\(ref)]"
                if !element.value.isEmpty { line += " [value=\(element.value)]" }
                if element.checked { line += " [checked]" }
                if element.disabled { line += " [disabled]" }
                if element.highlighted { line += " [highlighted]" }
                lines.append(line)
                walk(element.children, depth: depth + 1)
            }
        }
        walk(page.elements, depth: 0)
        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    private func site(for url: String) -> MockWebSite? {
        guard let host = URL(string: url)?.host else { return nil }
        return sites.first { $0.host == host }
    }

    private static func findElement(id: String, in elements: [BrowserElement]) -> BrowserElement? {
        for element in elements {
            if element.id == id { return element }
            if let found = findElement(id: id, in: element.children) { return found }
        }
        return nil
    }

    private static func findElement(label: String, in elements: [BrowserElement]) -> BrowserElement? {
        for element in elements {
            if element.label == label { return element }
            if let found = findElement(label: label, in: element.children) { return found }
        }
        return nil
    }

    private static func quote(_ text: String) -> String { "\"\(text)\"" }

    /// Splits a command line into tokens, honoring double-quoted spans so labels
    /// and text arguments can contain spaces (`fill "Service date" "2026-06-14"`).
    static func tokenize(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        var tokenStarted = false
        for character in line {
            if character == "\"" {
                inQuotes.toggle()
                tokenStarted = true // "" is a legal (empty) token
                continue
            }
            if character == " " && !inQuotes {
                if tokenStarted {
                    tokens.append(current)
                    current = ""
                    tokenStarted = false
                }
                continue
            }
            current.append(character)
            tokenStarted = true
        }
        if tokenStarted {
            tokens.append(current)
        }
        return tokens
    }
}
