import Foundation
import Testing
@testable import ClickyCore

/// The chat key: default right Command + comma, sides told apart, removed from the front app, and refused
/// when a press could also fire the question key.
struct ChatKeyTests {
    private let start = Date(timeIntervalSinceReferenceDate: 7_000)
    private func at(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }

    private let rightCmd = ModifierKey.rightCommand.heldBit
    private let leftCmd = ModifierKey.leftCommand.heldBit
    private let leftShift = ModifierKey.leftShift.heldBit
    private let leftOpt = ModifierKey.leftOption.heldBit
    private let comma: UInt16 = 43

    private func mods(_ held: HeldModifiers, _ seconds: Double) -> QuestionKeyInput {
        .modifiersChanged(held: held, time: at(seconds))
    }
    private func down(_ code: UInt16, held: HeldModifiers, repeat isRepeat: Bool = false, _ seconds: Double) -> QuestionKeyInput {
        .keyDown(keyCode: code, held: held, isRepeat: isRepeat, time: at(seconds))
    }
    private func up(_ code: UInt16, _ seconds: Double) -> QuestionKeyInput { .keyUp(keyCode: code, time: at(seconds)) }

    private func run(_ inputs: [QuestionKeyInput]) -> [QuestionKeyDetection] {
        var detector = QuestionKeyDetector(spec: .defaultChatKey)
        return inputs.map { detector.handle($0) }
    }

    // MARK: Matching

    @Test func rightCommandCommaFiresOnceAndIsRemovedWithItsRepeatsAndRelease() {
        let results = run([mods(rightCmd, 0), down(comma, held: rightCmd, 0.1), down(comma, held: rightCmd, repeat: true, 0.2),
                           up(comma, 0.3)])
        #expect(results.map { $0.tap != nil } == [false, true, false, false])
        #expect(results.map(\.swallowEvent) == [false, true, true, true])
    }

    @Test func leftCommandCommaPassesThrough() {
        let results = run([mods(leftCmd, 0), down(comma, held: leftCmd, 0.1), up(comma, 0.2)])
        #expect(results.allSatisfy { $0.tap == nil && !$0.swallowEvent })
    }

    @Test func bothCommandsAndCommaPassesThrough() {
        let both = rightCmd.union(leftCmd)
        let results = run([down(comma, held: both, 0.1), up(comma, 0.2)])
        #expect(results.allSatisfy { $0.tap == nil && !$0.swallowEvent })
    }

    @Test func rightCommandWithLeftShiftAndCommaPassesThrough() {
        let results = run([down(comma, held: rightCmd.union(leftShift), 0.1), up(comma, 0.2)])
        #expect(results.allSatisfy { $0.tap == nil && !$0.swallowEvent })
    }

    @Test func aPlainCommaPassesThrough() {
        let results = run([down(comma, held: [], 0.1), up(comma, 0.2)])
        #expect(results.allSatisfy { $0.tap == nil && !$0.swallowEvent })
    }

    @Test func functionKeyIsIgnored() {
        let results = run([down(comma, held: rightCmd.union(.function), 0.1)])
        #expect(results[0].tap != nil && results[0].swallowEvent)
    }

    @Test func theReleaseIsRemovedEvenIfTheModifierWasLetGoFirst() {
        let results = run([down(comma, held: rightCmd, 0.1), mods([], 0.2), up(comma, 0.3)])
        #expect(results[0].tap != nil)
        #expect(results[2].swallowEvent)
    }

    @Test func aRepeatAfterTheModifierWasLetGoStaysHidden() {
        let results = run([down(comma, held: rightCmd, 0.1), mods([], 0.2), down(comma, held: [], repeat: true, 0.3)])
        #expect(results[2].swallowEvent && results[2].tap == nil)
    }

    @Test func aSecondPressFiresAgain() {
        let results = run([down(comma, held: rightCmd, 0.1), up(comma, 0.2), down(comma, held: rightCmd, 0.5), up(comma, 0.6)])
        #expect(results.compactMap(\.tap).count == 2)
    }

    @Test func swallowsAKeyOnlyWhenItHasARegularKey() {
        #expect(QuestionKeySpec.defaultChatKey.swallowsAKey)
        #expect(!QuestionKeySpec.sidedCombination(modifiers: [.rightCommand, .leftOption], keyCode: nil).swallowsAKey)
    }

    // MARK: Sided modifiers only and lone

