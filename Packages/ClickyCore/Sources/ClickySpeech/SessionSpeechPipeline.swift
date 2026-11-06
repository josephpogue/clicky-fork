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

    /// Called with the text of each finished utterance and when it started and ended.
    public var onUtterance: (@Sendable (String, Date, Date) -> Void)?
    /// Called about every 30 ms with the input level, 0...1, for a level meter.
    public var onAudioLevel: (@Sendable (Double) -> Void)?
    /// Called when the engine fails on one utterance. The utterance is skipped.
    public var onTranscriptionFailure: (@Sendable (Error) -> Void)?

    /// Wall-clock time of sample 0 of the running session; nil before `start()`.
    public private(set) var sessionStartDate: Date?

    private let transcriber: SpeechTranscriber
    private let source: AudioSampleSource
    private let now: @Sendable () -> Date

    private var isRunning = false
    private var sourceHasFinished = false
    private var ring = RecentSampleRing(capacity: Int(SessionSpeechPipeline.ringSeconds * SessionSpeechPipeline.sampleRate))
    private var segmenter = EnergyUtteranceSegmenter()
    private var unframedSamples: [Float] = []
    private var nextFrameStartIndex = 0

    private var sampleStreamContinuation: AsyncStream<[Float]>.Continuation?
    private var utteranceStreamContinuation: AsyncStream<UtteranceSegment>.Continuation?
    private var ingestTask: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []

    private var openQuestionStart: Date?
    private var finishedQuestionSpans: [(from: Date, to: Date)] = []

    /// `now` is the clock that stamps sample 0 when the session starts; tests pass a fixed one.
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
        guard !isRunning else { return }
        resetForNewSession()
        isRunning = true
        sessionStartDate = now()

        let (sampleStream, sampleContinuation) = AsyncStream.makeStream(of: [Float].self)
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

        do {
            try await source.start(
                onSamples: { chunk in sampleContinuation.yield(chunk) },
                onFinished: { sampleContinuation.finish() })
        } catch {
            await stop()
            throw error
        }
    }

    /// Stops at once: the microphone is released first, pending work is dropped, and no callback
    /// fires after this returns.
    public func stop() async {
        let wasRunning = isRunning
        isRunning = false
        await source.stop()
        guard wasRunning || sessionStartDate != nil else { return }
        sampleStreamContinuation?.finish()
        utteranceStreamContinuation?.finish()
        ingestTask?.cancel()
        transcriptionTask?.cancel()
        sampleStreamContinuation = nil
        utteranceStreamContinuation = nil
        ingestTask = nil
        transcriptionTask = nil
        // The audio is not kept once the session ends.
        ring = RecentSampleRing(capacity: ring.capacity)
        sessionStartDate = nil
        openQuestionStart = nil
        finishedQuestionSpans = []
        resumeFinishWaiters()
    }

    /// Returns once the source has run out of audio and every utterance is transcribed. A
    /// microphone never runs out, so this is for files; it also returns after `stop()`.
    public func waitForSourceToFinish() async {
        guard isRunning else { return }
        await withCheckedContinuation { continuation in
            finishWaiters.append(continuation)
        }
    }

    // MARK: Questions

    /// The question key went down at `date`. Speech from then on belongs to the question.
    public func markQuestionStarted(at date: Date) {
        openQuestionStart = date
    }

    /// Transcribes what was said from `speechFrom` to `speechTo` (padded 0.3 s before and 0.5 s
    /// after) and closes the question, so that speech is not also reported as an utterance.
    public func transcribeQuestion(speechFrom: Date, speechTo: Date) async throws -> String {
        guard isRunning, let start = sessionStartDate else { throw SpeechError.noSessionRunning }
        finishedQuestionSpans.append((from: speechFrom, to: speechTo))
        openQuestionStart = nil

        let firstIndex = sampleIndex(for: speechFrom, sessionStart: start)
            - Int(Self.questionPaddingBeforeSeconds * Self.sampleRate)
        let endIndex = sampleIndex(for: speechTo, sessionStart: start)
            + Int(Self.questionPaddingAfterSeconds * Self.sampleRate)

        // The key press just happened, so the trailing 0.5 s may not have been heard yet.
        var waitedSeconds = 0.0
        while isRunning, !sourceHasFinished, ring.endIndex < endIndex, waitedSeconds < 0.7 {
            try await Task.sleep(nanoseconds: 50_000_000)
            waitedSeconds += 0.05
        }
        guard isRunning else { throw SpeechError.noSessionRunning }

        let questionSamples = ring.slice(from: firstIndex, to: endIndex)
        guard !questionSamples.isEmpty else { return "" }
        let text = try await transcriber.transcribe(samples: questionSamples, sampleRate: Self.sampleRate)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Audio in

    private func resetForNewSession() {
        ring = RecentSampleRing(capacity: ring.capacity)
        segmenter = EnergyUtteranceSegmenter()
        unframedSamples = []
        nextFrameStartIndex = 0
        sourceHasFinished = false
        // A question may be marked just before start(), so question state is cleared in stop() instead.
    }

    private func ingest(_ chunk: [Float]) {
        guard isRunning else { return }
        ring.append(chunk)
        unframedSamples.append(contentsOf: chunk)

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
        resumeFinishWaiters()
    }

    private func resumeFinishWaiters() {
        let waiters = finishWaiters
        finishWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    // MARK: Utterances out

    private func transcribeAndReport(_ segment: UtteranceSegment) async {
        guard isRunning, let start = sessionStartDate else { return }
        let utteranceStart = start.addingTimeInterval(segment.start)
        let utteranceEnd = start.addingTimeInterval(segment.end)
        if overlapsQuestion(from: utteranceStart, to: utteranceEnd) { return }

        let padding = Int(Self.utterancePaddingSeconds * Self.sampleRate)
        let utteranceSamples = ring.slice(
            from: Int(segment.start * Self.sampleRate) - padding,
            to: Int(segment.end * Self.sampleRate) + padding)
        guard !utteranceSamples.isEmpty else { return }

        do {
            let text = try await transcriber.transcribe(samples: utteranceSamples, sampleRate: Self.sampleRate)
            // The session may have stopped, or the question key may have gone down, while the engine worked.
            guard isRunning else { return }
            if overlapsQuestion(from: utteranceStart, to: utteranceEnd) { return }
            let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedText.isEmpty else { return }
            onUtterance?(trimmedText, utteranceStart, utteranceEnd)
        } catch {
            guard isRunning else { return }
            onTranscriptionFailure?(error)
        }
    }

    private func overlapsQuestion(from: Date, to: Date) -> Bool {
        if let openStart = openQuestionStart, to > openStart { return true }
        return finishedQuestionSpans.contains { from < $0.to && to > $0.from }
    }

    // MARK: Helpers

    private func sampleIndex(for date: Date, sessionStart: Date) -> Int {
        Int((date.timeIntervalSince(sessionStart) * Self.sampleRate).rounded())
    }

    /// Maps loudness to 0...1: -60 dB reads 0 and -10 dB reads 1.
    static func meterLevel(for frame: [Float]) -> Double {
        let rms = Double(EnergyUtteranceSegmenter.rootMeanSquare(of: frame))
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        return min(1, max(0, (decibels + 60) / 50))
    }
}
