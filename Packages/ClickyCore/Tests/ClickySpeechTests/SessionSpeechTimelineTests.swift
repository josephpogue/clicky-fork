import Foundation
import Testing
@testable import ClickySpeech

/// The pipeline's clock-to-sample mapping and how it splits utterances around questions, played
/// with a hand-moved clock so a microphone prompt, a sleep and a question key can be timed exactly.
@Suite struct SessionSpeechTimelineTests {
    private static let sessionStart = Date(timeIntervalSince1970: 1_800_000_000)
    private static let settingsPhrase = "open the settings menu"
    private static let savePhrase = "where do i click to save this file"
    private static let buttonPhrase = "what does this button do"

    private func makePipeline(clock: ManualClock, source: ClockedSampleSource, recorder: PipelineRecorder) async throws
        -> SessionSpeechPipeline
    {
        let parakeet = try await SpeechTestSupport.sharedParakeet.value
        let pipeline = SessionSpeechPipeline(transcriber: parakeet, source: source, now: { clock.current })
        await pipeline.setHandlers(
            onUtterance: { text, start, end in recorder.recordUtterance(text, start, end) },
            onAudioLevel: { _ in recorder.recordLevel() })
        return pipeline
    }

    private func seconds(_ date: Date, after origin: Date) -> Double { date.timeIntervalSince(origin) }

    // MARK: Finding 1: the timeline follows the audio

    @Test func audioThatStartsFourSecondsAfterStartIsStillFoundAtItsRealTime() async throws {
        let clock = ManualClock(Self.sessionStart)
        let source = ClockedSampleSource(clock: clock)
        let recorder = PipelineRecorder()
        let pipeline = try await makePipeline(clock: clock, source: source, recorder: recorder)
        try await pipeline.start()

        // The microphone prompt held the first sample back for 4 s: audio begins at start + 4 s.
        let audioStart = Self.sessionStart.addingTimeInterval(4)
        let settingsClip = try SpeechTestSupport.spokenSamples(Self.settingsPhrase)
        let saveClip = try SpeechTestSupport.spokenSamples(Self.savePhrase)
        // In the audio: settings clip at 0.5 s, save clip at 3.0 s, quiet after.
        let audio = SpeechTestSupport.silence(seconds: 0.5) + settingsClip
        let paddedAudio = audio + SpeechTestSupport.silence(seconds: 3.0 - Double(audio.count) / 16_000) + saveClip
            + SpeechTestSupport.silence(seconds: 1.5)
        // The question was spoken at wall time start + 7.0 s (audio 3.0 s) for as long as the clip lasts;
        // the question key goes down just before it.
        let questionFrom = Self.sessionStart.addingTimeInterval(7.0)
        let questionTo = questionFrom.addingTimeInterval(Double(saveClip.count) / 16_000)
        let beforeQuestion = 3 * 16_000
        source.play(Array(paddedAudio[0..<beforeQuestion]), startingAt: audioStart)
        await pipeline.markQuestionStarted(at: questionFrom)
        source.play(Array(paddedAudio[beforeQuestion...]), startingAt: audioStart.addingTimeInterval(3.0))
        let questionText = try await pipeline.transcribeQuestion(speechFrom: questionFrom, speechTo: questionTo)
        #expect(SpeechTestSupport.words(of: questionText) == Self.savePhrase)

        await pipeline.stop()
        // The earlier clip is a spoken line, stamped at the moment it was said (start + 4.5 s), not 4 s early.
        let lines = recorder.recordedUtterances
        #expect(lines.count == 1)
        let line = try #require(lines.first)
        #expect(SpeechTestSupport.words(of: line.text) == Self.settingsPhrase)
        #expect(abs(seconds(line.start, after: Self.sessionStart) - 4.5) < 0.3)
    }

