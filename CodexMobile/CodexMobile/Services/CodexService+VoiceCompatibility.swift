// FILE: CodexService+VoiceCompatibility.swift
// Purpose: Maps voice-mode runtime failures into stable recovery reasons the UI can present cleanly.
// Layer: Service
// Exports: CodexVoiceFailureReason, CodexService voice compatibility helpers
// Depends on: Foundation, CodexServiceError, GPTVoiceTranscriptionError

import Foundation

enum CodexVoiceFailureReason: Equatable {
    case reconnectRequired
    case bridgeSessionUnsupported
    case macLoginRequired
    case macReauthenticationRequired
    case voiceSyncInProgress
    case chatGPTRequired
    case microphonePermissionRequired
    case microphoneUnavailable
    case recorderUnavailable
    case providerSpecific(summary: String, detail: String)
    case generic(String)
}

extension CodexService {
    // Learns that this bridge predates the bridge-owned voice RPCs so future mic taps can short-circuit immediately.
    func consumeUnsupportedVoiceBridgeAuth(_ error: Error) -> Bool {
        guard shouldTreatAsUnsupportedVoiceBridgeAuth(error) else {
            return false
        }

        supportsBridgeVoiceAuth = false
        return true
    }

    // Normalizes voice failures from the recorder, bridge RPC, and transcription API into UI-friendly buckets.
    func classifyVoiceFailure(_ error: Error) -> CodexVoiceFailureReason {
        if !supportsBridgeVoiceAuth || shouldTreatAsUnsupportedVoiceBridgeAuth(error) {
            return .bridgeSessionUnsupported
        }

        if let voiceError = error as? GPTVoiceTranscriptionError {
            return classifyVoiceFailure(voiceError)
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
        let mentionsBridgeVoiceMethod = message.contains("voice/resolveauth")
            || message.contains("voice resolveauth")
            || message.contains("voice/resolveauth`")
            || message.contains("voice/transcribe")
            || message.contains("voice transcribe")
            || message.contains("voice/transcribe`")

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
             .unableToCreateOutputFile,
             .alreadyRecording,
             .notRecording:
            return .recorderUnavailable
        case .authExpired:
            return .macReauthenticationRequired
        case .transcriptionFailed(let message):
            return classifyVoiceFailureMessage(message)
        }
    }

    private func classifyVoiceRPCError(_ rpcError: RPCError) -> CodexVoiceFailureReason? {
        let bridgeErrorCode = rpcError.data?.objectValue?["errorCode"]?.stringValue?.lowercased()
        switch bridgeErrorCode {
        case "auth_unavailable":
            return .reconnectRequired
        case "token_missing", "not_authenticated":
            return classifyMissingVoiceTokenState()
        case "not_chatgpt":
            return .chatGPTRequired
        case "api_transcription_temporarily_unavailable":
            return .providerSpecific(
                summary: "当前语音服务正忙，请稍后重试。",
                detail: "Remodex 已经自动尝试了可回退的转写模型，但你 Mac 上当前这条 Sub2API 路由暂时没有空闲的语音转写容量。"
            )
        case "api_transcription_endpoint_missing":
            return .providerSpecific(
                summary: "当前 Sub2API 路由没有可用的语音转写接口。",
                detail: "这条 Mac 端 provider 配置虽然能用于文本模型，但没有暴露兼容的 speech-to-text endpoint，所以手机语音无法转写。"
            )
        case "api_transcription_model_missing":
            return .providerSpecific(
                summary: "当前 Sub2API key 没有绑定语音转写模型。",
                detail: "这条路由只暴露了聊天或音频预览模型，没有提供 whisper 或 transcribe 类模型，所以 `/v1/audio/transcriptions` 不能工作。"
            )
        case "api_transcription_body_rejected":
            return .providerSpecific(
                summary: "当前 Sub2API 语音转写后端返回了无效请求。",
                detail: "Remodex 发出的 WAV multipart 请求已经符合标准 OpenAI transcription 形状，这个错误更像是你 Sub2API 服务器后端的语音实现或上游适配存在问题。"
            )
        default:
            return nil
        }
    }

