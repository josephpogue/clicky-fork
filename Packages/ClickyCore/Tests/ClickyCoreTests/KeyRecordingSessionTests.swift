import Foundation
import Testing
@testable import ClickyCore

/// What Settings shows while a key is recorded, refused, reset or cancelled, and when a refusal goes away.
struct KeyRecordingSessionTests {
    private let rightCmd = ModifierKey.rightCommand.heldBit
    private let comma: UInt16 = 43
    private func at(_ seconds: Double) -> Date { Date(timeIntervalSinceReferenceDate: 30_000 + seconds) }

    private let commandComma = QuestionKeySpec.combination(modifiers: [.command], keyCode: 43)
    /// The chat key's own form for "right Command alone": clashes with a lone right Command question key.
    private let chatRightCommand = QuestionKeySpec.sidedCombination(modifiers: [.rightCommand], keyCode: nil)
    private var defaults: SavedKeys { SavedKeys(question: .default, chat: .defaultChatKey) }

    private func mods(_ held: HeldModifiers, _ seconds: Double) -> QuestionKeyInput { .modifiersChanged(held: held, time: at(seconds)) }
    private func down(_ code: UInt16, held: HeldModifiers, _ seconds: Double) -> QuestionKeyInput {
        .keyDown(keyCode: code, held: held, isRepeat: false, time: at(seconds))
    }

    // MARK: A refused Reset

    @Test func aRefusedResetGoesOnTheNextRecord() {
        let saved = SavedKeys(question: .combination(modifiers: [.control], keyCode: 49), chat: chatRightCommand)
        var session = KeyRecordingSession(kind: .question)
        let outcome1 = session.reset(to: .default, saved: saved)
        #expect(outcome1 == nil)
        #expect(!session.refusal.isEmpty)
        session.start()
        #expect(session.refusal.isEmpty)
    }

    @Test func aRefusedResetGoesWhenAResetWorks() {
        var session = KeyRecordingSession(kind: .question)
        let clashing = SavedKeys(question: .combination(modifiers: [.control], keyCode: 49), chat: chatRightCommand)
        let outcome2 = session.reset(to: .default, saved: clashing)
        #expect(outcome2 == nil)
        let outcome3 = session.reset(to: .default, saved: defaults)
        #expect(outcome3 == .default)
        #expect(session.refusal.isEmpty)
    }

    @Test func aRefusedResetGoesTheMomentTheClashIsGone() {
        var session = KeyRecordingSession(kind: .question)
        let clashing = SavedKeys(question: .combination(modifiers: [.control], keyCode: 49), chat: chatRightCommand)
        let outcome4 = session.reset(to: .default, saved: clashing)
        #expect(outcome4 == nil)
        let text = session.refusal.text
        #expect(text.contains(chatRightCommand.displayName))
        // The other key changed to one that does not clash.
        session.savedKeysChanged(SavedKeys(question: clashing.question, chat: .defaultChatKey))
        #expect(session.refusal.isEmpty)
    }

    @Test func aRefusalIsRewordedWhenAnotherKeyClashesNow() {
        var session = KeyRecordingSession(kind: .question)
        let clashing = SavedKeys(question: .combination(modifiers: [.control], keyCode: 49), chat: chatRightCommand)
        let outcome5 = session.reset(to: .default, saved: clashing)
        #expect(outcome5 == nil)
        let otherChat = QuestionKeySpec.sidedCombination(modifiers: [.rightCommand, .leftOption], keyCode: nil)
        // Right Command + left Option does not clash with a lone right Command: the message goes.
        session.savedKeysChanged(SavedKeys(question: clashing.question, chat: otherChat))
        #expect(session.refusal.isEmpty)
        // And one that still clashes names the new chat key.
        var again = KeyRecordingSession(kind: .question)
        let outcome6 = again.reset(to: .default, saved: clashing)
        #expect(outcome6 == nil)
        let sameFamily = QuestionKeySpec.sidedCombination(modifiers: [.rightCommand], keyCode: nil)
        again.savedKeysChanged(SavedKeys(question: clashing.question, chat: sameFamily))
        #expect(!again.refusal.isEmpty)
    }

    @Test func aRefusalGoesWhenSettingsCloses() {
        var session = KeyRecordingSession(kind: .chat)
        let saved = SavedKeys(question: .loneModifier(.rightCommand), chat: .defaultChatKey)
        let outcome7 = session.reset(to: chatRightCommand, saved: saved)
        #expect(outcome7 == nil)
        let outcome8 = session.reset(to: chatRightCommand, saved: saved)
        #expect(outcome8 == nil)
        #expect(!session.refusal.isEmpty)
        session.settingsClosed()
        #expect(session.refusal.isEmpty)
        #expect(!session.isRecording)
    }

    // MARK: A recording refusal

    @Test func aRefusedRecordingStaysRecordingAndGoesOnCancel() {
        var session = KeyRecordingSession(kind: .chat)
        session.start()
        let saved = SavedKeys(question: .loneModifier(.rightCommand), chat: .defaultChatKey)
        let outcome9 = session.handle(mods(rightCmd, 0), saved: saved)
        #expect(outcome9 == .keepRecording)
        let outcome10 = session.handle(mods([], 0.1), saved: saved)
        #expect(outcome10 == .keepRecording)
        #expect(session.isRecording)
        #expect(session.refusal.text.contains("Right Command"))
        session.cancel()
        #expect(session.refusal.isEmpty)
        #expect(!session.isRecording)
    }

