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
    @Published private(set) var currentActivity = ""

    private let audioEngine = AVAudioEngine()
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let speechPlayer = SpeechPlaybackController()
    private let client = StreamingCodeAgentClient()

    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var activeContext: CodeSelectionContext?
    private var activeRootURL: URL?

    override init() {
        super.init()
        speechPlayer.onFinish = { [weak self] in
            self?.finishSpeakingIfNeeded()
        }
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
            return currentActivity.isEmpty ? "Thinking" : currentActivity
        case .speaking:
            return "Speaking"
        case .failed(let message):
            return message
        }
    }

    func startListening(context: CodeSelectionContext?, rootURL: URL) {
        guard let context else {
            phase = .failed("Select code before asking.")
            return
        }
        Task { await beginListening(context: context, rootURL: rootURL) }
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
        Task { await ask(question: question, context: activeContext, rootURL: activeRootURL) }
    }

    func cancel() {
        stopRecording(finishTask: false)
        stopSpeaking()
        transcript = ""
        answer = ""
        currentActivity = ""
        activeContext = nil
        activeRootURL = nil
        contextLabel = nil
        phase = .idle
    }

    func replayAnswer() {
        guard !answer.isEmpty else { return }
        speak(answer)
    }

    func stopSpeaking() {
        speechPlayer.stop()
        if phase == .speaking {
            phase = .idle
        }
    }

    private func beginListening(context: CodeSelectionContext, rootURL: URL) async {
        stopRecording(finishTask: false)
        stopSpeaking()

        transcript = ""
        answer = ""
        currentActivity = ""
        activeContext = context
        activeRootURL = rootURL
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

    private func ask(question: String, context: CodeSelectionContext?, rootURL: URL?) async {
        do {
            guard let context, let rootURL else {
                throw VoiceAssistantError.invalidResponse
            }
            currentActivity = "Let me inspect the diff first."
            speakProgress(currentActivity)
            let reply = try await client.ask(
                question: question,
                context: context,
                rootURL: rootURL,
                onProgress: { [weak self] message in
                    self?.currentActivity = message
                    self?.speakProgress(message)
                },
                onDelta: { [weak self] delta in
                    self?.answer += delta
                }
            )
            answer = reply
            currentActivity = ""
            speak(spokenAnswer(from: reply))
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
        phase = .speaking
        Task { [weak self] in
            guard let self else { return }
            await self.speechPlayer.speak(text)
        }
    }

    private func speakProgress(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.speechPlayer.speak(trimmed)
        }
    }

    private func spokenAnswer(from text: String) -> String {
        var spoken = text.replacingOccurrences(
            of: "```[\\s\\S]*?```",
            with: "the relevant code",
            options: .regularExpression
        )
        spoken = spoken.replacingOccurrences(
            of: "`([^`]+)`",
            with: "$1",
            options: .regularExpression
        )
        spoken = spoken
            .replacingOccurrences(of: #"Sources/[^\s,.)]+"#, with: "the referenced file", options: .regularExpression)
            .replacingOccurrences(of: #"[A-Za-z0-9_\-./]+\.(swift|ts|tsx|js|jsx|py|md|json|yml|yaml)"#, with: "the referenced file", options: .regularExpression)
        return String(spoken.prefix(900))
    }

    private func finishSpeakingIfNeeded() {
        guard phase == .speaking else { return }
        phase = .idle
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

@MainActor
private final class SpeechPlaybackController: NSObject {
    var onFinish: (() -> Void)?

    private let hostedSpeechClient = HostedSpeechClient()
    private let fallbackSynthesizer = AVSpeechSynthesizer()
    private var audioPlayer: AVAudioPlayer?
    private var playbackID = 0

    override init() {
        super.init()
        fallbackSynthesizer.delegate = self
    }

    func speak(_ text: String) async {
        stop()
        playbackID += 1
        let playbackID = playbackID

        do {
            let audioData = try await hostedSpeechClient.speechAudio(for: text)
            guard self.playbackID == playbackID else { return }
            try play(audioData)
        } catch {
            guard self.playbackID == playbackID else { return }
            speakWithSystemFallback(text)
        }
    }

    func stop() {
        playbackID += 1
        if audioPlayer?.isPlaying == true {
            audioPlayer?.stop()
        }
        audioPlayer = nil
        if fallbackSynthesizer.isSpeaking {
            fallbackSynthesizer.stopSpeaking(at: .immediate)
        }
    }

    private func play(_ data: Data) throws {
        let player = try AVAudioPlayer(data: data)
        player.delegate = self
        player.prepareToPlay()
        audioPlayer = player
        player.play()
    }

    private func speakWithSystemFallback(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        fallbackSynthesizer.speak(utterance)
    }
}

extension SpeechPlaybackController: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.audioPlayer = nil
            self.onFinish?()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            self.audioPlayer = nil
            self.onFinish?()
        }
    }
}

extension SpeechPlaybackController: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.onFinish?()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.onFinish?()
        }
    }
}

