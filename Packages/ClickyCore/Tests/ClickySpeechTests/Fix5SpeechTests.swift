import Foundation
import Testing
@testable import ClickySpeech

/// Wave 5: an abandon left over from one session never reaches the next session's first question.
struct Fix5SpeechTests {
    private static let start = Date(timeIntervalSince1970: 1_800_000_000)

    private struct NoTranscriber: SpeechTranscriber {
        let engineName = "none"
        func transcribe(samples: [Float], sampleRate: Double) async throws -> String { "" }
    }

    private struct NoSource: AudioSampleSource {
        func start(onSamples: @escaping @Sendable ([Float]) -> Void, onFinished: @escaping @Sendable () -> Void) async throws {}
        func stop() async {}
    }

    @Test func startClearsAPendingAbandon() async throws {
        let pipeline = SessionSpeechPipeline(transcriber: NoTranscriber(), source: NoSource(), now: { Self.start })
        await pipeline.abandonOpenQuestion(at: Self.start.addingTimeInterval(3))
        try await pipeline.start()
        await pipeline.markQuestionStarted(at: Self.start.addingTimeInterval(1))
        #expect(await pipeline.openQuestionIsClaiming)
        #expect(await pipeline.droppedSpanCount == 0)
        await pipeline.stop()
    }
}
