import Foundation
import Testing
@testable import ClickyCore

struct QuestionKeyRecorderTests {
    private let now = Date(timeIntervalSinceReferenceDate: 9_000)
    private let leftCtrl = ModifierKey.leftControl.heldBit
    private let leftOpt = ModifierKey.leftOption.heldBit
    private let rightCmd = ModifierKey.rightCommand.heldBit

    private func mods(_ held: HeldModifiers) -> QuestionKeyInput { .modifiersChanged(held: held, time: now) }
    private func key(_ code: UInt16, held: HeldModifiers = [], repeat isRepeat: Bool = false) -> QuestionKeyInput {
        .keyDown(keyCode: code, held: held, isRepeat: isRepeat, time: now)
    }

    private func record(_ inputs: [QuestionKeyInput]) -> [QuestionKeyRecordingOutcome] {
        var recorder = QuestionKeyRecorder()
        return inputs.compactMap { recorder.handle($0) }
    }

    @Test func aLoneModifierIsRecordedWithItsSide() {
        #expect(record([mods(rightCmd), mods([])]) == [.recorded(.loneModifier(.rightCommand))])
        #expect(record([mods(leftCtrl), mods([])]) == [.recorded(.loneModifier(.leftControl))])
    }

    @Test func modifiersAloneAreRecordedWhenAllAreLetGo() {
        let both = leftCtrl.union(leftOpt)
        #expect(record([mods(leftCtrl), mods(both), mods(leftCtrl), mods([])])
                == [.recorded(.combination(modifiers: [.control, .option], keyCode: nil))])
    }

    @Test func modifiersPlusAKeyAreRecordedAtOnce() {
        let both = leftCtrl.union(leftOpt)
        #expect(record([mods(leftCtrl), mods(both), key(49, held: both)])
                == [.recorded(.combination(modifiers: [.control, .option], keyCode: 49))])
    }

    @Test func aBareRegularKeyIsRejected() {
        #expect(record([key(49)]) == [.rejected(.needsModifier)])
        #expect(record([key(0, held: .function)]) == [.rejected(.needsModifier)])
    }

    @Test func escapeOnItsOwnCancels() {
        #expect(record([key(53)]) == [.cancelled])
    }

    @Test func escapeWithAModifierIsAValidKey() {
        #expect(record([key(53, held: leftCtrl)]) == [.recorded(.combination(modifiers: [.control], keyCode: 53))])
    }

    @Test func bothSidesOfOneModifierAreRejected() {
        let bothShifts = ModifierKey.leftShift.heldBit.union(ModifierKey.rightShift.heldBit)
        #expect(record([mods(ModifierKey.leftShift.heldBit), mods(bothShifts), mods([])]) == [.rejected(.ambiguousModifiers)])
    }

    @Test func keyRepeatsAreIgnored() {
        #expect(record([key(49, repeat: true)]).isEmpty)
    }

    @Test func recorderResetsAfterAnOutcome() {
        #expect(record([mods(rightCmd), mods([]), mods(leftCtrl), mods([])])
                == [.recorded(.loneModifier(.rightCommand)), .recorded(.loneModifier(.leftControl))])
    }

    @Test func heldHintListsModifiersWhileRecording() {
        var recorder = QuestionKeyRecorder()
        _ = recorder.handle(mods(leftCtrl.union(leftOpt)))
        #expect(recorder.heldHint == "Control + Option")
        _ = recorder.handle(mods([]))
        #expect(recorder.heldHint == "")
    }
}
