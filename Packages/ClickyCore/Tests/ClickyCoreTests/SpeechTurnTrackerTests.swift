import Testing
@testable import ClickyCore

/// One voice at a time, and old readings never disturb a new one.
struct SpeechTurnTrackerTests {
    private func shown(_ speaker: SpeechSpeaker) -> SpeechChange { SpeechChange(speaker: speaker, isSpeaking: true) }
    private func hidden(_ speaker: SpeechSpeaker) -> SpeechChange { SpeechChange(speaker: speaker, isSpeaking: false) }

    @Test func answerShowsOnStartAndFinishClearsIt() {
        var tracker = SpeechTurnTracker()
        let reading = tracker.begin(.answer)
        #expect(reading.changes.isEmpty)
        #expect(tracker.event(token: reading.token, isSpeaking: true) == [shown(.answer)])
        #expect(tracker.event(token: reading.token, isSpeaking: true).isEmpty)
        #expect(tracker.event(token: reading.token, isSpeaking: false) == [hidden(.answer)])
        #expect(tracker.event(token: reading.token, isSpeaking: false).isEmpty)
        #expect(tracker.currentSpeaker == nil)
    }

    @Test func stopThenSpeakAtOnceEndsWithCapsuleShowingForTheNewReading() {
        var tracker = SpeechTurnTracker()
        let old = tracker.begin(.answer)
        _ = tracker.event(token: old.token, isSpeaking: true)
        #expect(tracker.stop(.answer) == [hidden(.answer)])
        let new = tracker.begin(.answer)
        #expect(tracker.event(token: old.token, isSpeaking: false).isEmpty)
        #expect(tracker.event(token: new.token, isSpeaking: true) == [shown(.answer)])
        #expect(tracker.currentSpeaker == .answer)
    }

    @Test func oldCancelAfterTheNewReadingStartedDoesNotHideTheCapsule() {
        var tracker = SpeechTurnTracker()
        let old = tracker.begin(.answer)
        _ = tracker.event(token: old.token, isSpeaking: true)
        let new = tracker.begin(.answer)
        #expect(new.changes == [hidden(.answer)])
        #expect(tracker.event(token: new.token, isSpeaking: true) == [shown(.answer)])
        #expect(tracker.event(token: old.token, isSpeaking: false).isEmpty)
        #expect(tracker.currentSpeaker == .answer)
    }

    @Test func stopBeforeAnyStartReportsNothing() {
        var tracker = SpeechTurnTracker()
        _ = tracker.begin(.answer)
        #expect(tracker.stop().isEmpty)
    }

    @Test func samplePressedWhileAnAnswerReadsHidesTheCapsule() {
        var tracker = SpeechTurnTracker()
        let answer = tracker.begin(.answer)
        _ = tracker.event(token: answer.token, isSpeaking: true)
        let sample = tracker.begin(.sample, reportsImmediately: true)
        #expect(sample.changes == [hidden(.answer), shown(.sample)])
        #expect(tracker.event(token: answer.token, isSpeaking: false).isEmpty)
        #expect(tracker.currentSpeaker == .sample)
    }

    @Test func answerArrivingWhileTheSamplePlaysReturnsTheButtonToPlaySample() {
        var tracker = SpeechTurnTracker()
        let sample = tracker.begin(.sample, reportsImmediately: true)
        #expect(tracker.event(token: sample.token, isSpeaking: true).isEmpty)
        let answer = tracker.begin(.answer)
        #expect(answer.changes == [hidden(.sample)])
        #expect(tracker.event(token: sample.token, isSpeaking: false).isEmpty)
        #expect(tracker.event(token: answer.token, isSpeaking: true) == [shown(.answer)])
    }

    @Test func closingSettingsStopsTheSampleButNotAnAnswerReading() {
        var tracker = SpeechTurnTracker()
        _ = tracker.begin(.sample, reportsImmediately: true)
        #expect(tracker.stop(.sample) == [hidden(.sample)])

        let answer = tracker.begin(.answer)
        _ = tracker.event(token: answer.token, isSpeaking: true)
        #expect(tracker.stop(.sample).isEmpty)
        #expect(tracker.currentSpeaker == .answer)
    }

    @Test func sampleEndingOnItsOwnClearsTheButton() {
        var tracker = SpeechTurnTracker()
        let sample = tracker.begin(.sample, reportsImmediately: true)
        #expect(tracker.event(token: sample.token, isSpeaking: false) == [hidden(.sample)])
    }
}
