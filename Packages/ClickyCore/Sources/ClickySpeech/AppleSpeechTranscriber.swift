import AVFoundation
import Foundation
import Speech

/// Fallback engine: Apple's on-device speech recognizer. It never sends audio off the Mac
/// (`requiresOnDeviceRecognition`), but it needs the Speech Recognition permission and the app's
/// `NSSpeechRecognitionUsageDescription`, so it must not be called from `swift test`.
public final class AppleSpeechTranscriber: SpeechTranscriber {
    public let engineName = "Apple Speech (on device)"

    public init() {}

    /// Asks for Speech Recognition permission when it has not been asked yet.
    public static func requestAuthorization() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
        default: return false
        }
    }

    public func transcribe(samples: [Float], sampleRate: Double) async throws -> String {
        guard sampleRate == 16_000 else { throw SpeechError.unsupportedSampleRate(sampleRate) }
        guard await Self.requestAuthorization() else { throw SpeechError.speechRecognitionNotAuthorized }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
            recognizer.supportsOnDeviceRecognition
        else { throw SpeechError.speechRecognizerUnavailable }

        let format = PCMSampleConverter.targetFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
            let channel = buffer.floatChannelData
        else { throw SpeechError.speechRecognizerUnavailable }
        samples.withUnsafeBufferPointer { channel[0].update(from: $0.baseAddress!, count: samples.count) }
        buffer.frameLength = AVAudioFrameCount(samples.count)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        request.append(buffer)
        request.endAudio()

        return try await withCheckedThrowingContinuation { continuation in
            var hasResumed = false
            // The recognizer calls this on its own queue, one result at a time.
            _ = recognizer.recognitionTask(with: request) { result, error in
                guard !hasResumed else { return }
                if let result, result.isFinal {
                    hasResumed = true
                    continuation.resume(returning: result.bestTranscription.formattedString)
                } else if let error {
                    hasResumed = true
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
