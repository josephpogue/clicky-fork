import Foundation
import Testing
@testable import ClickyCore

/// The key fixes: one recorder at a time, a chat key that yields to the question key, loading saved keys, and
/// what the chat key does to a window behind another.
struct FixKeysTests {
    private let rightCmd = ModifierKey.rightCommand.heldBit
    private let comma: UInt16 = 43
    private func at(_ seconds: Double) -> Date { Date(timeIntervalSinceReferenceDate: 12_000 + seconds) }

    // MARK: One recorder at a time

    @Test func startingASecondRecordingCancelsTheFirstAndKeepsTheKeysSuspended() {
        var tracker = KeyRecordingTracker()
        #expect(tracker.begin("question") == nil)
        #expect(tracker.isRecording)
        #expect(tracker.begin("chat") == "question")
        // The cancelled section ends its recording; the chat section still records.
        tracker.end("question")
        #expect(tracker.isRecording)
        #expect(tracker.recordingOwner == "chat")
        tracker.end("chat")
        #expect(!tracker.isRecording)
    }

    @Test func recordingAgainInTheSameSectionCancelsNothing() {
        var tracker = KeyRecordingTracker()
        _ = tracker.begin("chat")
        #expect(tracker.begin("chat") == nil)
        tracker.end("chat")
        #expect(!tracker.isRecording)
    }

    // MARK: Saved chat key at launch

    @Test func savedChatKeyKeepsOnlyTheFormsItsRecorderMakes() {
        #expect(QuestionKeySpec.savedChatKey(encoded: nil) == .defaultChatKey)
        #expect(QuestionKeySpec.savedChatKey(encoded: "garbage") == .defaultChatKey)
        #expect(QuestionKeySpec.savedChatKey(encoded: "combo:command:43") == .defaultChatKey)
        #expect(QuestionKeySpec.savedChatKey(encoded: "lone:54") == .defaultChatKey)
        let own = QuestionKeySpec.sidedCombination(modifiers: [.leftOption, .rightShift], keyCode: 49)
        #expect(QuestionKeySpec.savedChatKey(encoded: own.encoded) == own)
    }

    // MARK: A chat key that overlaps the question key is inactive

    private let commandComma = QuestionKeySpec.combination(modifiers: [.command], keyCode: 43)

    @Test func theQuestionKeyWinsWhenTheLoadedChatKeyOverlapsIt() {
        var detector = TwoKeyDetector(questionKey: commandComma, chatKey: .defaultChatKey)
        #expect(!detector.isChatKeyActive)
        let results = [QuestionKeyInput.modifiersChanged(held: rightCmd, time: at(0)),
                       .keyDown(keyCode: comma, held: rightCmd, isRepeat: false, time: at(0.1)),
                       .keyUp(keyCode: comma, time: at(0.2))].map { detector.handle($0) }
        #expect(results.compactMap(\.questionTap).count == 1)
        #expect(results.allSatisfy { !$0.chatPressed })
    }

    @Test func aChatKeyThatIsSwitchedOffRemovesNothingAndNeedsNoActiveTap() {
        let lonePlusInactive = TwoKeyDetector(questionKey: .loneModifier(.rightCommand),
                                              chatKey: .sidedCombination(modifiers: [.rightCommand], keyCode: nil))
        #expect(!lonePlusInactive.isChatKeyActive)
        #expect(!lonePlusInactive.swallowsAKey)
    }

    @Test func aNonSidedChatKeyIsInactive() {
        #expect(!TwoKeyDetector(questionKey: .default, chatKey: .combination(modifiers: [.command], keyCode: 43)).isChatKeyActive)
        #expect(!TwoKeyDetector(questionKey: .default, chatKey: .loneModifier(.leftCommand)).isChatKeyActive)
    }

    @Test func changingTheQuestionKeyAwayFromTheOverlapSwitchesTheChatKeyOnAtOnce() {
        var detector = TwoKeyDetector(questionKey: commandComma, chatKey: .defaultChatKey)
        #expect(!detector.isChatKeyActive)
        detector.apply(questionKey: .default)
        #expect(detector.isChatKeyActive)
        #expect(detector.swallowsAKey)
        let results = [QuestionKeyInput.modifiersChanged(held: rightCmd, time: at(0)),
                       .keyDown(keyCode: comma, held: rightCmd, isRepeat: false, time: at(0.1))].map { detector.handle($0) }
        #expect(results.filter(\.chatPressed).count == 1)
        #expect(results.last?.swallowEvent == true)
    }

    @Test func changingTheQuestionKeyOntoTheChatKeySwitchesItOff() {
        var detector = TwoKeyDetector(questionKey: .default, chatKey: .defaultChatKey)
        detector.apply(questionKey: commandComma)
        #expect(!detector.isChatKeyActive)
        #expect(detector.chatKey == .defaultChatKey)
    }

    @Test func settingsSaysWhyTheChatKeyIsOff() {
        #expect(KeyOverlap.inactiveChatKeyNotice(chat: .defaultChatKey, question: commandComma)
                == "Your question key uses this press. Record a different chat key.")
        #expect(KeyOverlap.inactiveChatKeyNotice(chat: .defaultChatKey, question: .default) == nil)
    }

    // MARK: The chat key and a window behind another

    @Test func aChatWindowBehindAnotherWindowComesForwardInsteadOfClosing() {
        #expect(ChatKeyPressAction.forPress(isVisible: false, isBehindAnotherWindow: false) == .show)
        #expect(ChatKeyPressAction.forPress(isVisible: true, isBehindAnotherWindow: false) == .hide)
        #expect(ChatKeyPressAction.forPress(isVisible: true, isBehindAnotherWindow: true) == .bringToFront)
    }
}