    @Test func aTenSecondGapInTheAudioDoesNotShiftLaterTimes() async throws {
        let clock = ManualClock(Self.sessionStart)
        let source = ClockedSampleSource(clock: clock)
        let recorder = PipelineRecorder()
        let pipeline = try await makePipeline(clock: clock, source: source, recorder: recorder)
        try await pipeline.start()

        let settingsClip = try SpeechTestSupport.spokenSamples(Self.settingsPhrase)
        let saveClip = try SpeechTestSupport.spokenSamples(Self.savePhrase)
        let buttonClip = try SpeechTestSupport.spokenSamples(Self.buttonPhrase)

        // First 4 s from the start: the settings clip at 0.5 s.
        let beforeSleep = SpeechTestSupport.clipPlaced(settingsClip, atSeconds: 0.5, totalSeconds: 4.0)
        source.play(beforeSleep, startingAt: Self.sessionStart)

        // The Mac sleeps for 10 s. Audio resumes at start + 14 s: the save clip 1.0 s in (start + 15 s),
        // the button clip 4.0 s in (start + 18 s).
        let afterWake = SpeechTestSupport.clipPlaced(saveClip, atSeconds: 1.0, totalSeconds: 4.0)
            + buttonClip + SpeechTestSupport.silence(seconds: 1.5)
        let wakeStart = Self.sessionStart.addingTimeInterval(14)
        let questionFrom = Self.sessionStart.addingTimeInterval(15.0)
        let questionTo = questionFrom.addingTimeInterval(Double(saveClip.count) / 16_000)
        let handedOver = Int((1.0 + Double(saveClip.count) / 16_000 + 0.5) * 16_000)
        source.play(Array(afterWake[0..<16_000]), startingAt: wakeStart)
        await pipeline.markQuestionStarted(at: questionFrom)
        source.play(Array(afterWake[16_000..<handedOver]), startingAt: wakeStart.addingTimeInterval(1.0))
        let questionText = try await pipeline.transcribeQuestion(speechFrom: questionFrom, speechTo: questionTo)
        source.play(Array(afterWake[handedOver...]), startingAt: wakeStart.addingTimeInterval(Double(handedOver) / 16_000))
        #expect(SpeechTestSupport.words(of: questionText) == Self.savePhrase)

        await pipeline.stop()
        let lines = recorder.recordedUtterances
        #expect(lines.count == 2)
        guard lines.count == 2 else { return }
        #expect(SpeechTestSupport.words(of: lines[0].text) == Self.settingsPhrase)
        #expect(abs(seconds(lines[0].start, after: Self.sessionStart) - 0.5) < 0.3)
        #expect(SpeechTestSupport.words(of: lines[1].text) == Self.buttonPhrase)
        #expect(abs(seconds(lines[1].start, after: Self.sessionStart) - 18.0) < 0.3)
    }

    // MARK: Finding 3: an utterance that overlaps a question

    /// settings, 0.5 s, save, 0.5 s, button: one unbroken utterance (the pauses are shorter than the
    /// segmenter's 0.6 s hangover), with the clip start times in seconds.
    private struct ThreePhraseAudio {
        let samples: [Float]
        let settingsStart: Double, saveStart: Double, buttonStart: Double
        let settingsEnd: Double, saveEnd: Double, buttonEnd: Double
    }

    private func threePhraseAudio() throws -> ThreePhraseAudio {
        let settingsClip = try SpeechTestSupport.spokenSamples(Self.settingsPhrase)
        let saveClip = try SpeechTestSupport.spokenSamples(Self.savePhrase)
        let buttonClip = try SpeechTestSupport.spokenSamples(Self.buttonPhrase)
        let pause = SpeechTestSupport.silence(seconds: 0.5)
        let lead = SpeechTestSupport.silence(seconds: 1.0)
        let samples = lead + settingsClip + pause + saveClip + pause + buttonClip + SpeechTestSupport.silence(seconds: 1.5)
        func length(_ clip: [Float]) -> Double { Double(clip.count) / 16_000 }
        let settingsStart = 1.0
        let saveStart = settingsStart + length(settingsClip) + 0.5
        let buttonStart = saveStart + length(saveClip) + 0.5
        return ThreePhraseAudio(
            samples: samples,
            settingsStart: settingsStart, saveStart: saveStart, buttonStart: buttonStart,
            settingsEnd: settingsStart + length(settingsClip), saveEnd: saveStart + length(saveClip),
            buttonEnd: buttonStart + length(buttonClip))
    }

    /// Plays the audio up to the end of the question's trailing padding, asks the question, plays
    /// the rest, and returns what the question said and what was logged as spoken lines.
    private func askQuestion(
        over audio: ThreePhraseAudio, from questionFrom: Double, to questionTo: Double
    ) async throws -> (questionText: String, lines: [String]) {
        let clock = ManualClock(Self.sessionStart)
        let source = ClockedSampleSource(clock: clock)
        let recorder = PipelineRecorder()
        let pipeline = try await makePipeline(clock: clock, source: source, recorder: recorder)
        try await pipeline.start()

        let handedOver = Int((questionTo + 0.5) * 16_000)
        source.play(Array(audio.samples[0..<handedOver]), startingAt: Self.sessionStart)
        await pipeline.markQuestionStarted(at: Self.sessionStart.addingTimeInterval(questionFrom))
        let questionText = try await pipeline.transcribeQuestion(
            speechFrom: Self.sessionStart.addingTimeInterval(questionFrom),
            speechTo: Self.sessionStart.addingTimeInterval(questionTo))
        source.play(
            Array(audio.samples[handedOver...]),
            startingAt: Self.sessionStart.addingTimeInterval(Double(handedOver) / 16_000))
        await pipeline.stop()
        return (questionText, recorder.recordedUtterances.map { SpeechTestSupport.words(of: $0.text) })
    }

