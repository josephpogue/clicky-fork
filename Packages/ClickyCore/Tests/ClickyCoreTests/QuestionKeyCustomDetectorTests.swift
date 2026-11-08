import Foundation
import Testing
@testable import ClickyCore

/// The detector for every kind of question key. Times are seconds from a fixed start.
struct QuestionKeyCustomDetectorTests {
    private let start = Date(timeIntervalSinceReferenceDate: 5_000)
    private func at(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }

    private let leftCtrl = ModifierKey.leftControl.heldBit
    private let leftOpt = ModifierKey.leftOption.heldBit
    private let rightOpt = ModifierKey.rightOption.heldBit
    private let rightCmd = ModifierKey.rightCommand.heldBit
    private let leftShift = ModifierKey.leftShift.heldBit

    private func mods(_ held: HeldModifiers, _ seconds: Double) -> QuestionKeyInput {
        .modifiersChanged(held: held, time: at(seconds))
    }
    private func key(_ code: UInt16, held: HeldModifiers, repeat isRepeat: Bool = false, _ seconds: Double) -> QuestionKeyInput {
        .keyDown(keyCode: code, held: held, isRepeat: isRepeat, time: at(seconds))
    }

    private func run(_ spec: QuestionKeySpec, _ inputs: [QuestionKeyInput]) -> [QuestionKeyDetection] {
        var detector = QuestionKeyDetector(spec: spec)
        return inputs.map { detector.handle($0) }
    }
    private func taps(_ spec: QuestionKeySpec, _ inputs: [QuestionKeyInput]) -> [LoneTap] {
        run(spec, inputs).compactMap(\.tap)
    }

    // MARK: Lone modifier

    @Test func defaultRightCommandTapStillWorks() {
        let result = taps(.default, [mods(rightCmd, 0), mods([], 0.1)])
        #expect(result == [LoneTap(pressedAt: at(0), releasedAt: at(0.1))])
    }

    @Test func rightCommandWithAKeyIsNotATap() {
        #expect(taps(.default, [mods(rightCmd, 0), key(8, held: rightCmd, 0.05), mods([], 0.1)]).isEmpty)
    }

    @Test func rightCommandPressedWithAnotherModifierIsNotATap() {
        #expect(taps(.default, [mods(leftShift, 0), mods(leftShift.union(rightCmd), 0.05), mods(leftShift, 0.1), mods([], 0.2)]).isEmpty)
    }

    @Test func leftControlAsLoneKeyIgnoresRightControl() {
        let spec = QuestionKeySpec.loneModifier(.leftControl)
        #expect(taps(spec, [mods(ModifierKey.rightControl.heldBit, 0), mods([], 0.1)]).isEmpty)
        #expect(taps(spec, [mods(leftCtrl, 0), mods([], 0.1)]).count == 1)
    }

    @Test func rightOptionAsLoneKeyIgnoresLeftOption() {
        let spec = QuestionKeySpec.loneModifier(.rightOption)
        #expect(taps(spec, [mods(leftOpt, 0), mods([], 0.1)]).isEmpty)
        #expect(taps(spec, [mods(rightOpt, 0), mods([], 0.1)]).count == 1)
    }

    @Test func loneModifierNeverSwallowsAnything() {
        let results = run(.default, [mods(rightCmd, 0), key(8, held: rightCmd, 0.05), mods([], 0.1)])
        #expect(results.allSatisfy { !$0.swallowEvent })
    }

    @Test func fnHeldSpoilsALoneTap() {
        #expect(taps(.default, [mods(HeldModifiers.function.union(rightCmd), 0), mods(.function, 0.1), mods([], 0.2)]).isEmpty)
    }

    // MARK: Modifiers plus a key

    private let ctrlOptSpace = QuestionKeySpec.combination(modifiers: [.control, .option], keyCode: 49)

    @Test func comboFiresOnTheKeyAndSwallowsIt() {
        let held = leftCtrl.union(leftOpt)
        let results = run(ctrlOptSpace, [mods(leftCtrl, 0), mods(held, 0.05), key(49, held: held, 0.1)])
        #expect(results[2].tap == LoneTap(pressedAt: at(0.1), releasedAt: at(0.1)))
        #expect(results[2].swallowEvent)
        #expect(results[0].swallowEvent == false && results[1].swallowEvent == false)
    }

    @Test func comboAcceptsEitherSideOfAModifier() {
        let held = ModifierKey.rightControl.heldBit.union(rightOpt)
        #expect(taps(ctrlOptSpace, [key(49, held: held, 0)]).count == 1)
    }

    @Test func comboKeyReleaseIsSwallowedOnceAndRepeatsAreHidden() {
        let held = leftCtrl.union(leftOpt)
        let results = run(ctrlOptSpace, [
            key(49, held: held, 0), key(49, held: held, repeat: true, 0.5),
            .keyUp(keyCode: 49, time: at(0.6)), .keyUp(keyCode: 49, time: at(0.7)),
        ])
        #expect(results.compactMap(\.tap).count == 1)
        #expect(results.map(\.swallowEvent) == [true, true, true, false])
    }

