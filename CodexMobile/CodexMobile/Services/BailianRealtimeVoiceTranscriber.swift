// FILE: BailianRealtimeVoiceTranscriber.swift
// Purpose: Streams 16 kHz PCM chunks directly from iPhone to Bailian realtime ASR and relays partial/final text back to the composer.
// Layer: Service
// Exports: BailianRealtimeVoiceError, BailianRealtimeVoiceTranscriber
// Depends on: Foundation

import Foundation

enum BailianRealtimeVoiceError: LocalizedError {
    case invalidConfiguration(String)
    case authenticationFailed(String)
    case connectionFailed(String)
    case serverRejected(String)
    case invalidServerResponse(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message),
             .authenticationFailed(let message),
             .connectionFailed(let message),
             .serverRejected(let message),
             .invalidServerResponse(let message):
            return message
        }
    }
}

final class BailianRealtimeWebSocketDelegate: NSObject, URLSessionWebSocketDelegate, URLSessionTaskDelegate {
    private let lock = NSLock()
    private var openContinuation: CheckedContinuation<Void, Error>?
    private var openResult: Result<Void, Error>?

    func waitForOpen() async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            defer { lock.unlock() }
            if let openResult {
                continuation.resume(with: openResult)
                return
            }
            openContinuation = continuation
        }
    }

    func resolveOpen(with result: Result<Void, Error>) {
        lock.lock()
        guard openResult == nil else {
            lock.unlock()
            return
        }
        openResult = result
        let continuation = openContinuation
        openContinuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        resolveOpen(with: .success(()))
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        if closeCode == .invalid {
            resolveOpen(with: .failure(CodexServiceError.disconnected))
            return
        }

        resolveOpen(
            with: .failure(
                BailianRealtimeVoiceError.connectionFailed(
                    "Bailian realtime dictation closed during connect (\(closeCode.rawValue))."
                )
            )
        )
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            resolveOpen(with: .failure(error))
        }
    }
}

