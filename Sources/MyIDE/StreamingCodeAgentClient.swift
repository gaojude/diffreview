import Foundation

struct AgentToolEvent: Identifiable, Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case started
        case finished
    }

    let id: String
    let name: String
    let arguments: String
    let status: Status
    let outputPreview: String?
}

struct AgentFixProposal: Equatable, Codable, Sendable {
    let title: String
    let summary: String
    let prompt: String
}

struct StreamingCodeAgentClient {
    typealias ProgressHandler = @MainActor (String) -> Void
    typealias ToolEventHandler = @MainActor (AgentToolEvent) -> Void
    typealias DeltaHandler = @MainActor (String) -> Void
    typealias FixProposalHandler = @MainActor (AgentFixProposal) -> Void

    func ask(
        question: String,
        context: CodeSelectionContext,
        rootURL: URL,
        forceFixCapture: Bool = false,
        onProgress: @escaping ProgressHandler,
        onToolEvent: @escaping ToolEventHandler,
        onDelta: @escaping DeltaHandler,
        onFixProposal: FixProposalHandler? = nil
    ) async throws -> String {
        let configuration = try apiConfiguration()
        let toolbox = CodebaseAgentToolbox(rootURL: rootURL, selection: context)
        var messages: [ChatMessage] = [
            .system(systemPrompt),
            .user(initialPrompt(question: question, context: context, toolbox: toolbox)),
        ]

        for iteration in 0..<8 {
            let toolChoice: Any?
            if iteration == 0 {
                toolChoice = Self.requiredToolChoice("get_git_diff")
            } else if forceFixCapture && !messages.containsToolCall(named: "capture_fix") {
                toolChoice = Self.requiredToolChoice("capture_fix")
            } else {
                toolChoice = "auto"
            }

            let result = try await streamChatCompletion(
                configuration: configuration,
                messages: messages,
                tools: Self.toolDefinitions,
                toolChoice: toolChoice,
                onDelta: onDelta
            )
            try Task.checkCancellation()

            guard !result.toolCalls.isEmpty else {
                let text = result.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty {
                    return try await forceFinalAnswer(
                        configuration: configuration,
                        messages: messages,
                        onDelta: onDelta
                    )
                }
                return text
            }

            messages.append(.assistant(content: result.content, toolCalls: result.toolCalls))

            let outputs = await executeToolCalls(
                result.toolCalls,
                toolbox: toolbox,
                onProgress: onProgress,
                onToolEvent: onToolEvent,
                onFixProposal: onFixProposal
            )
            try Task.checkCancellation()
            for output in outputs {
                messages.append(.tool(toolCallID: output.toolCall.id, content: output.output))
            }
        }

        return try await forceFinalAnswer(
            configuration: configuration,
            messages: messages,
            onDelta: onDelta
        )
    }

    private func streamChatCompletion(
        configuration: APIConfiguration,
        messages: [ChatMessage],
        tools: [[String: Any]],
        toolChoice: Any?,
        onDelta: @escaping DeltaHandler
    ) async throws -> StreamResult {
        var payload: [String: Any] = [
            "model": configuration.model,
            "messages": messages.map(\.dictionary),
            "stream": true,
            "temperature": 0.2,
            "max_tokens": 1_000,
        ]
        if !tools.isEmpty {
            payload["tools"] = tools
            payload["parallel_tool_calls"] = true
        }
        if let toolChoice {
            payload["tool_choice"] = toolChoice
        }

        var request = URLRequest(url: configuration.baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.timeoutInterval = 120

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AgentClientError.invalidResponse
        }
        guard 200..<300 ~= httpResponse.statusCode else {
            let bodyPreview = try await Self.readBodyPreview(bytes)
            let detail = bodyPreview.isEmpty ? "" : " \(bodyPreview)"
            throw AgentClientError.api("Agent request failed with HTTP \(httpResponse.statusCode).\(detail)")
        }

        var content = ""
        var builders: [Int: ToolCallBuilder] = [:]

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            var dataLine = String(line.dropFirst(5))
            if dataLine.first == " " {
                dataLine.removeFirst()
            }
            let shouldContinue = try await processStreamEvent(
                dataLine,
                content: &content,
                builders: &builders,
                onDelta: onDelta
            )
            if !shouldContinue { break }
        }

