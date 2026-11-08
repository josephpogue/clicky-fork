import Foundation
import Testing
@testable import ClickyCore

/// Wave 3: what the user sees after the key tap dies, and the words of a refused Reset.
struct Fix3KeyTests {
    private let notice = KeyTapNotice.lost

    // MARK: When the cursor notice shows (finding 1)

    @Test func nothingInFlightShowsTheCursorNoticeAtOnce() {
        var state = KeyTapLossState()
        let action = state.tapLost(text: notice, isAnswerInFlight: false, isReadingAloud: false)
        #expect(action == .showNow(notice))
        #expect(state.isLost)
        #expect(state.deferredCursorText == nil)
    }

    @Test func aStreamingAnswerDefersTheCursorNotice() {
        var state = KeyTapLossState()
        let action = state.tapLost(text: notice, isAnswerInFlight: true, isReadingAloud: false)
        #expect(action == .deferred)
        #expect(state.deferredCursorText == notice)
        #expect(state.answerActivityChanged(isAnswerInFlight: true, isReadingAloud: false) == nil)
    }

    @Test func aReadingAloudDefersTheCursorNotice() {
        var state = KeyTapLossState()
        let action = state.tapLost(text: notice, isAnswerInFlight: false, isReadingAloud: true)
        #expect(action == .deferred)
        #expect(state.answerActivityChanged(isAnswerInFlight: false, isReadingAloud: true) == nil)
    }

    @Test func theDeferredNoticeShowsOnceWhenTheAnswerHasEndedAndTheReadingHasFinished() {
        var state = KeyTapLossState()
        _ = state.tapLost(text: notice, isAnswerInFlight: true, isReadingAloud: true)
        // The answer ended but its voice is still reading.
        #expect(state.answerActivityChanged(isAnswerInFlight: false, isReadingAloud: true) == nil)
        // The reading finished.
        #expect(state.answerActivityChanged(isAnswerInFlight: false, isReadingAloud: false) == notice)
        // Shown once.
        #expect(state.answerActivityChanged(isAnswerInFlight: false, isReadingAloud: false) == nil)
        #expect(state.deferredCursorText == nil)
        #expect(state.isLost)
    }

    @Test func aStopBeforeTheAnswerEndsShowsNothingBesideTheCursor() {
        var state = KeyTapLossState()
        _ = state.tapLost(text: notice, isAnswerInFlight: true, isReadingAloud: false)
        state.sessionStopped()
        #expect(state.answerActivityChanged(isAnswerInFlight: false, isReadingAloud: false) == nil)
        #expect(!state.isLost)
    }

    @Test func anotherNoticeTakingTheCursorDropsTheDeferredOne() {
        var state = KeyTapLossState()
        _ = state.tapLost(text: notice, isAnswerInFlight: true, isReadingAloud: false)
        state.cursorTakenByAnotherNotice()
        #expect(state.answerActivityChanged(isAnswerInFlight: false, isReadingAloud: false) == nil)
        #expect(state.isLost)
    }

    // MARK: The lost state (findings 4 and 5)

    @Test func theLostStateClearsAtStopAndAtStart() {
        var state = KeyTapLossState()
        _ = state.tapLost(text: notice, isAnswerInFlight: false, isReadingAloud: false)
        #expect(state.isLost)
        state.sessionStopped()
        #expect(!state.isLost)
        _ = state.tapLost(text: notice, isAnswerInFlight: false, isReadingAloud: false)
        state.sessionStarted()
        #expect(!state.isLost)
    }

    @Test func aSecondLossInTheSameSessionIsNotReportedAgainButTheNextSessionsIs() {
        var state = KeyTapLossState()
        #expect(state.tapLost(text: notice, isAnswerInFlight: false, isReadingAloud: false) == .showNow(notice))
        #expect(state.tapLost(text: notice, isAnswerInFlight: false, isReadingAloud: false) == .none)
        state.sessionStopped()
        state.sessionStarted()
        #expect(state.tapLost(text: notice, isAnswerInFlight: false, isReadingAloud: false) == .showNow(notice))
    }

    @Test func theLossNoticeIsRecognisedWhetherOrNotAQuestionWasDropped() {
        #expect(KeyTapNotice.isLossNotice(KeyTapNotice.lost))
        #expect(KeyTapNotice.isLossNotice(KeyTapNotice.text(questionDropped: true)))
        #expect(KeyTapNotice.text(questionDropped: false) == KeyTapNotice.lost)
        #expect(KeyTapNotice.text(questionDropped: true).hasPrefix(KeyTapNotice.lost))
        #expect(KeyTapNotice.text(questionDropped: true).contains("was not sent"))
        #expect(!KeyTapNotice.isLossNotice("Switched to ChatGPT"))
        #expect(!KeyTapNotice.isLossNotice(nil))
    }

