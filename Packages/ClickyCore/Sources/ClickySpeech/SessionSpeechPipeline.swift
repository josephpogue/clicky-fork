import Foundation

/// Listens while a session runs: keeps the last 10 minutes of audio, cuts it into utterances,
/// transcribes each one on the Mac and reports it. A question's speech is transcribed on request
/// from the same audio and is not also reported as an utterance.
///
/// All state is isolated to this actor. Samples reach it in order through a stream, and the
/// (slow) transcription runs on its own task so audio never waits for the speech engine.
public actor SessionSpeechPipeline {
    private static let sampleRate = 16_000.0
    private static let frameSampleCount = 480 // 30 ms
    private static let ringSeconds = 600.0
    /// Context added around an utterance, so the engine does not hear a word cut off.
    private static let utterancePaddingSeconds = 0.2
    private static let questionPaddingBeforeSeconds = 0.3
    private static let questionPaddingAfterSeconds = 0.5
    /// How long `stop()` waits for the speech engine to finish what was heard.
    private static let stopDrainSeconds = 5.0
    /// A part of an utterance shorter than this is not worth a line of its own.
    private static let minimumReportedSeconds = 0.3

    /// Called with the text of each finished utterance and when it started and ended.
    public var onUtterance: (@Sendable (String, Date, Date) -> Void)?
    /// Called about every 30 ms with the input level, 0...1, for a level meter.
    public var onAudioLevel: (@Sendable (Double) -> Void)?
    /// Called when the engine fails on one utterance. The utterance is skipped.
    public var onTranscriptionFailure: (@Sendable (Error) -> Void)?

    /// Wall-clock time of sample 0 of the running session, taken from when the audio arrived (not
    /// from when `start()` was called); nil until the first audio arrives.
    public var sessionStartDate: Date? { timeline.sampleZeroDate }

    private let transcriber: SpeechTranscriber
    private let source: AudioSampleSource
    private let now: @Sendable () -> Date

    private var isRunning = false
    private var isStopping = false
    private var sourceHasFinished = false
    private var transcriptionHasEnded = false
    private var timeline = SampleTimeline()
    private var ring = RecentSampleRing(capacity: Int(SessionSpeechPipeline.ringSeconds * SessionSpeechPipeline.sampleRate))
    private var segmenter = EnergyUtteranceSegmenter()
    private var unframedSamples: [Float] = []
    private var nextFrameStartIndex = 0

    /// Samples as the source delivered them, with the moment each chunk arrived.
    private struct TimedChunk: Sendable {
        let samples: [Float]
        let arrivedAt: Date
    }

    private var sampleStreamContinuation: AsyncStream<TimedChunk>.Continuation?
    private var utteranceStreamContinuation: AsyncStream<UtteranceSegment>.Continuation?
    private var ingestTask: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []

    private var openQuestionStart: Date?
    private var finishedQuestionSpans: [(from: Date, to: Date)] = []

    /// `now` is the clock that stamps each chunk of audio as it arrives; tests pass a fake one.
    public init(
        transcriber: SpeechTranscriber,
        source: AudioSampleSource,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transcriber = transcriber
        self.source = source
        self.now = now
    }

    public func setHandlers(
        onUtterance: (@Sendable (String, Date, Date) -> Void)?,
        onAudioLevel: (@Sendable (Double) -> Void)?
    ) {
        self.onUtterance = onUtterance
        self.onAudioLevel = onAudioLevel
    }

    // MARK: Session lifetime

    /// Starts listening. Throws if the source cannot start (for example the microphone is denied).
    public func start() async throws {
        if isStopping { await waitForStopToFinish() }
        guard !isRunning else { return }
        resetForNewSession()
        isRunning = true

        let (sampleStream, sampleContinuation) = AsyncStream.makeStream(of: TimedChunk.self)
        let (utteranceStream, utteranceContinuation) = AsyncStream.makeStream(of: UtteranceSegment.self)
        sampleStreamContinuation = sampleContinuation
        utteranceStreamContinuation = utteranceContinuation

        ingestTask = Task { [weak self] in
            for await chunk in sampleStream {
                await self?.ingest(chunk)
            }
            await self?.sampleStreamEnded()
        }
        transcriptionTask = Task { [weak self] in
            for await segment in utteranceStream {
                await self?.transcribeAndReport(segment)
            }
            await self?.transcriptionStreamEnded()
        }

        // Each chunk is stamped the moment the source hands it over, so the timeline follows the
        // audio and not the permission prompt that `source.start` may wait on.
        let clock = now
        do {
            try await source.start(
                onSamples: { samples in
                    sampleContinuation.yield(TimedChunk(samples: samples, arrivedAt: clock()))
                },
                onFinished: { sampleContinuation.finish() })
        } catch {
            await stop()
            throw error
        }
    }

    /// Stops the session. The microphone is released first, the speech still open is closed, and
    /// the utterances already heard are transcribed and reported (waiting up to 5 s for the speech
    /// engine, then giving up on what is left). No callback fires after this returns.
    public func stop() async {
        if isStopping {
            await waitForStopToFinish()
            return
        }
        guard isRunning else {
            await source.stop()
            return
        }
        isStopping = true
        await source.stop()
        // No more audio can arrive. Let the audio already delivered flow through the segmenter, which
        // closes any open speech, and wait for the transcriptions of what was heard.
        sampleStreamContinuation?.finish()
        await ingestTask?.value
        await waitForTranscriptionToDrain()

        // From here the work is synchronous: no callback can slip in between these lines.
        isRunning = false
        isStopping = false
        sampleStreamContinuation = nil
        utteranceStreamContinuation = nil
        ingestTask?.cancel()
        transcriptionTask?.cancel()
        ingestTask = nil
        transcriptionTask = nil
        // The audio is not kept once the session ends.
        ring = RecentSampleRing(capacity: ring.capacity)
        timeline = SampleTimeline()
        openQuestionStart = nil
        finishedQuestionSpans = []
        resumeFinishWaiters()
        let waitingForStop = stopWaiters
        stopWaiters = []
        for waiter in waitingForStop { waiter.resume() }
    }

    /// Returns once the source has run out of audio and every utterance is transcribed. A
    /// microphone never runs out, so this is for files; it also returns after `stop()`.
    public func waitForSourceToFinish() async {
        guard isRunning else { return }
        await withCheckedContinuation { continuation in
            finishWaiters.append(continuation)
        }
    }

    private func waitForStopToFinish() async {
        await withCheckedContinuation { continuation in
            stopWaiters.append(continuation)
        }
    }

    /// Waits for the transcription task to run out of utterances, at most `stopDrainSeconds`.
    private func waitForTranscriptionToDrain() async {
        guard !transcriptionHasEnded else { return }
        let deadline = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.stopDrainSeconds * 1_000_000_000))
            if !Task.isCancelled { await self?.resumeFinishWaiters() }
        }
        await withCheckedContinuation { continuation in
            finishWaiters.append(continuation)
        }
        deadline.cancel()
    }

    // MARK: Questions

    /// The question key went down at `date`. Speech from then on belongs to the question.
    public func markQuestionStarted(at date: Date) {
        openQuestionStart = date
    }

    /// The question the user was speaking is dropped, never sent (the question key died): its speech stays claimed by
    /// that question, so it is not reported as an utterance either, but speech after `date` is reported as usual.
    public func abandonOpenQuestion(at date: Date) {
        guard let start = openQuestionStart else { return }
        finishedQuestionSpans.append((from: start, to: date))
        openQuestionStart = nil
    }

    /// Transcribes what was said from `speechFrom` to `speechTo` (padded 0.3 s before and 0.5 s
    /// after) and closes the question, so that speech is not also reported as an utterance.
    public func transcribeQuestion(speechFrom: Date, speechTo: Date) async throws -> String {
        guard isRunning else { throw SpeechError.noSessionRunning }
        finishedQuestionSpans.append((from: speechFrom, to: speechTo))
        openQuestionStart = nil

        // The key press just happened, so the trailing 0.5 s may not have been heard yet. If no audio
        // has arrived at all, the position of the question on the timeline is not known yet either.
        var waitedSeconds = 0.0
        while isRunning, !sourceHasFinished, waitedSeconds < 0.7, !questionAudioHasArrived(speechFrom: speechFrom, speechTo: speechTo) {
            try await Task.sleep(nanoseconds: 50_000_000)
            waitedSeconds += 0.05
        }
        guard isRunning else { throw SpeechError.noSessionRunning }

        guard let range = questionSampleRange(speechFrom: speechFrom, speechTo: speechTo) else { return "" }
        let questionSamples = ring.slice(from: range.lowerBound, to: range.upperBound)
        guard !questionSamples.isEmpty else { return "" }
        let text = try await transcriber.transcribe(samples: questionSamples, sampleRate: Self.sampleRate)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The samples a question covers, with its padding; nil before any audio has arrived.
    private func questionSampleRange(speechFrom: Date, speechTo: Date) -> Range<Int>? {
        guard let firstSpeechIndex = timeline.sampleIndex(for: speechFrom),
            let lastSpeechIndex = timeline.sampleIndex(for: speechTo)
        else { return nil }
        let firstIndex = firstSpeechIndex - Int(Self.questionPaddingBeforeSeconds * Self.sampleRate)
        let endIndex = lastSpeechIndex + Int(Self.questionPaddingAfterSeconds * Self.sampleRate)
        return firstIndex..<max(firstIndex, endIndex)
    }

    private func questionAudioHasArrived(speechFrom: Date, speechTo: Date) -> Bool {
        guard let range = questionSampleRange(speechFrom: speechFrom, speechTo: speechTo) else { return false }
        return ring.endIndex >= range.upperBound
    }

    // MARK: Audio in

    private func resetForNewSession() {
        ring = RecentSampleRing(capacity: ring.capacity)
        timeline = SampleTimeline()
        segmenter = EnergyUtteranceSegmenter()
        unframedSamples = []
        nextFrameStartIndex = 0
        sourceHasFinished = false
        transcriptionHasEnded = false
        // A question may be marked just before start(), so question state is cleared in stop() instead.
    }

    private func ingest(_ chunk: TimedChunk) {
        guard isRunning else { return }
        let cameAfterGap = timeline.recordChunk(
            chunkSampleCount: chunk.samples.count, arrivedAt: chunk.arrivedAt)
        if cameAfterGap {
            // Speech cannot continue across a stretch in which nothing was heard.
            for segment in segmenter.flush() {
                utteranceStreamContinuation?.yield(segment)
            }
        }
        ring.append(chunk.samples)
        unframedSamples.append(contentsOf: chunk.samples)

        while unframedSamples.count >= Self.frameSampleCount {
            let frame = Array(unframedSamples.prefix(Self.frameSampleCount))
            unframedSamples.removeFirst(Self.frameSampleCount)
            let frameStartSeconds = Double(nextFrameStartIndex) / Self.sampleRate
            nextFrameStartIndex += Self.frameSampleCount

            onAudioLevel?(Self.meterLevel(for: frame))
            for segment in segmenter.append(samples: frame, startTime: frameStartSeconds) {
                utteranceStreamContinuation?.yield(segment)
            }
        }
    }

    /// The audio is over: close any speech still open and let the transcription task drain.
    private func sampleStreamEnded() {
        guard isRunning else { return }
        sourceHasFinished = true
        for segment in segmenter.flush() {
            utteranceStreamContinuation?.yield(segment)
        }
        utteranceStreamContinuation?.finish()
    }

    private func transcriptionStreamEnded() {
        guard isRunning else { return }
        transcriptionHasEnded = true
        resumeFinishWaiters()
    }

    private func resumeFinishWaiters() {
        let waiters = finishWaiters
        finishWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    // MARK: Utterances out

    /// Reports the parts of an utterance that no question claims. A question claims its speech with
    /// its padding; what was said before the question key, or after the question's end, is a spoken
    /// line of its own.
    private func transcribeAndReport(_ segment: UtteranceSegment) async {
        guard isRunning else { return }
        let utteranceRange = Int((segment.start * Self.sampleRate).rounded())..<Int((segment.end * Self.sampleRate).rounded())
        let claims = questionClaimedRanges()
        for piece in Self.partsOutside(claims, of: utteranceRange) {
            guard piece.count >= Int(Self.minimumReportedSeconds * Self.sampleRate) else { continue }
            await transcribeAndReportPiece(piece, avoiding: claims)
            guard isRunning else { return }
        }
    }

    private func transcribeAndReportPiece(_ piece: Range<Int>, avoiding claims: [Range<Int>]) async {
        // Context around the words, but never reaching into a neighbouring question's audio.
        let padding = Int(Self.utterancePaddingSeconds * Self.sampleRate)
        var paddedLower = piece.lowerBound - padding
        var paddedUpper = piece.upperBound + padding
        for claim in claims {
            if claim.upperBound <= piece.lowerBound { paddedLower = max(paddedLower, claim.upperBound) }
            if claim.lowerBound >= piece.upperBound { paddedUpper = min(paddedUpper, claim.lowerBound) }
        }
        let pieceSamples = ring.slice(from: paddedLower, to: paddedUpper)
        guard !pieceSamples.isEmpty else { return }

        do {
            let text = try await transcriber.transcribe(samples: pieceSamples, sampleRate: Self.sampleRate)
            // The session may have stopped, or the question key may have gone down, while the engine worked.
            guard isRunning else { return }
            let claimsNow = questionClaimedRanges()
            if claimsNow.contains(where: { $0.lowerBound < piece.upperBound && $0.upperBound > piece.lowerBound }) { return }
            let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedText.isEmpty,
                let pieceStart = timeline.date(forSampleIndex: piece.lowerBound),
                let pieceEnd = timeline.date(forSampleIndex: piece.upperBound)
            else { return }
            onUtterance?(trimmedText, pieceStart, pieceEnd)
        } catch {
            guard isRunning else { return }
            onTranscriptionFailure?(error)
        }
    }

    /// The sample ranges that belong to questions: each finished question with its padding, and
    /// everything from the padded start of the open question onward.
    private func questionClaimedRanges() -> [Range<Int>] {
        var claimedRanges: [Range<Int>] = []
        for span in finishedQuestionSpans {
            guard let range = questionSampleRange(speechFrom: span.from, speechTo: span.to) else { continue }
            claimedRanges.append(range)
        }
        if let openStart = openQuestionStart, let openStartIndex = timeline.sampleIndex(for: openStart) {
            let paddedStart = openStartIndex - Int(Self.questionPaddingBeforeSeconds * Self.sampleRate)
            claimedRanges.append(paddedStart..<Int.max)
        }
        return claimedRanges
    }

    /// `range` with every claimed range cut out, as the (possibly several, possibly no) parts left.
    static func partsOutside(_ claimedRanges: [Range<Int>], of range: Range<Int>) -> [Range<Int>] {
        var remainingParts = [range]
        for claim in claimedRanges {
            var partsAfterThisClaim: [Range<Int>] = []
            for part in remainingParts {
                guard claim.lowerBound < part.upperBound, claim.upperBound > part.lowerBound else {
                    partsAfterThisClaim.append(part)
                    continue
                }
                if part.lowerBound < claim.lowerBound {
                    partsAfterThisClaim.append(part.lowerBound..<claim.lowerBound)
                }
                if claim.upperBound < part.upperBound {
                    partsAfterThisClaim.append(claim.upperBound..<part.upperBound)
                }
            }
            remainingParts = partsAfterThisClaim
        }
        return remainingParts
    }

    // MARK: Helpers

    /// Maps loudness to 0...1: -60 dB reads 0 and -10 dB reads 1.
    static func meterLevel(for frame: [Float]) -> Double {
        let rms = Double(EnergyUtteranceSegmenter.rootMeanSquare(of: frame))
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        return min(1, max(0, (decibels + 60) / 50))
    }
}
