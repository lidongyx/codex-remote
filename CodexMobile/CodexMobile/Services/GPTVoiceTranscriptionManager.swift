// FILE: GPTVoiceTranscriptionManager.swift
// Purpose: Captures microphone audio with AVAudioEngine and streams normalized PCM chunks for realtime dictation.
// Layer: Service
// Exports: GPTVoiceTranscriptionManager
// Depends on: AVFoundation, Foundation

import AVFoundation
import Combine
import Foundation

private func codexLogVoiceRecording(_ message: String) {
    print("[VOICE] \(message)")
}

enum GPTVoiceTranscriptionError: LocalizedError {
    case alreadyRecording
    case notRecording
    case microphonePermissionDenied
    case missingMicrophoneInput
    case unableToConfigureAudioSession
    case unableToPrepareAudioEngine
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return "Voice recording is already running."
        case .notRecording:
            return "Voice recording is not running."
        case .microphonePermissionDenied:
            return "Microphone access is required for voice transcription."
        case .missingMicrophoneInput:
            return "No valid microphone input is available right now."
        case .unableToConfigureAudioSession:
            return "Unable to configure the microphone session."
        case .unableToPrepareAudioEngine:
            return "Unable to prepare the microphone recorder."
        case .transcriptionFailed(let message):
            return message
        }
    }
}

final class GPTVoiceTranscriptionManager: ObservableObject {
    private let audioSession = AVAudioSession.sharedInstance()
    private static let realtimeSampleRate: Double = 16_000
    // Keeps enough metering history for the capsule to resample across the full composer width.
    private static let maxAudioLevels = 240

    private var engine: AVAudioEngine?
    private var isRecording = false
    private var durationTimer: Timer?

    /// Rolling window of normalized (0…1) amplitude samples for waveform visualization.
    @Published var audioLevels: [CGFloat] = []
    /// Elapsed seconds since recording started.
    @Published var recordingDuration: TimeInterval = 0

    // ─── Recording lifecycle ─────────────────────────────────────

    @MainActor
    func startRecording(onRealtimePCMChunk: (@Sendable (Data) -> Void)? = nil) async throws {
        codexLogVoiceRecording("start requested")
        guard !isRecording else {
            throw GPTVoiceTranscriptionError.alreadyRecording
        }

        let isPermissionGranted = await requestMicrophonePermission()
        codexLogVoiceRecording("microphone permission: \(isPermissionGranted ? "granted" : "denied")")
        guard isPermissionGranted else {
            throw GPTVoiceTranscriptionError.microphonePermissionDenied
        }

        do {
            try configureAudioSession()

            let engine = AVAudioEngine()
            let inputNode = engine.inputNode
            let format = inputNode.outputFormat(forBus: 0)

            guard format.sampleRate > 0, format.channelCount > 0 else {
                codexLogVoiceRecording(
                    "invalid microphone format sampleRate=\(format.sampleRate) channels=\(format.channelCount)"
                )
                throw GPTVoiceTranscriptionError.missingMicrophoneInput
            }

            codexLogVoiceRecording(
                "capture format sampleRate=\(format.sampleRate) channels=\(format.channelCount)"
            )

            let realtimeConverter = try makeRealtimeAudioConverter(from: format)

            // Collect raw buffers on the tap thread and compute audio levels for the waveform.
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
                // Compute RMS power for waveform visualization.
                guard let channelData = buffer.floatChannelData?[0] else { return }
                let frameCount = Int(buffer.frameLength)
                guard frameCount > 0 else { return }

                var sumOfSquares: Float = 0
                let ptr = channelData
                for i in 0..<frameCount {
                    let sample = ptr[i]
                    sumOfSquares += sample * sample
                }
                let rms = sqrt(sumOfSquares / Float(frameCount))
                let dB = 20 * log10(max(rms, 1e-6))
                let normalized = CGFloat(max(0, min(1, (dB + 50) / 50)))

                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.audioLevels.append(normalized)
                    if self.audioLevels.count > Self.maxAudioLevels {
                        self.audioLevels.removeFirst(self.audioLevels.count - Self.maxAudioLevels)
                    }
                }

                if let onRealtimePCMChunk,
                   let realtimeConverter,
                   let pcmChunk = Self.convertToRealtimePCM16(buffer, using: realtimeConverter) {
                    onRealtimePCMChunk(pcmChunk)
                }
            }

            self.engine = engine
            isRecording = true

