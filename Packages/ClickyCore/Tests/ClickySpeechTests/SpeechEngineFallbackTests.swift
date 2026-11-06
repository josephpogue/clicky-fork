import Foundation
import Testing
@testable import ClickySpeech

@Suite struct SpeechEngineFallbackTests {
    /// Never answers, and ignores cancellation, like a network layer that keeps retrying.
    private func neverAnswers<Value>() async -> Value {
        await withCheckedContinuation { (_: CheckedContinuation<Value, Never>) in }
    }

    @Test func aStalledDownloadIsGivenUpAtTheDeadlineEvenIfItIgnoresCancellation() async throws {
        let started = Date()
        await #expect(throws: SpeechError.speechModelDownloadTimedOut(seconds: 0.3)) {
            _ = try await ParakeetSpeechTranscriber.load(
                loadFromCache: { throw SpeechError.speechRecognizerUnavailable },
                download: { await neverAnswers() },
                downloadTimeoutSeconds: 0.3)
        }
        let waited = Date().timeIntervalSince(started)
        // 0.3 s deadline: it answers soon after, not at the end of the download's own retries.
        #expect(waited >= 0.3)
        #expect(waited < 2.0)
    }

    @Test func aFailedDownloadReportsItsOwnError() async throws {
        await #expect(throws: SpeechError.microphoneUnavailable("offline")) {
            _ = try await ParakeetSpeechTranscriber.load(
                loadFromCache: { throw SpeechError.speechRecognizerUnavailable },
                download: { throw SpeechError.microphoneUnavailable("offline") },
                downloadTimeoutSeconds: 5)
        }
    }

    @Test func aModelThatCannotLoadFallsBackToApplesRecognizerAndSaysSo() async throws {
        let started = Date()
        let transcriber = await SpeechEngineFactory.makeTranscriber(loadParakeet: {
            try await ParakeetSpeechTranscriber.load(
                loadFromCache: { throw SpeechError.speechRecognizerUnavailable },
                download: { await neverAnswers() },
                downloadTimeoutSeconds: 0.3)
        })
        #expect(transcriber.engineName == AppleSpeechTranscriber.engineDisplayName)
        #expect(transcriber is AppleSpeechTranscriber)
        #expect(Date().timeIntervalSince(started) < 2.0)
    }

    @Test func aModelThatLoadsIsTheEngineTheAppGets() async throws {
        let parakeet = try await SpeechTestSupport.sharedParakeet.value
        let transcriber = await SpeechEngineFactory.makeTranscriber(loadParakeet: { parakeet })
        #expect(transcriber.engineName == ParakeetSpeechTranscriber.engineDisplayName)
    }

    @Test func theDownloadIsBoundedAtFiveMinutes() {
        #expect(ParakeetSpeechTranscriber.downloadTimeoutSeconds == 300)
    }
}