    @Test func settingsNamesTheKeyAndTheFix() {
        let line = KeyTapNotice.settingsLine(keyName: "question key")
        #expect(line.contains("question key"))
        #expect(line.contains("Accessibility"))
        #expect(line.contains("stop and start the session"))
        #expect(KeyTapNotice.settingsLine(keyName: "chat key").contains("chat key"))
    }

    // MARK: A refused Reset (finding 6)

    @Test func aRefusedChatKeyResetNamesTheResetAndBothKeys() {
        let chat = QuestionKeySpec.defaultChatKey
        let question = QuestionKeySpec.combination(modifiers: [.command], keyCode: 43)
        var session = KeyRecordingSession(kind: .chat)
        let saved = SavedKeys(question: question, chat: .sidedCombination(modifiers: [.rightOption], keyCode: nil))
        #expect(session.reset(to: chat, saved: saved) == nil)
        let expected = "Reset would make the chat key \(chat.displayName), which also fires your question key (\(question.displayName)). Record a different question key first, or record a different chat key."
        #expect(session.refusal.text == expected)
    }

    @Test func aRefusedQuestionKeyResetNamesTheResetAndBothKeys() {
        let chat = QuestionKeySpec.sidedCombination(modifiers: [.rightCommand], keyCode: nil)
        let question = QuestionKeySpec.default
        var session = KeyRecordingSession(kind: .question)
        let saved = SavedKeys(question: .combination(modifiers: [.control], keyCode: 49), chat: chat)
        #expect(session.reset(to: question, saved: saved) == nil)
        let expected = "Reset would make the question key \(question.displayName), which also fires your chat key (\(chat.displayName)). Record a different chat key first, or record a different question key."
        #expect(session.refusal.text == expected)
    }

    @Test func aResetRefusalStaysAResetRefusalWhenTheOtherKeyChangesToAnotherClash() {
        let chat = QuestionKeySpec.sidedCombination(modifiers: [.rightCommand], keyCode: nil)
        var session = KeyRecordingSession(kind: .question)
        let saved = SavedKeys(question: .combination(modifiers: [.control], keyCode: 49), chat: chat)
        _ = session.reset(to: .default, saved: saved)
        session.savedKeysChanged(SavedKeys(question: saved.question, chat: chat))
        #expect(session.refusal.text.hasPrefix("Reset would make the question key"))
    }

    @Test func aRecordedKeyRefusalKeepsTodaysWords() {
        let question = QuestionKeySpec.loneModifier(.rightCommand)
        let text = KeyOverlap.refusalForChatKey(.sidedCombination(modifiers: [.rightCommand], keyCode: nil), question: question)
        #expect(text == "That press would also fire your question key (\(question.displayName)). Press a different key for the chat key.")
    }

    // MARK: A question being listened for when the keys die (finding 3)

    @Test func abandoningAListenedQuestionEndsListeningAndSendsNothing() async throws {
        let harness = FlowHarness(questions: ["never asked"])
        try await harness.flow.begin()
        let started = FlowHarness.startTime.addingTimeInterval(1000)
        #expect(await harness.flow.handle(.questionStarted(at: started)) == .accepted)
        #expect(harness.output.phases.last == .listening)

        #expect(await harness.flow.abandonListening())
        #expect(harness.output.phases.last == .idle)
        // The send tap can no longer come, and if it did, nothing is sent.
        let sent = await harness.flow.handle(.sendQuestion(speechFrom: started, speechTo: started.addingTimeInterval(3)))
        #expect(sent == .ignoredBecauseBusy)
        #expect(harness.claude.askedTurns.isEmpty)
        // Nothing is being listened for any more.
        #expect(await harness.flow.abandonListening() == false)
    }

    @Test func abandoningWithNothingListenedForChangesNothing() async throws {
        let harness = FlowHarness(questions: ["q"])
        try await harness.flow.begin()
        let phasesBefore = harness.output.phases
        #expect(await harness.flow.abandonListening() == false)
        #expect(harness.output.phases == phasesBefore)
    }

    @Test func aQuestionAlreadySentIsNotAbandoned() async throws {
        let harness = FlowHarness(questions: ["asked"])
        try await harness.flow.begin()
        await harness.askQuestion()
        #expect(await harness.flow.abandonListening() == false)
        #expect(harness.claude.askedTurns.count == 1)
    }
}
