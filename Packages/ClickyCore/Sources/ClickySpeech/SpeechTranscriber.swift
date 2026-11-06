import Foundation

/// Turns spoken audio into text, on the Mac, with no network request.
public protocol SpeechTranscriber: Sendable {
    /// Short name of the engine, for logs and the settings screen.
    var engineName: String { get }

    /// Transcribes one stretch of speech. `samples` are mono Float samples in -1...1 at `sampleRate`
    /// (16 kHz for every engine here).
    func transcribe(samples: [Float], sampleRate: Double) async throws -> String
}

public enum SpeechError: LocalizedError, Sendable, Equatable {
    case unsupportedSampleRate(Double)
    case speechRecognitionNotAuthorized
    case speechRecognizerUnavailable
    case microphonePermissionDenied
    case microphoneUnavailable(String)
    case audioFileUnreadable(String)
    case noSessionRunning

    public var errorDescription: String? {
        switch self {
        case .unsupportedSampleRate(let rate):
            return "The speech engine needs 16 kHz audio but got \(rate) Hz."
        case .speechRecognitionNotAuthorized:
            return "Speech recognition is not allowed for this app."
        case .speechRecognizerUnavailable:
            return "On-device speech recognition is not available on this Mac."
        case .microphonePermissionDenied:
            return "The microphone is not allowed for this app. Turn it on in System Settings, Privacy and Security."
        case .microphoneUnavailable(let reason):
            return "The microphone could not start: \(reason)"
        case .noSessionRunning:
            return "No listening session is running."
        case .audioFileUnreadable(let reason):
            return "The audio file could not be read: \(reason)"
        }
    }
}