private struct HostedSpeechClient {
    func speechAudio(for text: String) async throws -> Data {
        let configuration = try apiConfiguration()
        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        configuration.headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.httpBody = try JSONSerialization.data(withJSONObject: configuration.body(text))
        request.timeoutInterval = 60

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw VoiceAssistantError.invalidResponse
        }
        guard 200..<300 ~= httpResponse.statusCode else {
            throw VoiceAssistantError.api("Speech request failed with HTTP \(httpResponse.statusCode).")
        }

        switch configuration.provider {
        case .gateway:
            let envelope = try JSONDecoder().decode(GatewaySpeechEnvelope.self, from: data)
            guard let audioData = Data(base64Encoded: envelope.audio) else {
                throw VoiceAssistantError.invalidResponse
            }
            return audioData
        case .openAI:
            return data
        }
    }

    private func apiConfiguration() throws -> APIConfiguration {
        let voice = environmentValue("MYIDE_TTS_VOICE")
            ?? environmentValue("AI_GATEWAY_TTS_VOICE")
            ?? environmentValue("OPENAI_TTS_VOICE")
            ?? "marin"
        let instructions = environmentValue("MYIDE_TTS_INSTRUCTIONS")
            ?? "Speak naturally and calmly, like a sharp senior engineer explaining code in a short voice note. Avoid announcer energy."
        let speed = Double(environmentValue("MYIDE_TTS_SPEED") ?? "") ?? 1.04

        if let gatewayKey = environmentValue("AI_GATEWAY_API_KEY") {
            return APIConfiguration(
                provider: .gateway,
                apiKey: gatewayKey,
                endpoint: environmentURL("AI_GATEWAY_TTS_URL")
                    ?? URL(string: "https://ai-gateway.vercel.sh/v4/ai/speech-model")!,
                headers: [
                    "ai-model-id": environmentValue("MYIDE_TTS_MODEL")
                        ?? environmentValue("AI_GATEWAY_TTS_MODEL")
                        ?? "openai/gpt-4o-mini-tts",
                ],
                body: { text in
                    [
                        "text": Self.clipped(text),
                        "voice": voice,
                        "outputFormat": "mp3",
                        "instructions": instructions,
                        "speed": speed,
                    ]
                }
            )
        }

        if let openAIKey = environmentValue("OPENAI_API_KEY") {
            let baseURL = environmentURL("OPENAI_BASE_URL")
                ?? URL(string: "https://api.openai.com/v1")!
            return APIConfiguration(
                provider: .openAI,
                apiKey: openAIKey,
                endpoint: baseURL.appendingPathComponent("audio/speech"),
                headers: [:],
                body: { text in
                    [
                        "model": environmentValue("MYIDE_TTS_MODEL")
                            ?? environmentValue("OPENAI_TTS_MODEL")
                            ?? "gpt-4o-mini-tts",
                        "input": Self.clipped(text),
                        "voice": voice,
                        "response_format": "mp3",
                        "instructions": instructions,
                        "speed": speed,
                    ]
                }
            )
        }

        throw VoiceAssistantError.missingAPIKey
    }

    private func environmentValue(_ name: String) -> String? {
        let value = ProcessInfo.processInfo.environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    private func environmentURL(_ name: String) -> URL? {
        environmentValue(name).flatMap(URL.init(string:))
    }

    private static func clipped(_ text: String, maxCharacters: Int = 3_800) -> String {
        guard text.count > maxCharacters else { return text }
        return "\(text.prefix(maxCharacters))"
    }

    private enum Provider {
        case gateway
        case openAI
    }

    private struct APIConfiguration {
        let provider: Provider
        let apiKey: String
        let endpoint: URL
        let headers: [String: String]
        let body: (String) -> [String: Any]
    }

    private struct GatewaySpeechEnvelope: Decodable {
        let audio: String
    }
}