    @Test func aRejectedKeyStaysUntilTheRecordingEnds() {
        var session = KeyRecordingSession(kind: .question)
        session.start()
        let outcome11 = session.handle(down(comma, held: [], 0), saved: defaults)
        #expect(outcome11 == .keepRecording)
        #expect(session.refusal.text == QuestionKeyRejection.needsModifier.message)
        // A rejection has no other key in it, so a key change leaves it alone.
        session.savedKeysChanged(defaults)
        #expect(session.refusal.text == QuestionKeyRejection.needsModifier.message)
        let outcome12 = session.handle(down(53, held: [], 0.1), saved: defaults)
        #expect(outcome12 == .cancelled)
        #expect(session.refusal.isEmpty)
    }

    @Test func aGoodKeyAfterARefusalIsSavedAndClearsTheMessage() {
        var session = KeyRecordingSession(kind: .question)
        session.start()
        _ = session.handle(down(comma, held: [], 0), saved: defaults)
        let step = session.handle(down(49, held: ModifierKey.leftControl.heldBit, 0.1), saved: defaults)
        #expect(step == .save(.combination(modifiers: [.control], keyCode: 49)))
        #expect(session.refusal.isEmpty)
        #expect(!session.isRecording)
    }

    // MARK: Escape in both sections

    @Test func escapeCancelsARecordingInBothSections() {
        for kind in [KeyRecordingSession.Kind.question, .chat] {
            var session = KeyRecordingSession(kind: kind)
            session.start()
            let outcome13 = session.handle(down(QuestionKeyRecorder.escapeKeyCode, held: [], 0), saved: defaults)
            #expect(outcome13 == .cancelled)
            #expect(!session.isRecording)
            #expect(session.hint.isEmpty)
        }
    }

    @Test func escapeClearsARefusalOnScreen() {
        for kind in [KeyRecordingSession.Kind.question, .chat] {
            var session = KeyRecordingSession(kind: kind)
            session.start()
            _ = session.handle(down(comma, held: [], 0), saved: defaults)
            #expect(!session.refusal.isEmpty)
            let outcome14 = session.handle(down(QuestionKeyRecorder.escapeKeyCode, held: [], 0.1), saved: defaults)
            #expect(outcome14 == .cancelled)
            #expect(session.refusal.isEmpty)
        }
    }

    @Test func aCancelledRecordingForgetsTheModifiersThatWereHeld() {
        for kind in [KeyRecordingSession.Kind.question, .chat] {
            var session = KeyRecordingSession(kind: kind)
            session.start()
            _ = session.handle(mods(rightCmd, 0), saved: defaults)
            #expect(!session.hint.isEmpty)
            session.cancel()
            #expect(session.hint.isEmpty)
            // The next recording does not inherit the held Command: letting go of it records nothing.
            session.start()
            let outcome15 = session.handle(mods([], 0.2), saved: defaults)
            #expect(outcome15 == .keepRecording)
            #expect(session.isRecording)
        }
    }

    @Test func escapeInTheSidedRecorderAlsoCancelsWithAFunctionKeyHeld() {
        var session = KeyRecordingSession(kind: .chat)
        session.start()
        let step = session.handle(down(QuestionKeyRecorder.escapeKeyCode, held: HeldModifiers.function, 0), saved: defaults)
        #expect(step == .cancelled)
    }

    // MARK: A chat key that is already off does not block a new question key

    @Test func anOffChatKeyDoesNotBlockANewQuestionKey() {
        // The question key in use (Command, either side) already clashes with the chat key, so the chat key is off.
        let inUse = QuestionKeySpec.combination(modifiers: [.command], keyCode: nil)
        #expect(!KeyOverlap.isChatKeyActive(chatRightCommand, question: inUse))
        #expect(KeyOverlap.refusalForNewQuestionKey(.loneModifier(.rightCommand), currentQuestion: inUse, chat: chatRightCommand) == nil)
        // The old function would have refused it.
        #expect(KeyOverlap.refusalForQuestionKey(.loneModifier(.rightCommand), chat: chatRightCommand) != nil)
    }

    @Test func aWorkingChatKeyStillBlocksAClashingQuestionKey() {
        let text = KeyOverlap.refusalForNewQuestionKey(.loneModifier(.rightCommand), currentQuestion: .combination(modifiers: [.control], keyCode: 49), chat: chatRightCommand)
        #expect(text?.contains("chat key") == true)
        #expect(text?.contains(chatRightCommand.displayName) == true)
    }

    @Test func refusalsAndNoticesNameTheClashingKeyAndSayWhatToDo() {
        let chat = KeyOverlap.refusalForChatKey(chatRightCommand, question: .loneModifier(.rightCommand))
        #expect(chat?.contains("question key (Right Command)") == true)
        #expect(chat?.contains("different key for the chat key") == true)
        let question = KeyOverlap.refusalForQuestionKey(.loneModifier(.rightCommand), chat: chatRightCommand)
        #expect(question?.contains("chat key (") == true)
        #expect(question?.contains("different key for the question key") == true)
        let notice = KeyOverlap.inactiveChatKeyNotice(chat: chatRightCommand, question: .loneModifier(.rightCommand))
        #expect(notice?.contains("question key (Right Command)") == true)
        #expect(notice?.contains("Record a different chat key") == true)
    }

    @Test func theOffNoticeFollowsTheQuestionKeyThatTakesThePress() {
        let first = KeyOverlap.inactiveChatKeyNotice(chat: chatRightCommand, question: .loneModifier(.rightCommand))
        let second = KeyOverlap.inactiveChatKeyNotice(chat: chatRightCommand, question: .combination(modifiers: [.command], keyCode: nil))
        #expect(first != nil && second != nil && first != second)
        #expect(KeyOverlap.inactiveChatKeyNotice(chat: chatRightCommand, question: .combination(modifiers: [.control], keyCode: 49)) == nil)
    }
}