    private func classifyMissingVoiceTokenState() -> CodexVoiceFailureReason {
        if gptAccountSnapshot.needsReauth || gptAccountSnapshot.status == .expired {
            return .macReauthenticationRequired
        }

        if gptAccountSnapshot.isAuthenticated && !gptAccountSnapshot.isVoiceTokenReady {
            return .voiceSyncInProgress
        }

        if gptAccountSnapshot.hasActiveLogin
            || gptAccountSnapshot.status == .notLoggedIn
            || gptAccountSnapshot.status == .unknown {
            return .macLoginRequired
        }

        return .chatGPTRequired
    }

    // Clears auth-driven recovery once the refreshed snapshot is healthy again.
    // used by: TurnView voice recovery banner
    private func resolveAuthSensitiveVoiceRecoveryReason() -> CodexVoiceFailureReason? {
        guard !gptAccountSnapshot.isAuthenticated || !gptAccountSnapshot.isVoiceTokenReady else {
            return nil
        }

        return classifyMissingVoiceTokenState()
    }

    // Re-derives auth-sensitive voice recovery from the latest bridge snapshot so stale
    // in-flight refreshes do not leave the banner stuck on the wrong instruction.
    func resolveVoiceRecoveryReason(_ reason: CodexVoiceFailureReason) -> CodexVoiceFailureReason? {
        switch reason {
        case .macLoginRequired, .macReauthenticationRequired, .voiceSyncInProgress:
            return resolveAuthSensitiveVoiceRecoveryReason()
        default:
            return reason
        }
    }

    private func classifyVoiceFailureMessage(_ message: String) -> CodexVoiceFailureReason {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .generic("Voice transcription failed.")
        }

        let normalized = trimmed.lowercased()
        if (normalized.contains("voice/resolveauth") || normalized.contains("voice/transcribe"))
            && normalized.contains("unknown variant") {
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
        if normalized.contains("chatgpt login has expired")
            || normalized.contains("fresh sign-in")
            || normalized.contains("sign in again") {
            return .macReauthenticationRequired
        }
        if normalized.contains("waiting for voice sync") {
            return .voiceSyncInProgress
        }
        if normalized.contains("sign in to chatgpt")
            || normalized.contains("no chatgpt session token") {
            return classifyMissingVoiceTokenState()
        }
        if normalized.contains("requires a chatgpt account") {
            return .chatGPTRequired
        }
        if normalized.contains("does not expose openai transcription models")
            || normalized.contains("did not advertise any transcription-capable models") {
            return .providerSpecific(
                summary: "当前 Sub2API key 没有绑定语音转写模型。",
                detail: "这条路由只暴露了聊天或音频预览模型，没有提供 whisper 或 transcribe 类模型，所以 `/v1/audio/transcriptions` 不能工作。"
            )
        }
        if normalized.contains("did not expose a compatible speech-to-text endpoint") {
            return .providerSpecific(
                summary: "当前 Sub2API 路由没有可用的语音转写接口。",
                detail: "这条 Mac 端 provider 配置虽然能用于文本模型，但没有暴露兼容的 speech-to-text endpoint，所以手机语音无法转写。"
            )
        }
        if normalized.contains("multipart upload")
            || normalized.contains("provider-side transcription implementation issue")
            || normalized.contains("failed to parse request body") {
            return .providerSpecific(
                summary: "当前 Sub2API 语音转写后端返回了无效请求。",
                detail: "Remodex 发出的 WAV multipart 请求已经符合标准 OpenAI transcription 形状，这个错误更像是你 Sub2API 服务器后端的语音实现或上游适配存在问题。"
            )
        }
        if normalized.contains("temporarily busy for speech-to-text")
            || normalized.contains("transcription capacity") {
            return .providerSpecific(
                summary: "当前语音服务正忙，请稍后重试。",
                detail: "Remodex 已经自动尝试了可回退的转写模型，但你 Mac 上当前这条 Sub2API 路由暂时没有空闲的语音转写容量。"
            )
        }

        return .generic(trimmed)
    }
}
