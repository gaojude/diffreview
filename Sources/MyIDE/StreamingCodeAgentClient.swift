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

struct StreamingCodeAgentClient {
    typealias ProgressHandler = @MainActor (String) -> Void
    typealias ToolEventHandler = @MainActor (AgentToolEvent) -> Void
    typealias DeltaHandler = @MainActor (String) -> Void

    func ask(
        question: String,
        context: CodeSelectionContext,
        rootURL: URL,
        onProgress: @escaping ProgressHandler,
        onToolEvent: @escaping ToolEventHandler,
        onDelta: @escaping DeltaHandler
    ) async throws -> String {
        let configuration = try apiConfiguration()
        let toolbox = CodebaseAgentToolbox(rootURL: rootURL, selection: context)
        var messages: [ChatMessage] = [
            .system(systemPrompt),
            .user(initialPrompt(question: question, context: context, toolbox: toolbox)),
        ]

        for _ in 0..<8 {
            let result = try await streamChatCompletion(
                configuration: configuration,
                messages: messages,
                tools: CodebaseAgentToolbox.toolDefinitions,
                toolChoice: "auto",
                onDelta: onDelta
            )

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

            for toolCall in result.toolCalls {
                let progress = toolbox.progressMessage(
                    for: toolCall.function.name,
                    arguments: toolCall.function.arguments
                )
                await onProgress(progress)
                await onToolEvent(AgentToolEvent(
                    id: toolCall.id,
                    name: toolCall.function.name,
                    arguments: toolCall.function.arguments,
                    status: .started,
                    outputPreview: nil
                ))
                let output = await Task.detached(priority: .userInitiated) {
                    toolbox.execute(
                        toolName: toolCall.function.name,
                        arguments: toolCall.function.arguments
                    )
                }.value
                await onToolEvent(AgentToolEvent(
                    id: toolCall.id,
                    name: toolCall.function.name,
                    arguments: toolCall.function.arguments,
                    status: .finished,
                    outputPreview: Self.outputPreview(for: output)
                ))
                messages.append(.tool(toolCallID: toolCall.id, content: output))
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
        toolChoice: String?,
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
            throw AgentClientError.api("Agent request failed with HTTP \(httpResponse.statusCode).")
        }

        var content = ""
        var builders: [Int: ToolCallBuilder] = [:]

        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let dataLine = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
            if dataLine == "[DONE]" { break }
            guard let data = dataLine.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = object["choices"] as? [[String: Any]],
                  let choice = choices.first else {
                continue
            }

            if let delta = choice["delta"] as? [String: Any] {
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
            }
        }

        let toolCalls = builders.keys.sorted().compactMap { builders[$0]?.toolCall }
        return StreamResult(content: content, toolCalls: toolCalls)
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

        throw AgentClientError.missingAPIKey
    }

    private var systemPrompt: String {
        """
        You are a concise senior code agent inside a native macOS IDE.
        The user selected code and typed a question. Treat the selection as the anchor, but inspect the repo with tools.
        Always inspect git diff semantics first with get_git_diff before broader search/read calls.
        You may inspect the whole opened codebase through list_files, read_file, and search_text, but only request the specific files or searches you need.
        Use read-only tools only. Never ask for broad code dumps.
        The app renders tool calls separately, so do not narrate each lookup in the final answer.
        Avoid quoting code unless a tiny identifier is essential.
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

    private struct APIConfiguration {
        let apiKey: String
        let baseURL: URL
        let model: String
    }

    private struct StreamResult {
        let content: String
        let toolCalls: [AgentToolCall]
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