    @Test func theAudioIsOneUtteranceToTheSegmenter() throws {
        let audio = try threePhraseAudio()
        var segmenter = EnergyUtteranceSegmenter()
        var segments: [UtteranceSegment] = []
        var frameStart = 0
        while frameStart + 480 <= audio.samples.count {
            segments += segmenter.append(
                samples: Array(audio.samples[frameStart..<(frameStart + 480)]), startTime: Double(frameStart) / 16_000)
            frameStart += 480
        }
        segments += segmenter.flush()
        #expect(segments.count == 1)
    }

    @Test func speechBeforeAndAfterAQuestionInsideOneUtteranceIsLogged() async throws {
        let audio = try threePhraseAudio()
        let result = try await askQuestion(over: audio, from: audio.saveStart, to: audio.saveEnd)
        #expect(SpeechTestSupport.words(of: result.questionText) == Self.savePhrase)
        #expect(result.lines == [Self.settingsPhrase, Self.buttonPhrase])
    }

    @Test func anUtteranceThatStartsBeforeAndEndsInsideTheQuestionLogsTheBeforePart() async throws {
        let audio = try threePhraseAudio()
        let result = try await askQuestion(over: audio, from: audio.saveStart, to: audio.buttonEnd)
        #expect(SpeechTestSupport.words(of: result.questionText) == "\(Self.savePhrase) \(Self.buttonPhrase)")
        #expect(result.lines == [Self.settingsPhrase])
    }

    @Test func anUtteranceThatStartsInsideTheQuestionAndEndsAfterItLogsTheAfterPart() async throws {
        let audio = try threePhraseAudio()
        let result = try await askQuestion(over: audio, from: audio.settingsStart, to: audio.saveEnd)
        #expect(SpeechTestSupport.words(of: result.questionText) == "\(Self.settingsPhrase) \(Self.savePhrase)")
        #expect(result.lines == [Self.buttonPhrase])
    }

    @Test func aQuestionThatSpansTheWholeUtteranceLeavesNothingToLog() async throws {
        let audio = try threePhraseAudio()
        let result = try await askQuestion(over: audio, from: audio.settingsStart, to: audio.buttonEnd)
        #expect(
            SpeechTestSupport.words(of: result.questionText)
                == "\(Self.settingsPhrase) \(Self.savePhrase) \(Self.buttonPhrase)")
        #expect(result.lines.isEmpty)
    }

    // MARK: The cut itself

    @Test func partsOutsideCutsClaimedRangesOutOfAnUtterance() {
        let utterance = 1_000..<9_000
        // Nothing claimed: the whole utterance.
        #expect(SessionSpeechPipeline.partsOutside([], of: utterance) == [1_000..<9_000])
        // Claim starts inside, runs past the end: the part before.
        #expect(SessionSpeechPipeline.partsOutside([4_000..<20_000], of: utterance) == [1_000..<4_000])
        // Claim starts before, ends inside: the part after.
        #expect(SessionSpeechPipeline.partsOutside([0..<3_000], of: utterance) == [3_000..<9_000])
        // Claim in the middle: both sides.
        #expect(SessionSpeechPipeline.partsOutside([4_000..<5_000], of: utterance) == [1_000..<4_000, 5_000..<9_000])
        // Claim covers everything: nothing.
        #expect(SessionSpeechPipeline.partsOutside([0..<10_000], of: utterance).isEmpty)
        // Two questions back to back: what is left between them, and the ends.
        #expect(
            SessionSpeechPipeline.partsOutside([2_000..<3_000, 5_000..<6_000], of: utterance)
                == [1_000..<2_000, 3_000..<5_000, 6_000..<9_000])
        // A claim far away changes nothing.
        #expect(SessionSpeechPipeline.partsOutside([20_000..<30_000], of: utterance) == [1_000..<9_000])
    }
}
