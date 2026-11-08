import Foundation
import Testing
@testable import ClickyCore

/// Wave 4: the deferred key-loss notice always gets its turn, and a question dropped on loss leaves no trace.
struct Fix4FlowTests {
    // MARK: The "reading ended" signal, on every path (finding 1)

    @Test func finishWithoutAStartEventEndsTheReading() {
        var tracker = SpeechTurnTracker()
        let reading = tracker.begin(.answer)
        // The queued sentence finished (or was cancelled) with no start event: no speaking change, but it ended.
        #expect(tracker.event(token: reading.token, isSpeaking: false) == [])
        #expect(tracker.takeEndedReading() == .answer)
        #expect(tracker.currentSpeaker == nil)
    }

    @Test func stopBeforeTheVoiceStartsEndsTheReading() {
        var tracker = SpeechTurnTracker()
        _ = tracker.begin(.answer)
        #expect(tracker.stop(.answer) == [])
        #expect(tracker.takeEndedReading() == .answer)
    }

    @Test func stopAllBeforeTheVoiceStartsEndsTheReading() {
        var tracker = SpeechTurnTracker()
        _ = tracker.begin(.answer)
        #expect(tracker.stopAll() == [])
        #expect(tracker.takeEndedReading() == .answer)
    }

    @Test func aReadingThatStartedAndFinishedEndsAfterItsSpeakingReport() {
        var tracker = SpeechTurnTracker()
        let reading = tracker.begin(.answer)
        _ = tracker.event(token: reading.token, isSpeaking: true)
        #expect(tracker.takeEndedReading() == nil)
        #expect(tracker.event(token: reading.token, isSpeaking: false) == [SpeechChange(speaker: .answer, isSpeaking: false)])
        #expect(tracker.takeEndedReading() == .answer)
    }

    @Test func aStoppedReadingsLateEventsAreIgnoredAndEndNothingTwice() {
        var tracker = SpeechTurnTracker()
        let reading = tracker.begin(.answer)
        _ = tracker.stop(.answer)
        _ = tracker.takeEndedReading()
        #expect(tracker.event(token: reading.token, isSpeaking: false) == [])
        #expect(tracker.takeEndedReading() == nil)
    }

    @Test func nothingReadingMeansNothingEnded() {
        var tracker = SpeechTurnTracker()
        #expect(tracker.stop(.answer) == [])
        #expect(tracker.stopAll() == [])
        #expect(tracker.takeEndedReading() == nil)
    }

    @Test func aSampleReplacingTheAnswerEndsTheAnswersReading() {
        var tracker = SpeechTurnTracker()
        _ = tracker.begin(.answer)
        _ = tracker.begin(.sample, reportsImmediately: true)
        #expect(tracker.takeEndedReading() == .answer)
        #expect(tracker.currentSpeaker == .sample)
    }

    @Test func takingTheEndedReadingClearsIt() {
        var tracker = SpeechTurnTracker()
        _ = tracker.begin(.answer)
        _ = tracker.stopAll()
        #expect(tracker.takeEndedReading() == .answer)
        #expect(tracker.takeEndedReading() == nil)
    }

    // MARK: A first press abandoned during its listening report (finding 2)

    @Test func aFirstPressAbandonedWhileListeningIsReportedLogsNothingAndIsNotAccepted() async throws {
        let harness = FlowHarness(questions: ["never asked"])
        try await harness.flow.begin()
        let gate = TestGate()
        harness.output.holdNextPhaseChange(to: .listening, at: gate)
        let started = FlowHarness.startTime.addingTimeInterval(1000)
        let tap = Task { await harness.flow.handle(.questionStarted(at: started)) }
        await gate.waitUntilReached()

        #expect(await harness.flow.abandonListening())
        gate.open()
        let outcome = await tap.value

        #expect(outcome == .ignoredBecauseBusy)
        #expect(!harness.log.kinds.contains(.questionStarted))
        #expect(harness.output.phases.last == .idle)
        #expect(harness.claude.askedTurns.isEmpty)
    }

    @Test func aFirstPressNotAbandonedIsStillAcceptedAndLogged() async throws {
        let harness = FlowHarness(questions: ["asked"])
        try await harness.flow.begin()
        let started = FlowHarness.startTime.addingTimeInterval(1000)
        #expect(await harness.flow.handle(.questionStarted(at: started)) == .accepted)
        #expect(harness.log.kinds.contains(.questionStarted))
    }
}
