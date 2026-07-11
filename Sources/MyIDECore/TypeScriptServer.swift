import Foundation

/// A resolved definition target.
public struct TSFileSpan: Equatable, Sendable {
    public let file: String
    /// 1-based.
    public let line: Int
    /// 1-based column.
    public let offset: Int
    public let endLine: Int

    public init(file: String, line: Int, offset: Int, endLine: Int) {
        self.file = file
        self.line = line
        self.offset = offset
        self.endLine = endLine
    }
}

/// One usage of a symbol, from tsserver's `references` command.
public struct TSReference: Equatable, Sendable {
    public let file: String
    /// 1-based.
    public let line: Int
    public let offset: Int
    /// The full source line, for preview rows.
    public let lineText: String
    public let isDefinition: Bool

    public init(file: String, line: Int, offset: Int, lineText: String, isDefinition: Bool) {
        self.file = file
        self.line = line
        self.offset = offset
        self.lineText = lineText
        self.isDefinition = isDefinition
    }
}

public enum TSServerError: Error, Equatable {
    case toolchainNotFound(String)
    case unsupportedFile
    case notRunning
    case timedOut
    case failed(String)

    public var userMessage: String {
        switch self {
        case .toolchainNotFound(let detail):
            return detail
        case .unsupportedFile:
            return "Definitions are available for TypeScript/JavaScript files."
        case .notRunning:
            return "TypeScript service stopped — try again."
        case .timedOut:
            return "TypeScript service timed out."
        case .failed(let message):
            return message
        }
    }
}

/// Splits tsserver's stdout stream into complete JSON message bodies. tsserver frames each
/// message as `Content-Length: N\r\n\r\n<N bytes of JSON>` with optional newlines between
/// frames. Pure and incremental so it can be fed arbitrary chunk boundaries — exercised
/// directly by `MyIDESelfTest`.
public struct TSServerMessageBuffer: Sendable {
    private var data = Data()
    private static let headerMarker = Data("Content-Length: ".utf8)
    private static let headerTerminator = Data("\r\n\r\n".utf8)

    public init() {}

    public mutating func append(_ chunk: Data) -> [Data] {
        data.append(chunk)
        var bodies: [Data] = []

        while true {
            guard let markerRange = data.firstRange(of: Self.headerMarker) else { break }
            guard let terminatorRange = data.firstRange(
                of: Self.headerTerminator,
                in: markerRange.upperBound..<data.endIndex
            ) else {
                break // incomplete header
            }

            let lengthBytes = data.subdata(in: markerRange.upperBound..<terminatorRange.lowerBound)
            guard let length = Int(String(decoding: lengthBytes, as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)), length >= 0 else {
                // Corrupt header — drop through it so the stream can resynchronize.
                data.removeSubrange(data.startIndex..<terminatorRange.upperBound)
                continue
            }

            let bodyStart = terminatorRange.upperBound
            guard data.distance(from: bodyStart, to: data.endIndex) >= length else {
                break // incomplete body
            }
            let bodyEnd = data.index(bodyStart, offsetBy: length)
            bodies.append(data.subdata(in: bodyStart..<bodyEnd))
            data.removeSubrange(data.startIndex..<bodyEnd)
        }

        return bodies
    }
}

/// Minimal client for the TypeScript language service (`tsserver`), used for go-to-definition.
/// Speaks tsserver's native protocol: newline-terminated JSON requests on stdin,
/// `Content-Length`-framed JSON messages on stdout.
///
/// All public methods are thread-safe and blocking — call them off the main thread.
public final class TSServer {
    public struct Toolchain: Equatable, Sendable {
        public let nodeURL: URL
        public let tsserverURL: URL

        public init(nodeURL: URL, tsserverURL: URL) {
            self.nodeURL = nodeURL
            self.tsserverURL = tsserverURL
        }
    }

    public static let supportedExtensions: Set<String> = [
        "ts", "tsx", "mts", "cts", "js", "jsx", "mjs", "cjs",
    ]

    private let process = Process()
    private let stdinHandle: FileHandle
    private let condition = NSCondition()
    private var messageBuffer = TSServerMessageBuffer()
    private var responsesBySeq: [Int: [String: Any]] = [:]
    private var nextSeq = 1
    private var openFiles: Set<String> = []
    private var running = false

