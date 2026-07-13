import Foundation

/// The pull request GitHub associates with the reviewed branch, as reported by `gh pr view`.
public struct GitHubPullRequest: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case open
        case merged
        case closed
        /// A state string this build doesn't know. Preserved verbatim so the UI can still
        /// show something truthful if GitHub grows new states.
        case unknown(String)
    }

    public let number: Int
    public let title: String
    public let url: URL
    public let state: State
    public let isDraft: Bool

    public init(number: Int, title: String, url: URL, state: State, isDraft: Bool) {
        self.number = number
        self.title = title
        self.url = url
        self.state = state
        self.isDraft = isDraft
    }
}

/// Resolves the reviewed branch to its pull request by asking the GitHub CLI:
/// `gh pr view --json …` in the opened directory. gh matches by branch name using its own
/// auth, so detection survives local unpushed commits and works on private repos. Every
/// failure (no gh, not logged in, no PR, not GitHub) collapses to `nil` — the feature
/// simply doesn't appear.
public enum GitHubPullRequestLocator {
    /// gh answers fast or fails fast; a hung network call must not pin a zombie `gh`
    /// process to the app for minutes.
    static let timeout: TimeInterval = 10

    public static func detect(in directory: URL) -> GitHubPullRequest? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["gh", "pr", "view", "--json", "number,title,url,state,isDraft"]
        process.currentDirectoryURL = directory
        process.environment = environmentWithSearchPaths(ProcessInfo.processInfo.environment)
        process.standardError = FileHandle.nullDevice

        let stdout = Pipe()
        process.standardOutput = stdout

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            return nil
        }

        // Drain stdout off-thread before waiting, same as GitChangeSet.runGit: a child
        // writing more than the pipe buffer blocks until someone reads.
        var stdoutData = Data()
        let stdoutDrained = DispatchSemaphore(value: 0)
        let stdoutHandle = stdout.fileHandleForReading
        DispatchQueue.global(qos: .utility).async {
            stdoutData = stdoutHandle.readDataToEndOfFile()
            stdoutDrained.signal()
        }

        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }
        stdoutDrained.wait()

        guard process.terminationStatus == 0 else { return nil }
        return parse(stdoutData)
    }

    /// Decodes `gh pr view --json number,title,url,state,isDraft` output, e.g.
    /// `{"isDraft":false,"number":1,"state":"MERGED","title":"…","url":"https://…/pull/1"}`.
    public static func parse(_ data: Data) -> GitHubPullRequest? {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let url = URL(string: payload.url) else {
            return nil
        }
        let state: GitHubPullRequest.State
        switch payload.state {
        case "OPEN": state = .open
        case "MERGED": state = .merged
        case "CLOSED": state = .closed
        default: state = .unknown(payload.state)
        }
        return GitHubPullRequest(
            number: payload.number,
            title: payload.title,
            url: url,
            state: state,
            isDraft: payload.isDraft
        )
    }

    /// A GUI-launched app inherits the minimal system PATH (`/usr/bin:/bin:…`), which is why
    /// plain `env gh` fails outside a terminal. Homebrew installs gh under /opt/homebrew/bin
    /// (Apple Silicon) or /usr/local/bin (Intel); append both so the same build works from
    /// Finder, the `diffreview` shim, and a terminal.
    public static func environmentWithSearchPaths(_ base: [String: String]) -> [String: String] {
        var environment = base
        let current = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let extra = ["/opt/homebrew/bin", "/usr/local/bin"].filter { !current.contains($0) }
        environment["PATH"] = (current + extra).joined(separator: ":")
        environment["GH_NO_UPDATE_NOTIFIER"] = "1"
        environment["GH_PROMPT_DISABLED"] = "1"
        return environment
    }

    private struct Payload: Decodable {
        let number: Int
        let title: String
        let url: String
        let state: String
        let isDraft: Bool
    }
}
