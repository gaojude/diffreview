import AVFoundation
import Combine
import Foundation
import Speech

@MainActor
final class VoiceQuestionController: NSObject, ObservableObject {
    enum Phase: Equatable {
        case idle
        case authorizing
        case listening
        case thinking
        case speaking
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var transcript = ""
    @Published private(set) var answer = ""
    @Published private(set) var contextLabel: String?

    private let audioEngine = AVAudioEngine()
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let synthesizer = AVSpeechSynthesizer()
    private let client = OpenAICodeQuestionClient()

    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var activeContext: CodeSelectionContext?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    var isListening: Bool {
        phase == .listening
    }

    var isBusy: Bool {
        switch phase {
        case .authorizing, .listening, .thinking, .speaking:
            return true
        case .idle, .failed:
            return false
        }
    }

    var showsPanel: Bool {
        phase != .idle || !transcript.isEmpty || !answer.isEmpty
    }

    var statusText: String {
        switch phase {
        case .idle:
            return answer.isEmpty ? "" : "Ready"
        case .authorizing:
            return "Requesting access"
        case .listening:
            return transcript.isEmpty ? "Listening" : transcript
        case .thinking:
            return "Thinking"
        case .speaking:
            return "Speaking"
        case .failed(let message):
            return message
        }
    }

    func startListening(context: CodeSelectionContext?) {
        guard let context else {
            phase = .failed("Select code before asking.")
            return
        }
        Task { await beginListening(context: context) }
    }

    func finishListeningAndAsk() {
        guard phase == .listening else { return }
        stopRecording(finishTask: true)

        let question = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else {
            phase = .failed("I did not catch a question.")
            return
        }

        phase = .thinking
        Task { await ask(question: question, context: activeContext) }
    }

    func cancel() {
        stopRecording(finishTask: false)
        stopSpeaking()
        transcript = ""
        answer = ""
        activeContext = nil
        contextLabel = nil
        phase = .idle
    }

    func replayAnswer() {
        guard !answer.isEmpty else { return }
        speak(answer)
    }

    func stopSpeaking() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        if phase == .speaking {
            phase = .idle
        }
    }

    private func beginListening(context: CodeSelectionContext) async {
        stopRecording(finishTask: false)
        stopSpeaking()

        transcript = ""
        answer = ""
        activeContext = context
        contextLabel = context.locationLabel
        phase = .authorizing

        do {
            try await requestPermissions()
            try startRecording()
        } catch {
            stopRecording(finishTask: false)
            phase = .failed(error.localizedDescription)
        }
    }

    private func ask(question: String, context: CodeSelectionContext?) async {
        do {
            let reply = try await client.ask(question: question, context: context)
            answer = reply
            speak(reply)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func requestPermissions() async throws {
        guard let speechRecognizer else {
            throw VoiceAssistantError.speechRecognitionUnavailable
        }

        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }

        switch speechStatus {
        case .authorized:
            break
        case .denied:
            throw VoiceAssistantError.speechRecognitionDenied
        case .restricted:
            throw VoiceAssistantError.speechRecognitionRestricted
        case .notDetermined:
            throw VoiceAssistantError.speechRecognitionDenied
        @unknown default:
            throw VoiceAssistantError.speechRecognitionUnavailable
        }

        guard speechRecognizer.isAvailable else {
            throw VoiceAssistantError.speechRecognitionUnavailable
        }

        let microphoneAllowed = await requestMicrophoneAccessIfNeeded()
        guard microphoneAllowed else {
            throw VoiceAssistantError.microphoneDenied
        }
    }

    private func requestMicrophoneAccessIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { allowed in
                    continuation.resume(returning: allowed)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func startRecording() throws {
        guard let speechRecognizer else {
            throw VoiceAssistantError.speechRecognitionUnavailable
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
        phase = .listening

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                }
                if let error, self.phase == .listening {
                    self.stopRecording(finishTask: false)
                    self.phase = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func stopRecording(finishTask: Bool) {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        if finishTask {
            recognitionTask?.finish()
        } else {
            recognitionTask?.cancel()
        }
        recognitionRequest = nil
        recognitionTask = nil
    }

    private func speak(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            phase = .idle
            return
        }
        stopSpeaking()
        phase = .speaking
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }
}

extension VoiceQuestionController: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        finishSpeakingIfNeeded()
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        finishSpeakingIfNeeded()
    }

    private nonisolated func finishSpeakingIfNeeded() {
        Task { @MainActor in
            guard self.phase == .speaking else { return }
            self.phase = .idle
        }
    }
}

private enum VoiceAssistantError: LocalizedError {
    case microphoneDenied
    case speechRecognitionDenied
    case speechRecognitionRestricted
    case speechRecognitionUnavailable
    case missingAPIKey
    case invalidResponse
    case api(String)

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "Microphone access is disabled."
        case .speechRecognitionDenied:
            return "Speech recognition access is disabled."
        case .speechRecognitionRestricted:
            return "Speech recognition is restricted on this Mac."
        case .speechRecognitionUnavailable:
            return "Speech recognition is unavailable."
        case .missingAPIKey:
            return "Set AI_GATEWAY_API_KEY or OPENAI_API_KEY to ask the assistant."
        case .invalidResponse:
            return "The assistant returned an unreadable response."
        case .api(let message):
            return message
        }
    }
}