actor BailianRealtimeVoiceTranscriber {
    enum Event {
        case partial(String)
        case final(String)
    }

    typealias EventHandler = @Sendable (Event) -> Void

    private var config: CodexRealtimeVoiceConfig?
    private var delegate: BailianRealtimeWebSocketDelegate?
    private var urlSession: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveLoopTask: Task<Void, Never>?
    private var eventHandler: EventHandler?
    private var sessionReadyContinuation: CheckedContinuation<Void, Error>?
    private var sessionFinishedContinuation: CheckedContinuation<Void, Error>?
    private var isSessionReady = false
    private var isSessionFinished = false
    private var terminalError: Error?
    private var lastPreviewText = ""
    private var hasSentAudio = false

    func start(config: CodexRealtimeVoiceConfig, onEvent: @escaping EventHandler) async throws {
        guard config.inputEncoding.lowercased() == "pcm16" else {
            throw BailianRealtimeVoiceError.invalidConfiguration(
                "Bailian realtime dictation currently expects pcm16 audio."
            )
        }
        guard config.inputSampleRateHz == 16_000 else {
            throw BailianRealtimeVoiceError.invalidConfiguration(
                "Bailian realtime dictation currently expects 16 kHz audio."
            )
        }

        let requestURL = try websocketURL(for: config)
        let delegate = BailianRealtimeWebSocketDelegate()
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)

        var request = URLRequest(url: requestURL)
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")

        let task = session.webSocketTask(with: request)

        self.config = config
        self.delegate = delegate
        self.urlSession = session
        self.webSocketTask = task
        self.eventHandler = onEvent
        self.isSessionReady = false
        self.isSessionFinished = false
        self.terminalError = nil
        self.lastPreviewText = ""
        self.hasSentAudio = false

        task.resume()
        try await delegate.waitForOpen()
        receiveLoopTask = Task {
            await self.receiveLoop()
        }
        try await send(event: sessionUpdateEvent(for: config))
        try await waitForSessionReady()
    }

    func appendAudioPCM16(_ data: Data) async {
        guard terminalError == nil, !isSessionFinished, !data.isEmpty else {
            return
        }

        hasSentAudio = true
        do {
            try await send(event: [
                "event_id": eventID(),
                "type": "input_audio_buffer.append",
                "audio": data.base64EncodedString(),
            ])
        } catch {
            fail(with: normalizeTransportError(error))
        }
    }

    func finish() async throws {
        guard terminalError == nil else {
            throw terminalError!
        }
        guard !isSessionFinished else {
            return
        }

        if hasSentAudio, let config {
            let trailingSilenceMs = max(config.vadSilenceDurationMs + 120, 520)
            await appendAudioPCM16(Self.makeSilencePCM16Data(
                sampleRateHz: config.inputSampleRateHz,
                durationMs: trailingSilenceMs
            ))
        }

        do {
            try await send(event: [
                "event_id": eventID(),
                "type": "session.finish",
            ])
            try await waitForSessionFinished()
        } catch {
            throw normalizeTransportError(error)
        }

        if let terminalError {
            throw terminalError
        }
    }

    func cancel() async {
        closeTransport()
        sessionReadyContinuation?.resume(throwing: CodexServiceError.disconnected)
        sessionReadyContinuation = nil
        sessionFinishedContinuation?.resume(returning: ())
        sessionFinishedContinuation = nil
    }

    private func websocketURL(for config: CodexRealtimeVoiceConfig) throws -> URL {
        guard var components = URLComponents(url: config.websocketURL, resolvingAgainstBaseURL: false) else {
            throw BailianRealtimeVoiceError.invalidConfiguration("Invalid Bailian realtime websocket URL.")
        }

        var queryItems = components.queryItems ?? []
        if !queryItems.contains(where: { $0.name == "model" }) {
            queryItems.append(URLQueryItem(name: "model", value: config.model))
        }
        components.queryItems = queryItems

        guard let resolvedURL = components.url else {
            throw BailianRealtimeVoiceError.invalidConfiguration("Invalid Bailian realtime websocket URL.")
        }
        return resolvedURL
    }

    private func sessionUpdateEvent(for config: CodexRealtimeVoiceConfig) -> [String: Any] {
        [
            "event_id": eventID(),
            "type": "session.update",
            "session": [
                "input_audio_format": "pcm",
                "sample_rate": config.inputSampleRateHz,
                "input_audio_transcription": [
                    "language": config.language,
                ],
                "turn_detection": [
                    "type": "server_vad",
                    "threshold": config.vadThreshold,
                    "silence_duration_ms": config.vadSilenceDurationMs,
                ],
            ],
        ]
    }

    private func send(event: [String: Any]) async throws {
        guard let webSocketTask else {
            throw CodexServiceError.disconnected
        }

        let payload = try JSONSerialization.data(withJSONObject: event)
        guard let payloadString = String(data: payload, encoding: .utf8) else {
            throw BailianRealtimeVoiceError.invalidServerResponse(
                "Failed to encode Bailian realtime dictation request."
            )
        }

        try await webSocketTask.send(.string(payloadString))
    }

    private func waitForSessionReady() async throws {
        if let terminalError {
            throw terminalError
        }
        if isSessionReady {
            return
        }

        try await withCheckedThrowingContinuation { continuation in
            sessionReadyContinuation = continuation
        }
    }

    private func waitForSessionFinished() async throws {
        if let terminalError {
            throw terminalError
        }
        if isSessionFinished {
            return
        }

        try await withCheckedThrowingContinuation { continuation in
            sessionFinishedContinuation = continuation
        }
    }

    private func receiveLoop() async {
        guard let webSocketTask else {
            return
        }

        while terminalError == nil && !isSessionFinished {
            do {
                let message = try await webSocketTask.receive()
                let payloadData: Data
                switch message {
                case .data(let data):
                    payloadData = data
                case .string(let string):
                    payloadData = Data(string.utf8)
                @unknown default:
                    continue
                }

                try handleServerMessage(payloadData)
            } catch {
                if terminalError == nil && !isSessionFinished {
                    fail(with: normalizeTransportError(error))
                }
                return
            }
        }
    }

    private func handleServerMessage(_ payloadData: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              let type = object["type"] as? String else {
            throw BailianRealtimeVoiceError.invalidServerResponse(
                "Bailian realtime dictation returned an unreadable event."
            )
        }

        switch type {
        case "session.updated":
            isSessionReady = true
            sessionReadyContinuation?.resume(returning: ())
            sessionReadyContinuation = nil
        case "conversation.item.input_audio_transcription.text":
            let previewText = transcriptPreview(from: object)
            lastPreviewText = previewText
            eventHandler?(.partial(previewText))
        case "conversation.item.input_audio_transcription.completed":
            let transcript = readString(object["transcript"]) ?? lastPreviewText
            lastPreviewText = transcript
            eventHandler?(.final(transcript))
        case "conversation.item.input_audio_transcription.failed":
            let message = readErrorMessage(from: object["error"])
                ?? "Bailian realtime dictation failed to transcribe this utterance."
            fail(with: BailianRealtimeVoiceError.serverRejected(message))
        case "error":
            let code = readString((object["error"] as? [String: Any])?["code"])?.lowercased()
            let message = readErrorMessage(from: object["error"])
                ?? "Bailian realtime dictation returned an unknown error."
            if code == "invalid_api_key" || code == "unauthorized" || code == "forbidden" {
                fail(with: BailianRealtimeVoiceError.authenticationFailed(message))
            } else {
                fail(with: BailianRealtimeVoiceError.serverRejected(message))
            }
        case "session.finished":
            isSessionFinished = true
            sessionFinishedContinuation?.resume(returning: ())
            sessionFinishedContinuation = nil
            closeTransport()
        default:
            return
        }
    }

    private func transcriptPreview(from object: [String: Any]) -> String {
        let confirmedText = readString(object["text"]) ?? ""
        let stashText = readString(object["stash"]) ?? ""
        return (confirmedText + stashText).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func fail(with error: Error) {
        guard terminalError == nil else {
            return
        }

        terminalError = error
        sessionReadyContinuation?.resume(throwing: error)
        sessionReadyContinuation = nil
        sessionFinishedContinuation?.resume(throwing: error)
        sessionFinishedContinuation = nil
        closeTransport()
    }

    private func closeTransport() {
        receiveLoopTask?.cancel()
        receiveLoopTask = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        delegate = nil
    }

    private func normalizeTransportError(_ error: Error) -> Error {
        if let realtimeError = error as? BailianRealtimeVoiceError {
            return realtimeError
        }
        if error is CancellationError {
            return BailianRealtimeVoiceError.connectionFailed("Bailian realtime dictation was cancelled.")
        }
        if let urlError = error as? URLError {
            return BailianRealtimeVoiceError.connectionFailed(
                "Could not connect to Bailian realtime dictation (\(urlError.localizedDescription))."
            )
        }
        return BailianRealtimeVoiceError.connectionFailed(error.localizedDescription)
    }

    private func readErrorMessage(from value: Any?) -> String? {
        guard let object = value as? [String: Any] else {
            return nil
        }

        return readString(object["message"])
    }

    private func readString(_ value: Any?) -> String? {
        guard let value = value as? String else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func eventID() -> String {
        "event_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
    }

    private static func makeSilencePCM16Data(sampleRateHz: Int, durationMs: Int) -> Data {
        let frameCount = max(1, Int((Double(sampleRateHz) * Double(durationMs)) / 1000.0))
        return Data(count: frameCount * MemoryLayout<Int16>.size)
    }
}
