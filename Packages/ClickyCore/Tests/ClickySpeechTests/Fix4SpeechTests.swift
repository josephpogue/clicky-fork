import Foundation
import Testing
@testable import ClickySpeech

/// Wave 4: a dropped question's span always wins, whatever order the press and the abandon land in.
struct Fix4SpeechTests {
    private static let start = Date(timeIntervalSince1970: 1_800_000_000)

    private struct NoTranscriber: SpeechTranscriber {
        let engineName = "none"
        func transcribe(samples: [Float], sampleRate: Double) async throws -> String { "" }
    }

    private struct NoSource: AudioSampleSource {
        func start(onSamples: @escaping @Sendable ([Float]) -> Void, onFinished: @escaping @Sendable () -> Void) async throws {}
        func stop() async {}
    }

    private func makePipeline() -> SessionSpeechPipeline {
        SessionSpeechPipeline(transcriber: NoTranscriber(), source: NoSource(), now: { Self.start })
    }

    @Test func abandonAfterTheMarkClosesTheSpan() async {
        let pipeline = makePipeline()
        await pipeline.markQuestionStarted(at: Self.start.addingTimeInterval(1))
        await pipeline.abandonOpenQuestion(at: Self.start.addingTimeInterval(3))
        #expect(await pipeline.openQuestionIsClaiming == false)
        #expect(await pipeline.droppedSpanCount == 1)
    }

    @Test func abandonBeforeTheMarkLandsStillWins() async {
        let pipeline = makePipeline()
        // The abandon ran while the mark was still in flight; the mark (stamped at the press) arrives after it.
        await pipeline.abandonOpenQuestion(at: Self.start.addingTimeInterval(3))
        await pipeline.markQuestionStarted(at: Self.start.addingTimeInterval(1))
        #expect(await pipeline.openQuestionIsClaiming == false)
        #expect(await pipeline.droppedSpanCount == 1)
    }

    @Test func aLaterQuestionAfterAnAbandonOpensNormally() async {
        let pipeline = makePipeline()
        await pipeline.abandonOpenQuestion(at: Self.start.addingTimeInterval(3))
        await pipeline.markQuestionStarted(at: Self.start.addingTimeInterval(10))
        #expect(await pipeline.openQuestionIsClaiming)
    }

    @Test func aPlainMarkOpensTheQuestion() async {
        let pipeline = makePipeline()
        await pipeline.markQuestionStarted(at: Self.start.addingTimeInterval(1))
        #expect(await pipeline.openQuestionIsClaiming)
    }
}