        let toolCalls = builders.keys.sorted().compactMap { builders[$0]?.toolCall }
        return StreamResult(content: content, toolCalls: toolCalls)
    }

    private func processStreamEvent(
        _ dataLine: String,
        content: inout String,
        builders: inout [Int: ToolCallBuilder],
        onDelta: @escaping DeltaHandler
    ) async throws -> Bool {
        let trimmed = dataLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        if trimmed == "[DONE]" { return false }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return true
        }

        if let error = object["error"] as? [String: Any] {
            throw AgentClientError.api(Self.apiErrorMessage(error))
        }

        guard let choices = object["choices"] as? [[String: Any]],
              let choice = choices.first else {
            return true
        }

        guard let delta = choice["delta"] as? [String: Any] else {
            return true
        }

        if let contentDelta = delta["content"] as? String, !contentDelta.isEmpty {
            content += contentDelta
            await onDelta(contentDelta)
        }

        if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
            for rawToolCall in toolCalls {
                let index = rawToolCall["index"] as? Int ?? builders.count
                var builder = builders[index] ?? ToolCallBuilder(index: index)
                if let id = rawToolCall["id"] as? String {
                    builder.id += id
                }
                if let type = rawToolCall["type"] as? String {
                    builder.type = type
                }
                if let function = rawToolCall["function"] as? [String: Any] {
                    if let name = function["name"] as? String {
                        builder.name += name
                    }
                    if let arguments = function["arguments"] as? String {
                        builder.arguments += arguments
                    }
                }
                builders[index] = builder
            }
        }

        return true
    }

    private func forceFinalAnswer(
        configuration: APIConfiguration,
        messages: [ChatMessage],
        onDelta: @escaping DeltaHandler
    ) async throws -> String {
        var finalMessages = messages
        finalMessages.append(.user("""
        Stop using tools now. Based only on the tool results already available, answer the user's question directly.
        If the tool results are insufficient, say what is missing in one sentence.
        """))

        let result = try await streamChatCompletion(
            configuration: configuration,
            messages: finalMessages,
            tools: [],
            toolChoice: nil,
            onDelta: onDelta
        )
        let text = result.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw AgentClientError.invalidResponse
        }
        return text
    }

    private func executeToolCalls(
        _ toolCalls: [AgentToolCall],
        toolbox: CodebaseAgentToolbox,
        onProgress: @escaping ProgressHandler,
        onToolEvent: @escaping ToolEventHandler,
        onFixProposal: FixProposalHandler?
    ) async -> [ToolExecutionResult] {
        for toolCall in toolCalls {
            let progress = progressMessage(for: toolCall, toolbox: toolbox)
            await onProgress(progress)
            await onToolEvent(AgentToolEvent(
                id: toolCall.id,
                name: toolCall.function.name,
                arguments: toolCall.function.arguments,
                status: .started,
                outputPreview: nil
            ))
        }

        return await withTaskGroup(of: ToolExecutionResult.self) { group in
            for (position, toolCall) in toolCalls.enumerated() {
                group.addTask(priority: .userInitiated) {
                    let output: String
                    let fixProposal: AgentFixProposal?
                    if toolCall.function.name == "capture_fix" {
                        let parsed = Self.parseFixProposal(arguments: toolCall.function.arguments)
                        fixProposal = parsed
                        if let parsed {
                            output = "Captured fix proposal: \(parsed.title)"
                        } else {
                            output = "Could not capture fix proposal: invalid arguments."
                        }
                    } else {
                        fixProposal = nil
                        output = toolbox.execute(
                            toolName: toolCall.function.name,
                            arguments: toolCall.function.arguments
                        )
                    }
                    return ToolExecutionResult(
                        position: position,
                        toolCall: toolCall,
                        output: output,
                        fixProposal: fixProposal
                    )
                }
            }

            var results: [ToolExecutionResult] = []
            for await result in group {
                if let fixProposal = result.fixProposal {
                    await onFixProposal?(fixProposal)
                }
                await onToolEvent(AgentToolEvent(
                    id: result.toolCall.id,
                    name: result.toolCall.function.name,
                    arguments: result.toolCall.function.arguments,
                    status: .finished,
                    outputPreview: Self.outputPreview(for: result.output)
                ))
                results.append(result)
            }

            return results.sorted { $0.position < $1.position }
        }
    }

    private func progressMessage(for toolCall: AgentToolCall, toolbox: CodebaseAgentToolbox) -> String {
        if toolCall.function.name == "capture_fix" {
            return "Preparing a fix"
        }
        return toolbox.progressMessage(
            for: toolCall.function.name,
            arguments: toolCall.function.arguments
        )
    }

    private static func parseFixProposal(arguments: String) -> AgentFixProposal? {
        guard let data = arguments.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AgentFixProposal.self, from: data)
    }

    private static func requiredToolChoice(_ name: String) -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": name,
            ],
        ]
    }

    private func apiConfiguration() throws -> APIConfiguration {
        if let gatewayKey = environmentValue("AI_GATEWAY_API_KEY") {
            return APIConfiguration(
                apiKey: gatewayKey,
                baseURL: environmentURL("AI_GATEWAY_BASE_URL")
                    ?? environmentURL("MYIDE_AI_BASE_URL")
                    ?? URL(string: "https://ai-gateway.vercel.sh/v1")!,
                model: environmentValue("MYIDE_AI_MODEL")
                    ?? environmentValue("AI_GATEWAY_MODEL")
                    ?? environmentValue("OPENAI_MODEL")
                    ?? "openai/gpt-5.5"
            )
        }

        if let openAIKey = environmentValue("OPENAI_API_KEY") {
            return APIConfiguration(
                apiKey: openAIKey,
                baseURL: environmentURL("OPENAI_BASE_URL")
                    ?? environmentURL("MYIDE_AI_BASE_URL")
                    ?? URL(string: "https://api.openai.com/v1")!,
                model: environmentValue("MYIDE_AI_MODEL")
                    ?? environmentValue("OPENAI_MODEL")
                    ?? "gpt-5.5"
            )
        }

        if let anthropicGatewayKey = environmentValue("ANTHROPIC_AUTH_TOKEN"),
           let baseURL = environmentURL("ANTHROPIC_BASE_URL"),
           baseURL.host?.contains("ai-gateway.vercel.sh") == true {
            return APIConfiguration(
                apiKey: anthropicGatewayKey,
                baseURL: openAICompatibleGatewayBaseURL(from: baseURL),
                model: environmentValue("MYIDE_AI_MODEL")
                    ?? environmentValue("ANTHROPIC_MODEL")
                    ?? "anthropic/claude-opus-4.8"
            )
        }

        throw AgentClientError.missingAPIKey
    }

    private var systemPrompt: String {
        """
        You are a concise senior code agent inside a native macOS IDE.
        The user selected code and typed a question. Treat the selection as the anchor, but inspect the repo with tools.
        Always inspect git diff semantics first with get_git_diff before broader search/read calls.
        You may inspect the whole opened codebase through list_files, read_file, and search_text, but only request the specific files or searches you need.
        If the user asks you to implement, fix, rename, or otherwise make a code change, do not pretend to edit code. Instead call capture_fix with a polished, paste-ready implementation prompt that you write yourself.
        capture_fix content must not be a raw copy of the chat. Include the target, the intended behavior, why it matters, and any tests or verification a coding agent should run.
        When multiple independent lookups are useful, batch them in the same tool-calling turn.
        When you need tools, return tool calls without user-visible prose; the app already shows progress.
        Use read-only tools only. Never ask for broad code dumps.
        The app shows compact progress separately, so do not narrate each lookup in the final answer.
        Avoid quoting code unless a tiny identifier is essential.
        When citing code, use repo-relative file references with line ranges, like path/to/file.ts:12-18, so the IDE can link them.
        Final answer: explain what matters, cite files/lines when useful, and keep it concise.
        """
    }

    private func initialPrompt(
        question: String,
        context: CodeSelectionContext,
        toolbox: CodebaseAgentToolbox
    ) -> String {
        """
        User question:
        \(question)

        Selection anchor:
        - File: \(toolbox.selectedPath)
        - Lines: \(context.startLine)-\(context.endLine)
        - Kind: \(context.contentKind == .diff ? "diff" : "source")

        Selected text, for orientation only:
        ```
        \(context.text)
        ```

        Git change summary:
        \(toolbox.changedFileSummary)

        First action: call get_git_diff. Prioritize the selected file's diff and the branch/worktree diff before reading unrelated files.
        """
    }

    private func environmentValue(_ name: String) -> String? {
        let value = ProcessInfo.processInfo.environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    private func environmentURL(_ name: String) -> URL? {
        environmentValue(name).flatMap(URL.init(string:))
    }

    private func openAICompatibleGatewayBaseURL(from baseURL: URL) -> URL {
        let path = baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path == "v1" || path.hasSuffix("/v1") {
            return baseURL
        }
        return baseURL.appendingPathComponent("v1")
    }

    private static func outputPreview(for output: String) -> String {
        let normalized = output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(4)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "No output." }
        if normalized.count <= 320 { return normalized }
        return "\(normalized.prefix(320))..."
    }

    private static func readBodyPreview(_ bytes: URLSession.AsyncBytes, maxBytes: Int = 4_096) async throws -> String {
        var data = Data()
        for try await byte in bytes {
            if data.count >= maxBytes { break }
            data.append(byte)
        }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
    }

    private static func apiErrorMessage(_ error: [String: Any]) -> String {
        let message = error["message"] as? String
            ?? error["error"] as? String
            ?? "The provider returned an error."
        let type = error["type"] as? String
        let code = error["code"] as? String
        return [type, code, message]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ": ")
    }

    private static var toolDefinitions: [[String: Any]] {
        CodebaseAgentToolbox.toolDefinitions + [captureFixToolDefinition]
    }

    private static var captureFixToolDefinition: [String: Any] {
        [
            "type": "function",
            "function": [
                "name": "capture_fix",
                "description": "Capture a paste-ready implementation prompt when the user wants a code change. The app stores this fix for handoff; no files are edited by this chat.",
                "strict": true,
                "parameters": [
                    "type": "object",
                    "properties": [
                        "title": [
                            "type": "string",
                            "description": "Short action title for the fix.",
                        ],
                        "summary": [
                            "type": "string",
                            "description": "One or two sentences describing the intended code change.",
                        ],
                        "prompt": [
                            "type": "string",
                            "description": "A complete, paste-ready prompt for a coding agent. Include file paths, relevant line ranges, implementation guidance, and tests or checks to run.",
                        ],
                    ],
                    "required": ["title", "summary", "prompt"],
                    "additionalProperties": false,
                ],
            ],
        ]
    }

    private struct APIConfiguration {
        let apiKey: String
        let baseURL: URL
        let model: String
    }

    private struct StreamResult {
        let content: String
        let toolCalls: [AgentToolCall]
    }

    private struct ToolExecutionResult: Sendable {
        let position: Int
        let toolCall: AgentToolCall
        let output: String
        let fixProposal: AgentFixProposal?
    }

    private struct ToolCallBuilder {
        let index: Int
        var id = ""
        var type = "function"
        var name = ""
        var arguments = ""

        var toolCall: AgentToolCall? {
            guard !name.isEmpty else { return nil }
            return AgentToolCall(
                id: id.isEmpty ? "call_\(index)" : id,
                type: type.isEmpty ? "function" : type,
                function: AgentToolFunction(name: name, arguments: arguments)
            )
        }
    }
}

