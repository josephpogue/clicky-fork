import Foundation

public enum SpeechEngineFactory {
    /// Parakeet when it loads (from the local cache, or one download on a Mac that lacks it);
    /// otherwise Apple's on-device recognizer.
    public static func makePreferredTranscriber() async -> SpeechTranscriber {
        do {
            return try await ParakeetSpeechTranscriber.load()
        } catch {
            return AppleSpeechTranscriber()
        }
    }
}
