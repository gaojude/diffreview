import Foundation

/// Spawns and supervises the agent harness sidecar (`node agent-harness.mjs`)
/// and shuttles NDJSON messages both ways. Follows the house subprocess rules:
/// both output pipes are drained via readability handlers (a full pipe buffer
/// deadlocks the child), state is lock-protected, and no public API throws.
public final class AgentHarnessClient {
    public struct LaunchSpec {
        public var nodeURL: URL
        public var scriptURL: URL
        public var arguments: [String]
        public var environment: [String: String]?

        public init(nodeURL: URL, scriptURL: URL, arguments: [String] = [], environment: [String: String]? = nil) {
            self.nodeURL = nodeURL
            self.scriptURL = scriptURL
            self.arguments = arguments
            self.environment = environment
        }
    }

    public enum LaunchResult: Equatable {
        case running
        case failed(String)
    }

    private let lock = NSLock()
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var buffer = NDJSONLineBuffer()
    private var stderrTail = ""

    /// Callbacks fire on a private serial queue; hop to the main actor yourself.
    private let deliveryQueue = DispatchQueue(label: "com.judegao.myide.agent-harness", qos: .userInitiated)
    public var onMessage: ((HarnessMessage) -> Void)?
    public var onTermination: ((Int32) -> Void)?

    public init() {}

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return process?.isRunning ?? false
    }

    /// The last few KB of the harness's stderr — surfaced in error paths so a
    /// dead sidecar can explain itself.
    public var recentStderr: String {
        lock.lock()
        defer { lock.unlock() }
        return stderrTail
    }

    // MARK: - Lifecycle

    public func launch(_ spec: LaunchSpec) -> LaunchResult {
        lock.lock()
        if process?.isRunning == true {
            lock.unlock()
            return .failed("The harness is already running.")
        }
        lock.unlock()

        let child = Process()
        child.executableURL = spec.nodeURL
        child.arguments = [spec.scriptURL.path] + spec.arguments
        child.currentDirectoryURL = spec.scriptURL.deletingLastPathComponent()
        if let environment = spec.environment {
            child.environment = environment
        }

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self.lock.lock()
            let lines = self.buffer.append(chunk)
            self.lock.unlock()
            for line in lines {
                guard let message = HarnessWire.decode(line) else { continue }
                self.deliveryQueue.async { self.onMessage?(message) }
            }
        }

        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            guard let text = String(data: chunk, encoding: .utf8) else { return }
            self.lock.lock()
            self.stderrTail = String((self.stderrTail + text).suffix(4_096))
            self.lock.unlock()
        }

        child.terminationHandler = { [weak self] finished in
            guard let self else { return }
            let status = finished.terminationStatus
            self.lock.lock()
            self.process = nil
            self.stdinHandle = nil
            self.lock.unlock()
            self.deliveryQueue.async { self.onTermination?(status) }
        }

        do {
            try child.run()
        } catch {
            return .failed("Could not start the harness: \(error.localizedDescription)")
        }

        lock.lock()
        process = child
        stdinHandle = stdin.fileHandleForWriting
        buffer = NDJSONLineBuffer()
        stderrTail = ""
        lock.unlock()
        return .running
    }

    public func send(_ message: AppToHarnessMessage) {
        lock.lock()
        let handle = stdinHandle
        lock.unlock()
        guard let handle else { return }
        let line = HarnessWire.encode(message) + "\n"
        // write(contentsOf:) throws instead of raising when the pipe is gone —
        // a dying harness must never take the app down with it.
        try? handle.write(contentsOf: Data(line.utf8))
    }

    /// Asks the harness to exit, then makes sure it does. Safe to call twice.
    public func stop() {
        lock.lock()
        let child = process
        lock.unlock()
        guard let child, child.isRunning else { return }

        send(.shutdown)
        lock.lock()
        try? stdinHandle?.close()
        stdinHandle = nil
        lock.unlock()

        // Give it a moment to exit cleanly before pulling the plug.
        let deadline = Date().addingTimeInterval(0.5)
        while child.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if child.isRunning {
            child.terminate()
        }
    }

    deinit {
        stop()
    }
}

// MARK: - Discovery

public enum AgentHarnessLocator {
    /// Finds a `node` binary the way `TSServer` does — PATH first, then the
    /// usual install locations, because a Finder-launched app has a minimal PATH.
    public static func findNode(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let fileManager = FileManager.default
        var candidates: [URL] = []
        if let path = environment["PATH"] {
            candidates += path.split(separator: ":").map { URL(fileURLWithPath: String($0), isDirectory: true) }
        }
        let home = fileManager.homeDirectoryForCurrentUser
        candidates += [
            URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
            home.appendingPathComponent(".volta/bin", isDirectory: true),
        ]
        candidates += versionedBinDirectories(under: home.appendingPathComponent(".nvm/versions/node", isDirectory: true))
        candidates += versionedBinDirectories(under: home.appendingPathComponent(".local", isDirectory: true))

        for directory in candidates {
            let node = directory.appendingPathComponent("node")
            if fileManager.isExecutableFile(atPath: node.path) {
                return node
            }
        }
        return nil
    }

    /// `<base>/*/bin`, newest name first (good enough for version-named dirs).
    private static func versionedBinDirectories(under base: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: base,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return entries
            .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
            .map { $0.appendingPathComponent("bin", isDirectory: true) }
    }

    /// Walks up from each starting directory (≤ 12 levels) looking for
    /// `harness/agent-harness.mjs` — finds the sidecar whether the app runs
    /// from a repo checkout or from inside the built bundle's Resources.
    public static func findHarnessScript(startingFrom directories: [URL]) -> URL? {
        let fileManager = FileManager.default
        for start in directories {
            var current = start.standardizedFileURL
            for _ in 0..<12 {
                let candidate = current.appendingPathComponent("harness/agent-harness.mjs")
                if fileManager.fileExists(atPath: candidate.path) {
                    return candidate
                }
                let parent = current.deletingLastPathComponent()
                if parent.path == current.path { break }
                current = parent
            }
        }
        return nil
    }
}
