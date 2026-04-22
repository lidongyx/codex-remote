// FILE: CodexService+Voice.swift
// Purpose: Sends recorded voice clips to the bridge so transcription stays on the Mac-side auth/provider context.
// Layer: Service
// Exports: CodexVoiceTranscriptionPreflight, CodexService voice helpers
// Depends on: Foundation, RPCMessage, JSONValue

import Foundation

struct CodexVoiceTranscriptionPreflight: Equatable, Sendable {
    static let maxDurationSeconds: TimeInterval = 120
    static let maxByteCount: Int = 10 * 1024 * 1024

    let byteCount: Int
    let durationSeconds: TimeInterval

    var failureMessage: String? {
        if durationSeconds > Self.maxDurationSeconds {
            return "Voice clips must be 120 seconds or less."
        }

        if byteCount > Self.maxByteCount {
            return "Voice clips must be smaller than 10 MB."
        }

        return nil
    }

    func validate() throws {
        if let failureMessage {
            throw CodexServiceError.invalidInput(failureMessage)
        }
    }
}

extension CodexService {
    // Sends the local WAV clip through the bridge so the Mac-side ChatGPT/API auth
    // context stays private and provider-specific routing happens on the bridge.
    func transcribeVoiceAudioFile(at url: URL, durationSeconds: TimeInterval) async throws -> String {
        guard isConnected else {
            throw CodexServiceError.disconnected
        }

        let audioData = try Data(contentsOf: url)
        let preflight = CodexVoiceTranscriptionPreflight(
            byteCount: audioData.count,
            durationSeconds: durationSeconds
        )
        try preflight.validate()

        let response: RPCMessage
        do {
            response = try await sendRequest(
                method: "voice/transcribe",
                params: .object([
                    "mimeType": .string("audio/wav"),
                    "audioBase64": .string(audioData.base64EncodedString()),
                    "sampleRateHz": .integer(24_000),
                    "durationMs": .integer(Int((durationSeconds * 1_000).rounded())),
                ])
            )
        } catch {
            _ = consumeUnsupportedVoiceBridgeAuth(error)
            Task { await refreshGPTAccountState() }
            throw error
        }

        guard let payload = response.result?.objectValue,
              let text = payload["text"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            throw CodexServiceError.invalidResponse("voice/transcribe did not return any text")
        }

        return text
    }
}
