// FILE: CodexService+VoiceCompatibility.swift
// Purpose: Maps Bailian realtime voice failures into stable recovery reasons the UI can present cleanly.
// Layer: Service
// Exports: CodexVoiceFailureReason, CodexService voice compatibility helpers
// Depends on: Foundation, CodexServiceError, GPTVoiceTranscriptionError

import Foundation

enum CodexVoiceFailureReason: Equatable {
    case reconnectRequired
    case bridgeSessionUnsupported
    case microphonePermissionRequired
    case microphoneUnavailable
    case recorderUnavailable
    case providerSpecific(summary: String, detail: String)
    case generic(String)
}

extension CodexService {
    // Learns that this bridge predates the Bailian realtime voice RPC so future mic taps can short-circuit immediately.
    func consumeUnsupportedVoiceBridgeAuth(_ error: Error) -> Bool {
        guard shouldTreatAsUnsupportedVoiceBridgeAuth(error) else {
            return false
        }

        supportsBridgeVoiceAuth = false
        return true
    }

    // Normalizes voice failures from the recorder, bridge RPC, and Bailian realtime session into UI-friendly buckets.
    func classifyVoiceFailure(_ error: Error) -> CodexVoiceFailureReason {
        if !supportsBridgeVoiceAuth || shouldTreatAsUnsupportedVoiceBridgeAuth(error) {
            return .bridgeSessionUnsupported
        }

        if let voiceError = error as? GPTVoiceTranscriptionError {
            return classifyVoiceFailure(voiceError)
        }

        if let realtimeVoiceError = error as? BailianRealtimeVoiceError {
            return classifyVoiceFailure(realtimeVoiceError)
        }

        guard let serviceError = error as? CodexServiceError else {
            let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            return .generic(message.isEmpty ? "Voice transcription failed." : message)
        }

        switch serviceError {
        case .disconnected:
            return .reconnectRequired
        case .invalidInput(let reason), .invalidResponse(let reason):
            return classifyVoiceFailureMessage(reason)
        case .rpcError(let rpcError):
            if let classifiedRPCError = classifyVoiceRPCError(rpcError) {
                return classifiedRPCError
            }
            return classifyVoiceFailureMessage(rpcError.message)
        case .invalidServerURL(_), .encodingFailed, .noPendingApproval:
            return .generic(serviceError.localizedDescription)
        }
    }

    func shouldTreatAsUnsupportedVoiceBridgeAuth(_ error: Error) -> Bool {
        guard let serviceError = error as? CodexServiceError,
              case .rpcError(let rpcError) = serviceError else {
            return false
        }

        if rpcError.code == -32601 {
            return true
        }

        let message = rpcError.message.lowercased()
        let mentionsUnsupportedRequest = message.contains("method not found")
            || message.contains("unknown method")
            || message.contains("not implemented")
            || message.contains("does not support")
            || message.contains("unknown variant")
            || message.contains("expected one of")
        let mentionsBridgeVoiceMethod = message.contains("voice/realtimeconfig")
            || message.contains("voice realtimeconfig")
            || message.contains("voice/realtimeconfig`")

        guard rpcError.code == -32600 || rpcError.code == -32602 || rpcError.code == -32000 else {
            return mentionsUnsupportedRequest && mentionsBridgeVoiceMethod
        }

        return mentionsUnsupportedRequest && mentionsBridgeVoiceMethod
    }

    private func classifyVoiceFailure(_ error: GPTVoiceTranscriptionError) -> CodexVoiceFailureReason {
        switch error {
        case .microphonePermissionDenied:
            return .microphonePermissionRequired
        case .missingMicrophoneInput:
            return .microphoneUnavailable
        case .unableToConfigureAudioSession,
             .unableToPrepareAudioEngine,
             .alreadyRecording,
             .notRecording:
            return .recorderUnavailable
        case .transcriptionFailed(let message):
            return classifyVoiceFailureMessage(message)
        }
    }

    private func classifyVoiceFailure(_ error: BailianRealtimeVoiceError) -> CodexVoiceFailureReason {
        switch error {
        case .invalidConfiguration:
            return .providerSpecific(
                summary: "百炼实时听写配置无效。",
                detail: error.localizedDescription
            )
        case .authenticationFailed:
            return .providerSpecific(
                summary: "百炼实时听写鉴权失败。",
                detail: error.localizedDescription
            )
        case .serverRejected:
            return .providerSpecific(
                summary: "百炼实时听写拒绝了这次会话。",
                detail: error.localizedDescription
            )
        case .connectionFailed, .invalidServerResponse:
            return .generic(error.localizedDescription)
        }
    }

    private func classifyVoiceRPCError(_ rpcError: RPCError) -> CodexVoiceFailureReason? {
        let bridgeErrorCode = rpcError.data?.objectValue?["errorCode"]?.stringValue?.lowercased()
        switch bridgeErrorCode {
        case "auth_unavailable":
            return .reconnectRequired
        case "realtime_config_missing":
            return .providerSpecific(
                summary: "请先在 Mac 上配置百炼实时听写。",
                detail: "先在本地 bridge 环境里设置 `DASHSCOPE_API_KEY`，然后重新连接后再试。"
            )
        default:
            return nil
        }
    }

    // Voice recovery is no longer tied to ChatGPT/API auth state; keep the latest reason verbatim.
    func resolveVoiceRecoveryReason(_ reason: CodexVoiceFailureReason) -> CodexVoiceFailureReason? {
        reason
    }

    private func classifyVoiceFailureMessage(_ message: String) -> CodexVoiceFailureReason {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .generic("Voice transcription failed.")
        }

        let normalized = trimmed.lowercased()
        if normalized.contains("voice/realtimeconfig") && normalized.contains("unknown variant") {
            return .bridgeSessionUnsupported
        }
        if normalized.contains("connect to your mac before using voice transcription")
            || normalized == CodexServiceError.disconnected.localizedDescription.lowercased()
            || normalized.contains("bridge running")
            || normalized.contains("reconnect") {
            return .reconnectRequired
        }
        if normalized.contains("microphone access") {
            return .microphonePermissionRequired
        }
        if normalized.contains("no valid microphone input") {
            return .microphoneUnavailable
        }
        if normalized.contains("unable to configure the microphone")
            || normalized.contains("unable to prepare the microphone")
            || normalized.contains("unable to create the temporary audio file") {
            return .recorderUnavailable
        }
        if normalized.contains("dashscope_api_key")
            || normalized.contains("bailian realtime")
            || normalized.contains("百炼") {
            return .providerSpecific(
                summary: "请先在 Mac 上配置百炼实时听写。",
                detail: trimmed
            )
        }

        return .generic(trimmed)
    }
}
