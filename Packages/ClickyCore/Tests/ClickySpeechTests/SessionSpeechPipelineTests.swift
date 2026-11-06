import Foundation
import Testing
@testable import ClickySpeech

/// Collects what the pipeline reports, safely across threads.
final class PipelineRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var utterances: [(text: String, start: Date, end: Date)] = []
    private var levelCount = 0

    func recordUtterance(_ text: String, _ start: Date, _ end: Date) {
        lock.withLock { utterances.append((text, start, end)) }
    }
    func recordLevel() { lock.withLock { levelCount += 1 } }
    var recordedUtterances: [(text: String, start: Date, end: Date)] { lock.withLock { utterances } }
    var recordedLevelCount: Int { lock.withLock { levelCount } }
}

/// A stand-in microphone the test pushes samples into by hand.
private final class HandFedSampleSource: AudioSampleSource, @unchecked Sendable {
    private let lock = NSLock()
    private var deliver: (@Sendable ([Float]) -> Void)?
    private(set) var stopCallCount = 0

    func start(
        onSamples: @escaping @Sendable ([Float]) -> Void, onFinished: @escaping @Sendable () -> Void
    ) async throws {
        lock.withLock { deliver = onSamples }
    }
    func stop() async { lock.withLock { stopCallCount += 1 } }
    func push(_ samples: [Float]) { lock.withLock { deliver }?(samples) }
}

@Suite struct SessionSpeechPipelineTests {
    private static let sessionStart = Date(timeIntervalSince1970: 1_800_000_000)
    private static let clipText = "where do I click to save this file"

    /// 6 s of quiet with the spoken clip starting at 2.0 s.
    private func sixSecondsWithClip() throws -> [Float] {
        let clip = try SpeechTestSupport.spokenSamples(Self.clipText)
        return SpeechTestSupport.clipPlaced(clip, atSeconds: 2.0, totalSeconds: 6.0)
    }

    private func makePipeline(source: AudioSampleSource, recorder: PipelineRecorder) async throws -> SessionSpeechPipeline {
        let parakeet = try await SpeechTestSupport.sharedParakeet.value
        let pipeline = SessionSpeechPipeline(
            transcriber: parakeet, source: source, now: { Self.sessionStart })
        await pipeline.setHandlers(
            onUtterance: { text, start, end in recorder.recordUtterance(text, start, end) },
            onAudioLevel: { _ in recorder.recordLevel() })
        return pipeline
    }

    @Test func spokenClipFiresOneUtteranceWithItsText() async throws {
        let recorder = PipelineRecorder()
        let pipeline = try await makePipeline(
            source: AudioFileSampleSource(samples: try sixSecondsWithClip()), recorder: recorder)
        try await pipeline.start()
        await pipeline.waitForSourceToFinish()

        #expect(recorder.recordedUtterances.count == 1)
        let utterance = try #require(recorder.recordedUtterances.first)
        #expect(utterance.text.lowercased().contains("save"))
        #expect(utterance.text.lowercased().contains("file"))
        // The clip starts at 2.0 s into the session.
        #expect(abs(utterance.start.timeIntervalSince(Self.sessionStart) - 2.0) < 0.5)
        #expect(recorder.recordedLevelCount > 0)
        await pipeline.stop()
    }

    @Test func questionSpanIsTranscribedAndNotReportedAsAnUtterance() async throws {
        let recorder = PipelineRecorder()
        let pipeline = try await makePipeline(
            source: AudioFileSampleSource(samples: try sixSecondsWithClip()), recorder: recorder)
        // The question key goes down at 1.8 s; set before the quick-playing file runs past it.
        await pipeline.markQuestionStarted(at: Self.sessionStart.addingTimeInterval(1.8))
        try await pipeline.start()
        await pipeline.waitForSourceToFinish()

        let questionText = try await pipeline.transcribeQuestion(
            speechFrom: Self.sessionStart.addingTimeInterval(1.8),
            speechTo: Self.sessionStart.addingTimeInterval(5.5))
        #expect(questionText.lowercased().contains("save"))
        #expect(recorder.recordedUtterances.isEmpty)
        await pipeline.stop()
    }

    @Test func nothingIsDeliveredAfterStopReturns() async throws {
        let recorder = PipelineRecorder()
        let handFed = HandFedSampleSource()
        let pipeline = try await makePipeline(source: handFed, recorder: recorder)
        let samples = try sixSecondsWithClip()
        try await pipeline.start()

        // Feed the first 3.0 s (the clip has started), stop mid-speech, then feed the rest.
        let splitIndex = 3 * 16_000
        handFed.push(Array(samples[0..<splitIndex]))
        try await Task.sleep(nanoseconds: 300_000_000)
        await pipeline.stop()
        #expect(handFed.stopCallCount >= 1)

        // Stop closes the speech that was open, so the words heard so far are reported before it returns.
        let utterancesAtStop = recorder.recordedUtterances.count
        let levelsAtStop = recorder.recordedLevelCount
        #expect(utterancesAtStop == 1)
        #expect(levelsAtStop > 0)
        #expect(await pipeline.sessionStartDate == nil)

        handFed.push(Array(samples[splitIndex...]))
        try await Task.sleep(nanoseconds: 1_500_000_000)
        #expect(recorder.recordedLevelCount == levelsAtStop)
        #expect(recorder.recordedUtterances.count == utterancesAtStop)
        await #expect(throws: SpeechError.noSessionRunning) {
            _ = try await pipeline.transcribeQuestion(
                speechFrom: Self.sessionStart, speechTo: Self.sessionStart.addingTimeInterval(1))
        }
    }

    @Test func questionTextIsExactlyWhatWasSpoken() async throws {
        let recorder = PipelineRecorder()
        let pipeline = try await makePipeline(
            source: AudioFileSampleSource(samples: try sixSecondsWithClip()), recorder: recorder)
        await pipeline.markQuestionStarted(at: Self.sessionStart.addingTimeInterval(1.8))
        try await pipeline.start()
        await pipeline.waitForSourceToFinish()

        let questionText = try await pipeline.transcribeQuestion(
            speechFrom: Self.sessionStart.addingTimeInterval(1.8),
            speechTo: Self.sessionStart.addingTimeInterval(5.5))
        #expect(SpeechTestSupport.words(of: questionText) == Self.clipText.lowercased())
        await pipeline.stop()
    }
}