struct AgentToolCall: Sendable {
    let id: String
    let type: String
    let function: AgentToolFunction

    var dictionary: [String: Any] {
        [
            "id": id,
            "type": type,
            "function": function.dictionary,
        ]
    }
}

struct AgentToolFunction: Sendable {
    let name: String
    let arguments: String

    var dictionary: [String: Any] {
        [
            "name": name,
            "arguments": arguments,
        ]
    }
}

private struct ChatMessage {
    let dictionary: [String: Any]

    static func system(_ content: String) -> ChatMessage {
        ChatMessage(dictionary: ["role": "system", "content": content])
    }

    static func user(_ content: String) -> ChatMessage {
        ChatMessage(dictionary: ["role": "user", "content": content])
    }

    static func assistant(content: String, toolCalls: [AgentToolCall]) -> ChatMessage {
        var dictionary: [String: Any] = [
            "role": "assistant",
            "content": content.isEmpty ? NSNull() : content,
        ]
        if !toolCalls.isEmpty {
            dictionary["tool_calls"] = toolCalls.map(\.dictionary)
        }
        return ChatMessage(dictionary: dictionary)
    }

    static func tool(toolCallID: String, content: String) -> ChatMessage {
        ChatMessage(dictionary: [
            "role": "tool",
            "tool_call_id": toolCallID,
            "content": content,
        ])
    }

    func containsToolCall(named name: String) -> Bool {
        guard let toolCalls = dictionary["tool_calls"] as? [[String: Any]] else { return false }
        return toolCalls.contains { toolCall in
            guard let function = toolCall["function"] as? [String: Any] else { return false }
            return function["name"] as? String == name
        }
    }
}

private extension Array where Element == ChatMessage {
    func containsToolCall(named name: String) -> Bool {
        contains { $0.containsToolCall(named: name) }
    }
}

private enum AgentClientError: LocalizedError {
    case missingAPIKey
    case invalidResponse
    case api(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Set AI_GATEWAY_API_KEY or OPENAI_API_KEY to ask the assistant."
        case .invalidResponse:
            return "The assistant returned an unreadable response."
        case .api(let message):
            return message
        }
    }
}
