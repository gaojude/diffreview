import Foundation

/// Wire types for the NDJSON stdio protocol between the app and the agent
/// harness sidecar (`harness/agent-harness.mjs`). The app is the tool server:
/// the harness asks for browser commands via `tool_use` and the app answers
/// with `tool_result` after executing them on the in-process engine.

public enum HarnessMessage: Equatable, Sendable {
    case hello(mode: String)
    case state(String)
    case text(String)
    case toolUse(id: String, command: String)
    case turnEnd
    case fatal(String)
}

public enum AppToHarnessMessage: Equatable, Sendable {
    case user(String)
    case toolResult(id: String, ok: Bool, output: String)
    case shutdown
}

public enum HarnessWire {
    /// Decodes one harness stdout line. Returns nil for malformed JSON and for
    /// unknown message types — the protocol is forward-compatible by ignoring
    /// what it doesn't understand, never by crashing.
    public static func decode(_ line: String) -> HarnessMessage? {
        guard
            let data = line.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any],
            let type = dictionary["type"] as? String
        else { return nil }

        switch type {
        case "hello":
            guard let mode = dictionary["mode"] as? String else { return nil }
            return .hello(mode: mode)
        case "state":
            guard let value = dictionary["value"] as? String else { return nil }
            return .state(value)
        case "text":
            guard let text = dictionary["text"] as? String else { return nil }
            return .text(text)
        case "tool_use":
            guard
                let id = dictionary["id"] as? String,
                let command = dictionary["command"] as? String
            else { return nil }
            return .toolUse(id: id, command: command)
        case "turn_end":
            return .turnEnd
        case "fatal":
            guard let message = dictionary["message"] as? String else { return nil }
            return .fatal(message)
        default:
            return nil
        }
    }

    /// Encodes one app→harness message as compact single-line JSON (no trailing
    /// newline — the transport appends it).
    public static func encode(_ message: AppToHarnessMessage) -> String {
        let dictionary: [String: Any]
        switch message {
        case .user(let text):
            dictionary = ["type": "user", "text": text]
        case .toolResult(let id, let ok, let output):
            dictionary = ["type": "tool_result", "id": id, "ok": ok, "output": output]
        case .shutdown:
            dictionary = ["type": "shutdown"]
        }
        guard
            let data = try? JSONSerialization.data(withJSONObject: dictionary, options: [.sortedKeys]),
            let line = String(data: data, encoding: .utf8)
        else {
            // Unreachable for the fixed shapes above, but the API must not throw.
            return "{\"type\":\"shutdown\"}"
        }
        return line
    }
}

/// Incremental newline framer for the harness's stdout. Pure and chunk-boundary
/// safe (a line may arrive split across many pipe reads), separated out so
/// `MyIDESelfTest` can exercise it — the same shape as `TSServerMessageBuffer`.
public struct NDJSONLineBuffer: Sendable {
    private var pending = Data()

    public init() {}

    /// Appends a raw chunk and returns every completed line, `\n`-delimited,
    /// tolerating `\r\n` and skipping empty lines.
    public mutating func append(_ chunk: Data) -> [String] {
        pending.append(chunk)
        var lines: [String] = []
        while let newlineIndex = pending.firstIndex(of: 0x0A) {
            var lineData = pending.subdata(in: pending.startIndex..<newlineIndex)
            pending.removeSubrange(pending.startIndex...newlineIndex)
            if lineData.last == 0x0D {
                lineData.removeLast()
            }
            if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                lines.append(line)
            }
        }
        return lines
    }
}