    @Test func keyReleaseAfterModifiersWereLetGoIsStillSwallowed() {
        let held = leftCtrl.union(leftOpt)
        let results = run(ctrlOptSpace, [key(49, held: held, 0), mods([], 0.1), .keyUp(keyCode: 49, time: at(0.2))])
        #expect(results[2].swallowEvent)
    }

    @Test(arguments: [0, 1, 2])
    func comboIgnoresTheKeyWithTheWrongModifiers(case index: Int) {
        let heldCases: [HeldModifiers] = [[], leftCtrl, leftCtrl.union(leftOpt).union(leftShift)]
        let results = run(ctrlOptSpace, [key(49, held: heldCases[index], 0)])
        #expect(results[0] == QuestionKeyDetection())
    }

    @Test func comboIgnoresOtherKeys() {
        let held = leftCtrl.union(leftOpt)
        #expect(run(ctrlOptSpace, [key(8, held: held, 0)])[0] == QuestionKeyDetection())
    }

    @Test func comboWithFnHeldStillMatchesBecauseArrowAndFunctionKeysSetFn() {
        let fKey = QuestionKeySpec.combination(modifiers: [.control], keyCode: 96)
        #expect(taps(fKey, [key(96, held: leftCtrl.union(.function), 0)]).count == 1)
    }

    // MARK: Modifiers only

    private let ctrlOpt = QuestionKeySpec.combination(modifiers: [.control, .option], keyCode: nil)

    @Test func modifiersOnlyComboFiresWhenLetGo() {
        let both = leftCtrl.union(leftOpt)
        let result = taps(ctrlOpt, [mods(leftCtrl, 0), mods(both, 0.05), mods(leftCtrl, 0.2), mods([], 0.25)])
        #expect(result == [LoneTap(pressedAt: at(0.05), releasedAt: at(0.2))])
    }

    @Test func modifiersOnlyComboAcceptsEitherSide() {
        let both = ModifierKey.rightControl.heldBit.union(rightOpt)
        #expect(taps(ctrlOpt, [mods(both, 0), mods([], 0.1)]).count == 1)
    }

    @Test func modifiersOnlyComboWithAKeyInBetweenIsNotATap() {
        let both = leftCtrl.union(leftOpt)
        #expect(taps(ctrlOpt, [mods(both, 0), key(8, held: both, 0.05), mods([], 0.1)]).isEmpty)
    }

    @Test func modifiersOnlyComboWithAnExtraModifierIsNotATap() {
        let all = leftCtrl.union(leftOpt).union(leftShift)
        #expect(taps(ctrlOpt, [mods(leftCtrl, 0), mods(leftCtrl.union(leftShift), 0.02), mods(all, 0.05), mods(leftCtrl.union(leftOpt), 0.1), mods([], 0.2)]).isEmpty)
    }

    @Test func modifiersOnlyComboWithAClickInBetweenIsNotATap() {
        let both = leftCtrl.union(leftOpt)
        #expect(taps(ctrlOpt, [mods(both, 0), .mouseButtonDown(time: at(0.05)), mods([], 0.1)]).isEmpty)
    }

    @Test func modifiersOnlyComboHeldAsLongPressIsNotATap() {
        let both = leftCtrl.union(leftOpt)
        #expect(taps(ctrlOpt, [mods(both, 0), mods([], 1.5)]).isEmpty)
    }

    @Test func modifiersOnlyComboDoesNotFireTwiceFromOneHold() {
        let both = leftCtrl.union(leftOpt)
        let result = taps(ctrlOpt, [mods(both, 0), mods(leftCtrl, 0.1), mods(both, 0.15), mods(leftCtrl, 0.2), mods([], 0.25)])
        #expect(result.count == 1)
    }

    @Test func modifiersOnlyComboFiresAgainOnTheNextCleanPress() {
        let both = leftCtrl.union(leftOpt)
        let result = taps(ctrlOpt, [mods(both, 0), mods([], 0.1), mods(both, 1), mods([], 1.1)])
        #expect(result.count == 2)
    }

    @Test func modifiersOnlyComboNeverSwallows() {
        let both = leftCtrl.union(leftOpt)
        #expect(run(ctrlOpt, [mods(both, 0), mods([], 0.1), key(49, held: [], 0.2)]).allSatisfy { !$0.swallowEvent })
    }

    @Test func comboKeysFeedTheSendPairLikeALoneTap() {
        var detector = QuestionKeyDetector(spec: ctrlOptSpace)
        var machine = QuestionKeyStateMachine()
        let held = leftCtrl.union(leftOpt)
        let first = detector.handle(key(49, held: held, 1)).tap.map { machine.handleLoneTap($0) }
        let second = detector.handle(key(49, held: held, 4)).tap.map { machine.handleLoneTap($0) }
        #expect(first == .questionStarted(at: at(1)))
        #expect(second == .sendQuestion(speechFrom: at(1), speechTo: at(4)))
    }
}
