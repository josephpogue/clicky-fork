import Foundation

public enum SpeechEngineFactory {
    /// Parakeet when it loads (from the local cache, or one download of at most
    /// `ParakeetSpeechTranscriber.downloadTimeoutSeconds` on a Mac that lacks it); otherwise
    /// Apple's on-device recognizer. The result's `engineName` says which one the app got:
    /// `ParakeetSpeechTranscriber.engineDisplayName` or `AppleSpeechTranscriber.engineDisplayName`.
    public static func makePreferredTranscriber() async -> SpeechTranscriber {
        await makeTranscriber(loadParakeet: { try await ParakeetSpeechTranscriber.load() })
    }

    static func makeTranscriber(
        loadParakeet: @Sendable () async throws -> SpeechTranscriber
    ) async -> SpeechTranscriber {
        do {
            return try await loadParakeet()
        } catch {
            return AppleSpeechTranscriber()
        }
    }
}