            engine.prepare()
            try engine.start()
            startDurationTimer()
            codexLogVoiceRecording("recording active")
        } catch let error as GPTVoiceTranscriptionError {
            teardownEngine()
            codexLogVoiceRecording("start failed: \(error.localizedDescription)")
            throw error
        } catch {
            teardownEngine()
            codexLogVoiceRecording("engine start threw: \(error.localizedDescription)")
            throw GPTVoiceTranscriptionError.unableToPrepareAudioEngine
        }
    }

    @MainActor
    func cancelRecording() {
        let wasRecording = isRecording
        isRecording = false

        stopDurationTimer()
        resetMeteringState()

        if wasRecording || engine != nil {
            teardownEngine()
        }
    }

    @MainActor
    func resetMeteringState() {
        audioLevels = []
        recordingDuration = 0
    }

    // ─── Duration timer ─────────────────────────────────────────

    @MainActor
    private func startDurationTimer() {
        recordingDuration = 0
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.recordingDuration += 0.1
            }
        }
    }

    @MainActor
    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
    }

    // ─── Mic permission ──────────────────────────────────────────

    private func requestMicrophonePermission() async -> Bool {
#if os(iOS)
        if #available(iOS 17.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted:
                return true
            case .denied:
                return false
            case .undetermined:
                break
            @unknown default:
                return false
            }

            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { allowed in
                    continuation.resume(returning: allowed)
                }
            }
        }
#endif
        switch audioSession.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            break
        @unknown default:
            return false
        }

        return await withCheckedContinuation { continuation in
            audioSession.requestRecordPermission { allowed in
                continuation.resume(returning: allowed)
            }
        }
    }

    // ─── Audio session ───────────────────────────────────────────

    @MainActor
    private func configureAudioSession() throws {
        do {
            try audioSession.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, .allowBluetoothHFP]
            )
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

            let inputs = audioSession.currentRoute.inputs.map { "\($0.portType.rawValue):\($0.portName)" }
            codexLogVoiceRecording("active input route: \(inputs.isEmpty ? "none" : inputs.joined(separator: ", "))")
            codexLogVoiceRecording("hardware sampleRate=\(audioSession.sampleRate) channels=\(audioSession.inputNumberOfChannels)")

            guard !audioSession.currentRoute.inputs.isEmpty else {
                throw GPTVoiceTranscriptionError.missingMicrophoneInput
            }
        } catch {
            if let recordingError = error as? GPTVoiceTranscriptionError {
                throw recordingError
            }
            codexLogVoiceRecording("audio session config failed: \(error.localizedDescription)")
            throw GPTVoiceTranscriptionError.unableToConfigureAudioSession
        }
    }

    // ─── Engine teardown ─────────────────────────────────────────

    @MainActor
    private func teardownEngine() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            if engine.isRunning { engine.stop() }
        }
        engine = nil
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func makeRealtimeAudioConverter(from inputFormat: AVAudioFormat) throws -> AVAudioConverter? {
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.realtimeSampleRate,
            channels: 1,
            interleaved: true
        ) else {
            throw GPTVoiceTranscriptionError.unableToPrepareAudioEngine
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw GPTVoiceTranscriptionError.unableToPrepareAudioEngine
        }

        return converter
    }

    private static func convertToRealtimePCM16(
        _ inputBuffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter
    ) -> Data? {
        let ratio = realtimeSampleRate / max(inputBuffer.format.sampleRate, 1)
        let estimatedFrameCount = max(1, Int((Double(inputBuffer.frameLength) * ratio).rounded(.up)))
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: converter.outputFormat,
            frameCapacity: AVAudioFrameCount(estimatedFrameCount)
        ) else {
            return nil
        }

        var didProvideInput = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outputStatus in
            if didProvideInput {
                outputStatus.pointee = .noDataNow
                return nil
            }

            didProvideInput = true
            outputStatus.pointee = .haveData
            return inputBuffer
        }

        if conversionError != nil || (status != .haveData && status != .inputRanDry) || outputBuffer.frameLength == 0 {
            return nil
        }

        let audioBuffer = outputBuffer.audioBufferList.pointee.mBuffers
        guard let dataPointer = audioBuffer.mData else {
            return nil
        }

        let byteCount = Int(audioBuffer.mDataByteSize)
        guard byteCount > 0 else {
            return nil
        }

        return Data(bytes: dataPointer, count: byteCount)
    }
}