    public init(toolchain: Toolchain) throws {
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        stdinHandle = stdinPipe.fileHandleForWriting

        process.executableURL = toolchain.nodeURL
        process.arguments = [toolchain.tsserverURL.path]
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        running = true

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let chunk = handle.availableData
            self.condition.lock()
            defer { self.condition.unlock() }
            if chunk.isEmpty {
                self.running = false
                handle.readabilityHandler = nil
            } else {
                for body in self.messageBuffer.append(chunk) {
                    guard
                        let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                        object["type"] as? String == "response",
                        let requestSeq = object["request_seq"] as? Int
                    else {
                        continue // events and malformed frames are irrelevant here
                    }
                    self.responsesBySeq[requestSeq] = object
                }
            }
            self.condition.broadcast()
        }
    }

    deinit {
        shutdown()
    }

    public func shutdown() {
        condition.lock()
        running = false
        condition.unlock()
        if process.isRunning {
            process.terminate()
        }
    }

    /// Definitions for the symbol at 1-based `line`/`offset` in `file`. Opens the file in the
    /// service on first use (tsserver reads content from disk).
    public func definition(
        file: String,
        line: Int,
        offset: Int,
        timeout: TimeInterval = 12
    ) -> Result<[TSFileSpan], TSServerError> {
        condition.lock()
        defer { condition.unlock() }
        guard running else { return .failure(.notRunning) }

        if !openFiles.contains(file) {
            openFiles.insert(file)
            send(command: "open", arguments: ["file": file], seq: takeSeq())
        }

        let seq = takeSeq()
        send(command: "definition", arguments: ["file": file, "line": line, "offset": offset], seq: seq)

        let deadline = Date().addingTimeInterval(timeout)
        while responsesBySeq[seq] == nil, running {
            if !condition.wait(until: deadline) {
                return .failure(.timedOut)
            }
        }
        guard let response = responsesBySeq.removeValue(forKey: seq) else {
            return .failure(.notRunning)
        }

        guard response["success"] as? Bool == true else {
            let message = response["message"] as? String ?? "Definition lookup failed."
            return .failure(.failed(message))
        }
        let body = response["body"] as? [[String: Any]] ?? []
        let spans = body.compactMap { item -> TSFileSpan? in
            guard
                let file = item["file"] as? String,
                let start = item["start"] as? [String: Any],
                let line = start["line"] as? Int,
                let offset = start["offset"] as? Int
            else {
                return nil
            }
            let end = item["end"] as? [String: Any]
            return TSFileSpan(
                file: file,
                line: line,
                offset: offset,
                endLine: end?["line"] as? Int ?? line
            )
        }
        return .success(spans)
    }

    /// Everywhere the symbol at 1-based `line`/`offset` is used (including its definition,
    /// flagged as such).
    public func references(
        file: String,
        line: Int,
        offset: Int,
        timeout: TimeInterval = 12
    ) -> Result<(symbolName: String?, references: [TSReference]), TSServerError> {
        condition.lock()
        defer { condition.unlock() }
        guard running else { return .failure(.notRunning) }

        if !openFiles.contains(file) {
            openFiles.insert(file)
            send(command: "open", arguments: ["file": file], seq: takeSeq())
        }

        let seq = takeSeq()
        send(command: "references", arguments: ["file": file, "line": line, "offset": offset], seq: seq)

        let deadline = Date().addingTimeInterval(timeout)
        while responsesBySeq[seq] == nil, running {
            if !condition.wait(until: deadline) {
                return .failure(.timedOut)
            }
        }
        guard let response = responsesBySeq.removeValue(forKey: seq) else {
            return .failure(.notRunning)
        }
        guard response["success"] as? Bool == true else {
            let message = response["message"] as? String ?? "Reference lookup failed."
            return .failure(.failed(message))
        }

        let body = response["body"] as? [String: Any] ?? [:]
        let symbolName = body["symbolName"] as? String
        let references = (body["refs"] as? [[String: Any]] ?? []).compactMap { item -> TSReference? in
            guard
                let file = item["file"] as? String,
                let start = item["start"] as? [String: Any],
                let line = start["line"] as? Int,
                let offset = start["offset"] as? Int
            else {
                return nil
            }
            return TSReference(
                file: file,
                line: line,
                offset: offset,
                lineText: (item["lineText"] as? String ?? "").trimmingCharacters(in: .whitespaces),
                isDefinition: item["isDefinition"] as? Bool ?? false
            )
        }
        return .success((symbolName, references))
    }

    private func takeSeq() -> Int {
        defer { nextSeq += 1 }
        return nextSeq
    }

    private func send(command: String, arguments: [String: Any], seq: Int) {
        let request: [String: Any] = [
            "seq": seq,
            "type": "request",
            "command": command,
            "arguments": arguments,
        ]
        guard var payload = try? JSONSerialization.data(withJSONObject: request) else { return }
        payload.append(0x0A)
        try? stdinHandle.write(contentsOf: payload)
    }

    // MARK: - Toolchain discovery

    /// Finds a `node` binary and a `tsserver.js` for the project. Prefers the project's own
    /// `node_modules/typescript`; falls back to a global install next to node. The app is
    /// typically launched from Finder with a minimal PATH, so common install locations and
    /// version-manager directories are searched explicitly.
    public static func discoverToolchain(
        projectRoot: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Toolchain? {
        guard let node = findNode(environment: environment) else { return nil }
        guard let tsserver = findTSServer(projectRoot: projectRoot, nodeURL: node) else { return nil }
        return Toolchain(nodeURL: node, tsserverURL: tsserver)
    }

    public static func findNode(environment: [String: String]) -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        var directories: [URL] = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0), isDirectory: true) }
        directories += [
            URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
            home.appendingPathComponent(".volta/bin", isDirectory: true),
        ]
        // Version managers and per-user installs: ~/.nvm/versions/node/*/bin, ~/.local/*/bin
        directories += glob(home.appendingPathComponent(".nvm/versions/node"), suffix: "bin")
        directories += glob(home.appendingPathComponent(".local"), suffix: "bin")

        for directory in directories {
            let candidate = directory.appendingPathComponent("node")
            if fm.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private static func glob(_ parent: URL, suffix: String) -> [URL] {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return []
        }
        return children
            .sorted { $0.lastPathComponent > $1.lastPathComponent } // prefer newest version
            .map { $0.appendingPathComponent(suffix, isDirectory: true) }
    }

    public static func findTSServer(projectRoot: URL, nodeURL: URL) -> URL? {
        let fm = FileManager.default

        var directory = projectRoot.standardizedFileURL.resolvingSymlinksInPath()
        for _ in 0..<12 {
            let candidate = directory.appendingPathComponent("node_modules/typescript/lib/tsserver.js")
            if fm.fileExists(atPath: candidate.path) {
                return candidate
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }

        // Global install alongside node: <prefix>/bin/node → <prefix>/lib/node_modules/…
        let globalCandidate = nodeURL
            .deletingLastPathComponent() // bin
            .deletingLastPathComponent() // prefix
            .appendingPathComponent("lib/node_modules/typescript/lib/tsserver.js")
        if fm.fileExists(atPath: globalCandidate.path) {
            return globalCandidate
        }
        return nil
    }
}
