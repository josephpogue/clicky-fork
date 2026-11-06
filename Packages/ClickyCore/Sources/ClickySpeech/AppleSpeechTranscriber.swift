import AVFoundation
import Foundation
import Speech

/// Fallback engine: Apple's on-device speech recognizer. It never sends audio off the Mac
/// (`requiresOnDeviceRecognition`), but it needs the Speech Recognition permission and the app's
/// `NSSpeechRecognitionUsageDescription`, so it must not be called from `swift test`.
public final class AppleSpeechTranscriber: SpeechTranscriber {
    /// What `engineName` reads for this engine; the app compares against it to say which engine it got.
    public static let engineDisplayName = "Apple Speech (on device)"
    public let engineName = AppleSpeechTranscriber.engineDisplayName

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

        // The recognizer answers with a final result or an error. If it does neither (no speech found,
        // the on-device model missing), the deadline turns that silence into an error the app can show.
        let outcome = FirstResult<String>()
        let recognitionTask = recognizer.recognitionTask(with: request) { result, error in
            if let result, result.isFinal {
                outcome.finish(.success(result.bestTranscription.formattedString))
            } else if let error {
                outcome.finish(.failure(error))
            }
        }
        let audioSeconds = Double(samples.count) / sampleRate
        let deadline = Task {
            try? await Task.sleep(nanoseconds: UInt64((Self.recognitionBaseSeconds + audioSeconds) * 1_000_000_000))
            if !Task.isCancelled, outcome.finish(.failure(SpeechError.speechRecognitionTimedOut)) {
                recognitionTask.cancel()
            }
        }
        defer { deadline.cancel() }
        return try await outcome.value()
    }

    /// Time allowed for the recognizer on top of the audio's own length.
    private static let recognitionBaseSeconds = 20.0
}