private struct OpenAICodeQuestionClient {
    func ask(question: String, context: CodeSelectionContext?) async throws -> String {
        let configuration = try apiConfiguration()
        let payload = try JSONSerialization.data(withJSONObject: [
            "model": configuration.model,
            "input": [
                [
                    "role": "developer",
                    "content": developerInstructions,
                ],
                [
                    "role": "user",
                    "content": userPrompt(question: question, context: context),
                ],
            ],
            "max_output_tokens": 600,
        ])

        var request = URLRequest(url: configuration.baseURL.appendingPathComponent("responses"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = payload
        request.timeoutInterval = 60

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw VoiceAssistantError.invalidResponse
        }

        guard 200..<300 ~= httpResponse.statusCode else {
            if let apiError = try? JSONDecoder().decode(OpenAIErrorEnvelope.self, from: data) {
                throw VoiceAssistantError.api(apiError.error.message)
            }
            throw VoiceAssistantError.api("OpenAI request failed with HTTP \(httpResponse.statusCode).")
        }

        let envelope = try JSONDecoder().decode(OpenAIResponseEnvelope.self, from: data)
        let text = envelope.combinedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw VoiceAssistantError.invalidResponse
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

        throw VoiceAssistantError.missingAPIKey
    }

    private var developerInstructions: String {
        """
        You are a concise senior coding assistant inside a native macOS IDE.
        The user asks by voice about the selected code or diff lines.
        Answer directly and practically. If the context is insufficient, say what additional context would help.
        Keep answers short enough to be spoken aloud.
        """
    }

    private func userPrompt(question: String, context: CodeSelectionContext?) -> String {
        guard let context else {
            return """
            Question:
            \(question)

            No code selection was available.
            """
        }

        return """
        Question:
        \(question)

        Context kind:
        \(context.contentKind == .diff ? "diff" : "source")

        File:
        \(context.fileURL?.path ?? "Unknown")

        Selected lines:
        \(context.startLine)-\(context.endLine)

        Selected text:
        ```
        \(Self.clipped(context.text))
        ```
        """
    }

    private func environmentValue(_ name: String) -> String? {
        let value = ProcessInfo.processInfo.environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    private func environmentURL(_ name: String) -> URL? {
        environmentValue(name).flatMap(URL.init(string:))
    }

    private static func clipped(_ text: String, maxCharacters: Int = 12_000) -> String {
        guard text.count > maxCharacters else { return text }
        return "\(text.prefix(maxCharacters))\n\n[Selection truncated]"
    }

    private struct APIConfiguration {
        let apiKey: String
        let baseURL: URL
        let model: String
    }
}

private struct OpenAIErrorEnvelope: Decodable {
    let error: ErrorBody

    struct ErrorBody: Decodable {
        let message: String
    }
}

private struct OpenAIResponseEnvelope: Decodable {
    let outputText: String?
    let output: [OutputItem]?

    var combinedText: String {
        if let outputText, !outputText.isEmpty {
            return outputText
        }

        return output?
            .flatMap { $0.content ?? [] }
            .compactMap { item in
                switch item.type {
                case "output_text":
                    return item.text
                case "refusal":
                    return item.refusal
                default:
                    return nil
                }
            }
            .joined(separator: "\n") ?? ""
    }

    enum CodingKeys: String, CodingKey {
        case outputText = "output_text"
        case output
    }

    struct OutputItem: Decodable {
        let content: [ContentItem]?
    }

    struct ContentItem: Decodable {
        let type: String
        let text: String?
        let refusal: String?
    }
}
