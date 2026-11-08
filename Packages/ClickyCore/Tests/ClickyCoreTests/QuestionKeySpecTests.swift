import Foundation
import Testing
@testable import ClickyCore

struct QuestionKeySpecTests {
    @Test func defaultIsRightCommand() {
        #expect(QuestionKeySpec.default == .loneModifier(.rightCommand))
        #expect(QuestionKeySpec.default.displayName == "Right Command")
    }

    @Test(arguments: [
        QuestionKeySpec.loneModifier(.rightCommand),
        .loneModifier(.leftControl),
        .loneModifier(.rightOption),
        .combination(modifiers: [.control, .option], keyCode: 49),
        .combination(modifiers: [.control, .option], keyCode: nil),
        .combination(modifiers: [.command], keyCode: 0),
    ])
    func encodingRoundTrips(spec: QuestionKeySpec) {
        #expect(QuestionKeySpec(encoded: spec.encoded) == spec)
    }

    @Test func encodedFormIsStable() {
        #expect(QuestionKeySpec.default.encoded == "lone:54")
        #expect(QuestionKeySpec.combination(modifiers: [.option, .control], keyCode: 49).encoded == "combo:control,option:49")
        #expect(QuestionKeySpec.combination(modifiers: [.shift, .command], keyCode: nil).encoded == "combo:shift,command:-")
    }

    @Test(arguments: ["", "lone", "lone:0", "lone:abc", "combo:control:", "combo::49", "combo:control:-", "combo:bogus,option:49", "key:49", "combo:control,option"])
    func damagedValuesAreRejected(text: String) {
        #expect(QuestionKeySpec(encoded: text) == nil)
    }

    @Test func aBareRegularKeyIsNotAKey() {
        #expect(QuestionKeySpec.makeCombination(modifiers: [], keyCode: 49) == nil)
    }

    @Test func oneModifierWithNoKeyIsNotACombination() {
        #expect(QuestionKeySpec.makeCombination(modifiers: [.control], keyCode: nil) == nil)
        #expect(QuestionKeySpec.makeCombination(modifiers: [.control, .option], keyCode: nil) != nil)
    }

    @Test func displayNamesFollowMacOrder() {
        #expect(QuestionKeySpec.combination(modifiers: [.command, .control], keyCode: 49).displayName == "Control + Command + Space")
        #expect(QuestionKeySpec.combination(modifiers: [.option, .control], keyCode: nil).displayName == "Control + Option")
        #expect(QuestionKeySpec.loneModifier(.leftControl).displayName == "Left Control")
        #expect(QuestionKeySpec.combination(modifiers: [.shift], keyCode: 200).displayName == "Shift + Key 200")
    }

    @Test func onlyKeyCombinationsSwallowAKey() {
        #expect(!QuestionKeySpec.default.swallowsAKey)
        #expect(!QuestionKeySpec.combination(modifiers: [.control, .option], keyCode: nil).swallowsAKey)
        #expect(QuestionKeySpec.combination(modifiers: [.control], keyCode: 49).swallowsAKey)
    }

    @Test func heldModifiersReadDeviceBitsAndIgnoreTheRest() {
        // Right Command (0x10) plus the generic Command flag bit (0x100000) and a caps lock bit.
        let held = HeldModifiers(eventFlagBits: 0x10 | 0x100000 | 0x10000)
        #expect(held.keys == [.rightCommand])
        #expect(held.families == [.command])
        #expect(HeldModifiers(eventFlagBits: 0x800000).contains(.function))
    }

    @Test func everyModifierKeyHasItsOwnBitAndCode() {
        #expect(Set(ModifierKey.allCases.map(\.keyCode)).count == ModifierKey.allCases.count)
        #expect(Set(ModifierKey.allCases.map { $0.heldBit.rawValue }).count == ModifierKey.allCases.count)
        for key in ModifierKey.allCases { #expect(ModifierKey(keyCode: key.keyCode) == key) }
    }
}
