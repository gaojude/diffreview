import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Owns a real, headed Chrome dedicated to the Assistant: launches it with a
/// remote-debugging port and a persistent profile directory, checks whether it
/// is still alive, and relaunches it when the user closes it. This is what
/// lets the agent recover from "I closed the browser" — attaching alone can't,
/// because a dead CDP endpoint has nothing to reconnect to.
///
/// The profile directory is persistent, so logins survive Chrome restarts at
/// the profile level too (complementing the explicit save/restore feature).
public final class ChromeProcessManager {
    public struct Config: Sendable {
        public var chromeBinaryURL: URL
        public var port: Int
        public var userDataDir: URL

        public init(chromeBinaryURL: URL, port: Int, userDataDir: URL) {
            self.chromeBinaryURL = chromeBinaryURL
            self.port = port
            self.userDataDir = userDataDir
        }
    }

    public enum EnsureResult: Equatable {
        case alreadyRunning
        case launched
        case failed(String)
    }

    private let config: Config
    private let lock = NSLock()
    private var launchedProcess: Process?

    public init(config: Config) {
        self.config = config
    }

    public var port: Int { config.port }

    // MARK: - Discovery

    /// Finds a Chromium-family browser that understands `--remote-debugging-port`.
    /// Chrome first, then common Chromium-based siblings.
    public static func discoverChrome() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            home.appendingPathComponent("Applications/Google Chrome.app/Contents/MacOS/Google Chrome").path,
            "/Applications/Chromium.app/Contents/MacOS/Chromium",
            "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
            "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    public static func defaultUserDataDir() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("MyIDE/ChromeProfile", isDirectory: true)
    }

    // MARK: - Liveness

    /// True when something is listening on the debug port — the fast, ATS-free
    /// liveness signal (a raw loopback TCP connect, not an HTTP request).
    public func isRunning(timeout: TimeInterval = 1.0) -> Bool {
        Self.isPortOpen(host: "127.0.0.1", port: config.port, timeout: timeout)
    }

    /// Ensures a debug Chrome is up, launching one if needed and waiting for
    /// the port to accept connections. Safe to call before every command.
    @discardableResult
    public func ensureRunning(waitUpTo: TimeInterval = 15) -> EnsureResult {
        lock.lock()
        defer { lock.unlock() }

        if isRunning() { return .alreadyRunning }

        do {
            try FileManager.default.createDirectory(at: config.userDataDir, withIntermediateDirectories: true)
        } catch {
            return .failed("Could not create the browser profile folder: \(error.localizedDescription)")
        }

        let process = Process()
        process.executableURL = config.chromeBinaryURL
        // One clean initial tab that the agent's first `open` reuses. We do NOT
        // pass --restore-last-session: it reopens old tabs AND leaves the fresh
        // blank behind, which is exactly the stray blank page users complained
        // about on every relaunch.
        process.arguments = [
            "--remote-debugging-port=\(config.port)",
            "--user-data-dir=\(config.userDataDir.path)",
            "--no-first-run",
            "--no-default-browser-check",
            "about:blank",
        ]
        // Chrome is chatty on stderr; keep it off our pipes.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return .failed("Could not launch Chrome: \(error.localizedDescription)")
        }
        launchedProcess = process

        // Wait for the debugging endpoint to come up.
        let deadline = Date().addingTimeInterval(waitUpTo)
        while Date() < deadline {
            if Self.isPortOpen(host: "127.0.0.1", port: config.port, timeout: 0.5) {
                return .launched
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return .failed("Chrome started but its debugging port \(config.port) never opened.")
    }

    // MARK: - Socket probe

    private static func isPortOpen(host: String, port: Int, timeout: TimeInterval) -> Bool {
        #if canImport(Darwin)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        // Non-blocking so connect() can be bounded by select().
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port)).bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return false }

        let connectResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connectResult == 0 { return true }          // connected immediately
        if errno != EINPROGRESS { return false }

        var writeSet = fd_set()
        Self.fdZero(&writeSet)
        Self.fdSet(fd, &writeSet)
        var tv = timeval(
            tv_sec: Int(timeout),
            tv_usec: __darwin_suseconds_t((timeout - floor(timeout)) * 1_000_000)
        )
        let selected = select(fd + 1, nil, &writeSet, nil, &tv)
        guard selected > 0 else { return false }

        // Confirm the connection actually succeeded (no SO_ERROR).
        var soError: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len) == 0 else { return false }
        return soError == 0
        #else
        return false
        #endif
    }

    #if canImport(Darwin)
    private static func fdZero(_ set: inout fd_set) {
        set.fds_bits = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    private static func fdSet(_ fd: Int32, _ set: inout fd_set) {
        let intOffset = Int(fd) / 32
        let bitOffset = Int(fd) % 32
        let mask = Int32(1 << bitOffset)
        withUnsafeMutablePointer(to: &set.fds_bits) { pointer in
            pointer.withMemoryRebound(to: Int32.self, capacity: 32) { bits in
                bits[intOffset] |= mask
            }
        }
    }
    #endif
}
