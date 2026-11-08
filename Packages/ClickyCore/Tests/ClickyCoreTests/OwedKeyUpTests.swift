import Foundation
import Testing
@testable import ClickyCore

/// A key-up the tap promised to hide (it hid the key-down) is still hidden after a suspension, a key change or a
/// reset, so the app the user is in never sees half a key press.
struct OwedKeyUpTests {
    private let rightCmd = ModifierKey.rightCommand.heldBit
    private let comma: UInt16 = 43
    private func at(_ seconds: Double) -> Date { Date(timeIntervalSinceReferenceDate: 20_000 + seconds) }

    private func chatKeyGoesDown(_ detector: inout TwoKeyDetector) {
        _ = detector.handle(.modifiersChanged(held: rightCmd, time: at(0)))
        let down = detector.handle(.keyDown(keyCode: comma, held: rightCmd, isRepeat: false, time: at(0.1)))
        #expect(down.swallowEvent)
        #expect(down.chatPressed)
    }

    @Test func aResetBetweenTheCommaGoingDownAndUpStillHidesTheRelease() {
        var detector = TwoKeyDetector(questionKey: .default, chatKey: .defaultChatKey)
        chatKeyGoesDown(&detector)
        detector.reset()
        let up = detector.handle(.keyUp(keyCode: comma, time: at(0.3)))
        #expect(up.swallowEvent)
        // Only the one release is owed.
        #expect(!detector.handle(.keyUp(keyCode: comma, time: at(0.4))).swallowEvent)
    }

    @Test func changingTheChatKeyBetweenDownAndUpStillHidesTheRelease() {
        var detector = TwoKeyDetector(questionKey: .default, chatKey: .defaultChatKey)
        chatKeyGoesDown(&detector)
        detector.apply(chatKey: .sidedCombination(modifiers: [.leftOption], keyCode: 49))
        #expect(detector.handle(.keyUp(keyCode: comma, time: at(0.3))).swallowEvent)
    }

    @Test func changingTheQuestionKeyBetweenDownAndUpStillHidesTheRelease() {
        var detector = TwoKeyDetector(questionKey: .default, chatKey: .defaultChatKey)
        chatKeyGoesDown(&detector)
        detector.apply(questionKey: .loneModifier(.leftOption))
        #expect(detector.handle(.keyUp(keyCode: comma, time: at(0.3))).swallowEvent)
    }

    @Test func whileSuspendedTheOwedReleaseAndRepeatsAreHiddenAndNothingElseIs() {
        var detector = TwoKeyDetector(questionKey: .default, chatKey: .defaultChatKey)
        chatKeyGoesDown(&detector)
        // Recording starts here: the tap no longer feeds the detector.
        let swallowed1 = detector.swallowsWhileSuspended(.keyDown(keyCode: comma, held: rightCmd, isRepeat: true, time: at(0.2)))
        #expect(swallowed1)
        let swallowed2 = detector.swallowsWhileSuspended(.keyUp(keyCode: 0, time: at(0.25)))
        #expect(!swallowed2)
        let swallowed3 = detector.swallowsWhileSuspended(.keyUp(keyCode: comma, time: at(0.3)))
        #expect(swallowed3)
        let swallowed4 = detector.swallowsWhileSuspended(.keyUp(keyCode: comma, time: at(0.4)))
        #expect(!swallowed4)
    }

    @Test func aNewPressOfTheKeyAfterAMissedReleaseIsNotLeftOwingARelease() {
        var detector = TwoKeyDetector(questionKey: .default, chatKey: .defaultChatKey)
        chatKeyGoesDown(&detector)
        // The release never arrived (the tap was switched off). A plain comma later passes through whole.
        detector.reset()
        let plainDown = detector.handle(.keyDown(keyCode: comma, held: [], isRepeat: false, time: at(1)))
        #expect(!plainDown.swallowEvent)
        #expect(!detector.handle(.keyUp(keyCode: comma, time: at(1.1))).swallowEvent)
    }
}