    @Test func sidedModifiersOnlyFiresWhenLetGoAndIgnoresTheOtherSide() {
        let spec = QuestionKeySpec.sidedCombination(modifiers: [.rightCommand, .leftOption], keyCode: nil)
        var detector = QuestionKeyDetector(spec: spec)
        let good = [mods(rightCmd, 0), mods(rightCmd.union(leftOpt), 0.1), mods([], 0.2)].map { detector.handle($0) }
        #expect(good.compactMap(\.tap).count == 1)
        detector = QuestionKeyDetector(spec: spec)
        let wrongSide = [mods(leftCmd, 0), mods(leftCmd.union(leftOpt), 0.1), mods([], 0.2)].map { detector.handle($0) }
        #expect(wrongSide.compactMap(\.tap).isEmpty)
    }

    @Test func aSingleSidedModifierIsALoneTap() {
        var detector = QuestionKeyDetector(spec: .sidedCombination(modifiers: [.leftOption], keyCode: nil))
        let tapped = [mods(leftOpt, 0), mods([], 0.1)].map { detector.handle($0) }
        #expect(tapped.compactMap(\.tap).count == 1)
        let chord = [mods(leftOpt, 1), down(8, held: leftOpt, 1.05), mods([], 1.1)].map { detector.handle($0) }
        #expect(chord.compactMap(\.tap).isEmpty)
    }

    // MARK: Both keys in one stream

    @Test func chatKeyFiresAndSpoilsTheQuestionKeyTapOfSharedRightCommand() {
        var detector = TwoKeyDetector(questionKey: .default, chatKey: .defaultChatKey)
        let results = [mods(rightCmd, 0), down(comma, held: rightCmd, 0.1), up(comma, 0.2), mods([], 0.3)].map { detector.handle($0) }
        #expect(results.filter(\.chatPressed).count == 1)
        #expect(results.compactMap(\.questionTap).isEmpty)
    }

    @Test func aLoneRightCommandTapStillStartsAQuestionAndNotTheChat() {
        var detector = TwoKeyDetector(questionKey: .default, chatKey: .defaultChatKey)
        let results = [mods(rightCmd, 0), mods([], 0.1)].map { detector.handle($0) }
        #expect(results.compactMap(\.questionTap).count == 1)
        #expect(results.allSatisfy { !$0.chatPressed && !$0.swallowEvent })
    }

    @Test func theTapMustRemoveEventsWhenEitherKeyDoes() {
        #expect(TwoKeyDetector(questionKey: .default, chatKey: .defaultChatKey).swallowsAKey)
        #expect(!TwoKeyDetector(questionKey: .default, chatKey: .sidedCombination(modifiers: [.leftOption], keyCode: nil)).swallowsAKey)
        #expect(TwoKeyDetector(questionKey: .combination(modifiers: [.control], keyCode: 49), chatKey: .sidedCombination(modifiers: [.leftOption], keyCode: nil)).swallowsAKey)
    }

    // MARK: Saved form and name

    @Test func defaultChatKeyReadsRightCommandComma() {
        #expect(QuestionKeySpec.defaultChatKey.displayName == "Right \u{2318} ,")
    }

