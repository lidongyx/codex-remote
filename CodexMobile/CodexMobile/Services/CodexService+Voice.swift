// FILE: CodexService+Voice.swift
// Purpose: Reads bridge-managed Bailian realtime config for iPhone-side dictation.
// Layer: Service
// Exports: CodexVoiceTranscriptionPreflight, CodexService voice helpers
// Depends on: Foundation

import Foundation

struct CodexVoiceTranscriptionPreflight: Equatable, Sendable {
    static let maxDurationSeconds: TimeInterval = 120
}

struct CodexRealtimeVoiceConfig: Equatable, Sendable {
    let provider: String
    let websocketURL: URL
    let apiKey: String
    let model: String
    let language: String
    let inputSampleRateHz: Int
    let inputEncoding: String
    let vadSilenceDurationMs: Int
    let vadThreshold: Double
}

extension CodexService {
    // Resolves bridge-managed Bailian realtime dictation config without proxying microphone audio through the bridge.
    func resolveRealtimeVoiceConfig() async throws -> CodexRealtimeVoiceConfig {
        guard isConnected else {
            throw CodexServiceError.disconnected
        }

        let response = try await sendRequest(method: "voice/realtimeConfig", params: nil)
        guard let payload = response.result?.objectValue else {
            throw CodexServiceError.invalidResponse("voice/realtimeConfig did not return a payload")
        }

        guard let provider = payload["provider"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !provider.isEmpty else {
            throw CodexServiceError.invalidResponse("voice/realtimeConfig did not include a provider")
        }
        guard let websocketURLString = payload["websocketURL"]?.stringValue ?? payload["websocketUrl"]?.stringValue,
              let websocketURL = URL(string: websocketURLString) else {
            throw CodexServiceError.invalidResponse("voice/realtimeConfig did not include a valid websocket URL")
        }
        guard let apiKey = payload["apiKey"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.isEmpty else {
            throw CodexServiceError.invalidResponse("voice/realtimeConfig did not include an API key")
        }
        guard let model = payload["model"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !model.isEmpty else {
            throw CodexServiceError.invalidResponse("voice/realtimeConfig did not include a model")
        }
        let language = payload["language"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "zh"
        let inputSampleRateHz = payload["inputSampleRateHz"]?.intValue ?? 16_000
        let inputEncoding = payload["inputEncoding"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "pcm16"
        let vadSilenceDurationMs = payload["vadSilenceDurationMs"]?.intValue ?? 400
        let vadThreshold = payload["vadThreshold"]?.doubleValue ?? 0.5

        return CodexRealtimeVoiceConfig(
            provider: provider,
            websocketURL: websocketURL,
            apiKey: apiKey,
            model: model,
            language: language,
            inputSampleRateHz: inputSampleRateHz,
            inputEncoding: inputEncoding,
            vadSilenceDurationMs: vadSilenceDurationMs,
            vadThreshold: vadThreshold
        )
    }
}