    @Test func sidedKeysRoundTrip() {
        let specs: [QuestionKeySpec] = [.defaultChatKey,
                                        .sidedCombination(modifiers: [.leftOption, .rightShift], keyCode: nil),
                                        .sidedCombination(modifiers: [.leftControl, .rightCommand], keyCode: 49)]
        for spec in specs { #expect(QuestionKeySpec(encoded: spec.encoded) == spec) }
        #expect(QuestionKeySpec.defaultChatKey.encoded == "sided:rightCommand:43")
        #expect(QuestionKeySpec.sidedCombination(modifiers: [.leftOption, .rightShift], keyCode: nil).encoded == "sided:leftOption,rightShift:")
    }

    @Test func sidedDisplayNameListsEachSide() {
        let spec = QuestionKeySpec.sidedCombination(modifiers: [.rightCommand, .leftOption], keyCode: 49)
        #expect(spec.displayName == "Left \u{2325} Right \u{2318} Space")
    }

    @Test func damagedSavedFormsDecodeToNil() {
        for text in ["garbage", "sided", "sided:rightCommand", "sided::43", "sided:nope:43", "sided:rightCommand:x", ""] {
            #expect(QuestionKeySpec(encoded: text) == nil)
        }
    }

    // MARK: Overlap (q = question key, c = chat key)

    private func overlaps(_ q: QuestionKeySpec, _ c: QuestionKeySpec) -> Bool {
        let both = KeyOverlap.canFireBoth(q, c)
        #expect(both == KeyOverlap.canFireBoth(c, q))
        return both
    }

    @Test func defaultKeysDoNotOverlap() {
        #expect(!overlaps(.loneModifier(.rightCommand), .defaultChatKey))
    }

    @Test func loneKeysOverlapOnTheSameSideOnly() {
        #expect(overlaps(.loneModifier(.rightCommand), .sidedCombination(modifiers: [.rightCommand], keyCode: nil)))
        #expect(!overlaps(.loneModifier(.rightCommand), .sidedCombination(modifiers: [.leftCommand], keyCode: nil)))
    }

    @Test func keyedCombinationsOverlapWhenTheSameKeyAndHeldSetFit() {
        let q = QuestionKeySpec.combination(modifiers: [.command], keyCode: 40)
        #expect(overlaps(q, .sidedCombination(modifiers: [.rightCommand], keyCode: 40)))
        #expect(!overlaps(q, .sidedCombination(modifiers: [.leftCommand, .leftShift], keyCode: 40)))
        #expect(!overlaps(q, .sidedCombination(modifiers: [.rightCommand], keyCode: 41)))
        #expect(overlaps(.combination(modifiers: [.command], keyCode: 43), .defaultChatKey))
    }

    @Test func modifiersOnlyKeysOverlapWhenTheSameHeldSetCompletesBoth() {
        let q = QuestionKeySpec.combination(modifiers: [.command, .option], keyCode: nil)
        #expect(overlaps(q, .sidedCombination(modifiers: [.rightCommand, .leftOption], keyCode: nil)))
        #expect(!overlaps(q, .sidedCombination(modifiers: [.rightCommand, .leftShift], keyCode: nil)))
    }

    @Test func aRegularKeyKeyNeverOverlapsAModifiersOnlyOrLoneKey() {
        // A regular key going down while modifiers are held spoils a lone tap and a modifiers-only press.
        #expect(!overlaps(.loneModifier(.rightCommand), .defaultChatKey))
        #expect(!overlaps(.combination(modifiers: [.command, .option], keyCode: nil), .sidedCombination(modifiers: [.rightCommand, .leftOption], keyCode: 43)))
        #expect(!overlaps(.combination(modifiers: [.command], keyCode: 43), .sidedCombination(modifiers: [.rightCommand, .leftOption], keyCode: nil)))
    }

    @Test func refusalTextNamesTheOtherKey() {
        let q = QuestionKeySpec.loneModifier(.rightCommand)
        let c = QuestionKeySpec.sidedCombination(modifiers: [.rightCommand], keyCode: nil)
        #expect(KeyOverlap.refusalForChatKey(c, question: q)?.contains("Right Command") == true)
        #expect(KeyOverlap.refusalForQuestionKey(q, chat: c)?.contains("Right \u{2318}") == true)
        #expect(KeyOverlap.refusalForChatKey(.defaultChatKey, question: q) == nil)
    }

    // MARK: Recording a sided key

    private func record(_ inputs: [QuestionKeyInput]) -> [QuestionKeyRecordingOutcome] {
        var recorder = QuestionKeyRecorder(sided: true)
        return inputs.compactMap { recorder.handle($0) }
    }

    @Test func recordingKeepsTheSideOfEveryHeldModifier() {
        #expect(record([mods(rightCmd, 0), down(comma, held: rightCmd, 0.1)]) == [.recorded(.defaultChatKey)])
        let both = leftOpt.union(rightCmd)
        #expect(record([mods(leftOpt, 0), mods(both, 0.1), down(49, held: both, 0.2)])
                == [.recorded(.sidedCombination(modifiers: [.leftOption, .rightCommand], keyCode: 49))])
    }

    @Test func recordingModifiersAloneWaitsForLetGo() {
        let both = leftOpt.union(rightCmd)
        #expect(record([mods(leftOpt, 0), mods(both, 0.1), mods([], 0.2)])
                == [.recorded(.sidedCombination(modifiers: [.leftOption, .rightCommand], keyCode: nil))])
    }

    @Test func recordingARegularKeyAloneIsRefusedAndEscapeCancels() {
        #expect(record([down(comma, held: [], 0)]) == [.rejected(.needsModifier)])
        #expect(record([down(53, held: [], 0)]) == [.cancelled])
    }
}
