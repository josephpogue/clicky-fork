import Foundation
import Testing
@testable import ClickyCore

/// KeyOverlap against what the detectors really do, for keys with no regular key. A pair overlaps when one
/// continuous hold (modifiers pressed and let go one at a time, never all up) makes both detectors fire.
struct KeyOverlapPairTests {
    private typealias Step = (key: ModifierKey, goesDown: Bool)

    private static func inputs(for steps: [Step]) -> [QuestionKeyInput] {
        var held: HeldModifiers = []
        var result: [QuestionKeyInput] = []
        for index in 0..<steps.count {
            let step = steps[index]
            if step.goesDown { held.formUnion(step.key.heldBit) } else { held.subtract(step.key.heldBit) }
            result.append(.modifiersChanged(held: held, time: Date(timeIntervalSinceReferenceDate: 9_000 + Double(index) * 0.01)))
        }
        return result
    }

    private func bothFire(_ first: QuestionKeySpec, _ second: QuestionKeySpec, _ steps: [Step]) -> Bool {
        var firstDetector = QuestionKeyDetector(spec: first)
        var secondDetector = QuestionKeyDetector(spec: second)
        var firstFired = false
        var secondFired = false
        for input in Self.inputs(for: steps) {
            if firstDetector.handle(input).tap != nil { firstFired = true }
            if secondDetector.handle(input).tap != nil { secondFired = true }
        }
        return firstFired && secondFired
    }

    private func overlaps(_ a: QuestionKeySpec, _ b: QuestionKeySpec) -> Bool {
        let both = KeyOverlap.canFireBoth(a, b)
        #expect(both == KeyOverlap.canFireBoth(b, a))
        return both
    }

    private func down(_ key: ModifierKey) -> Step { (key, true) }
    private func up(_ key: ModifierKey) -> Step { (key, false) }

    private func families(_ set: Set<ModifierFamily>) -> QuestionKeySpec { .combination(modifiers: set, keyCode: nil) }
    private func sided(_ set: Set<ModifierKey>) -> QuestionKeySpec { .sidedCombination(modifiers: set, keyCode: nil) }

    // MARK: One test per pair kind

    @Test func loneAgainstLoneOverlapsOnTheSameKeyOnly() {
        #expect(overlaps(.loneModifier(.rightCommand), .loneModifier(.rightCommand)))
        #expect(overlaps(.loneModifier(.rightCommand), sided([.rightCommand])))
        #expect(!overlaps(.loneModifier(.rightCommand), .loneModifier(.leftCommand)))
        #expect(!overlaps(.loneModifier(.rightCommand), sided([.leftCommand])))
    }

    @Test func loneAgainstSeveralModifiersNeverOverlaps() {
        // A lone tap needs every other modifier up for the whole press; a longer chord spoils it.
        let chords: [QuestionKeySpec] = [families([.command, .option]), sided([.rightCommand, .leftOption]),
                                         sided([.leftCommand, .rightCommand])]
        for chord in chords { #expect(!overlaps(.loneModifier(.rightCommand), chord)) }
        let holds: [[Step]] = [
            [down(.rightCommand), down(.leftOption), up(.leftOption), up(.rightCommand)],
            [down(.leftOption), down(.rightCommand), up(.rightCommand), up(.leftOption)],
        ]
        for hold in holds {
            #expect(!bothFire(.loneModifier(.rightCommand), sided([.rightCommand, .leftOption]), hold))
        }
    }

    @Test func familiesAgainstFamiliesOverlapWhenOneContainsTheOther() {
        let commandOption = families([.command, .option])
        #expect(overlaps(commandOption, families([.command, .option])))
        #expect(overlaps(commandOption, families([.command, .option, .shift])))
        #expect(!overlaps(commandOption, families([.command, .shift])))
        #expect(!overlaps(commandOption, families([.shift, .control])))
        // The wider key fires on the first release, then the narrower one is rebuilt and let go.
        let hold: [Step] = [down(.leftCommand), down(.leftOption), down(.leftShift), up(.leftShift), up(.leftOption)]
        #expect(!bothFire(commandOption, families([.command, .option, .shift]), hold))
        let chained: [Step] = [down(.leftCommand), down(.leftOption), down(.leftShift), up(.leftShift),
                               up(.leftOption), down(.leftOption), up(.leftOption)]
        #expect(!bothFire(commandOption, families([.command, .option, .shift]), chained))
        let narrowerFirst: [Step] = [down(.leftCommand), down(.leftOption), up(.leftOption), down(.leftOption),
                                     down(.leftShift), up(.leftShift)]
        #expect(bothFire(commandOption, families([.command, .option, .shift]), narrowerFirst))
    }

    @Test func familiesAgainstSidedKeysOverlapWhenOneContainsTheOther() {
        let commandOption = families([.command, .option])
        // The case from the review: both command keys held, then option added after one command key is let go.
        let bothCommands = sided([.leftCommand, .rightCommand])
        #expect(overlaps(commandOption, bothCommands))
        let hold: [Step] = [down(.leftCommand), down(.rightCommand), up(.rightCommand), down(.leftOption), up(.leftOption),
                            up(.leftCommand)]
        #expect(bothFire(commandOption, bothCommands, hold))
        #expect(overlaps(commandOption, sided([.rightCommand, .leftOption])))
        #expect(overlaps(families([.command, .option, .shift]), sided([.rightCommand, .leftOption])))
        #expect(!overlaps(commandOption, sided([.rightCommand, .leftShift])))
        #expect(!overlaps(families([.command, .shift]), sided([.rightCommand, .leftOption])))
    }

    @Test func sidedAgainstSidedOverlapWhenOneKeySetContainsTheOther() {
        #expect(overlaps(sided([.leftCommand, .rightCommand]), sided([.leftCommand, .rightCommand])))
        #expect(overlaps(sided([.leftCommand, .rightCommand]), sided([.leftCommand, .rightCommand, .leftOption])))
        #expect(!overlaps(sided([.leftCommand, .rightOption]), sided([.rightCommand, .leftOption, .leftShift])))
        #expect(!overlaps(sided([.leftCommand, .leftOption]), sided([.rightCommand, .leftOption])))
        let hold: [Step] = [down(.leftCommand), down(.rightCommand), up(.rightCommand), down(.rightCommand),
                            down(.leftOption), up(.leftOption)]
        #expect(bothFire(sided([.leftCommand, .rightCommand]), sided([.leftCommand, .rightCommand, .leftOption]), hold))
    }

    // MARK: Every hold against every pair

    /// All keys with no regular key over four modifier keys (Command both sides, Option left, Shift left).
    private static let universe: [ModifierKey] = [.leftCommand, .rightCommand, .leftOption, .leftShift]

    private static func subsets<T>(of items: [T], minimumSize: Int) -> [[T]] {
        var result: [[T]] = []
        for mask in 1..<(1 << items.count) {
            var subset: [T] = []
            for index in 0..<items.count where mask & (1 << index) != 0 { subset.append(items[index]) }
            if subset.count >= minimumSize { result.append(subset) }
        }
        return result
    }

    private static var allKeylessSpecs: [QuestionKeySpec] {
        var specs: [QuestionKeySpec] = universe.map { .loneModifier($0) }
        let familyList: [ModifierFamily] = [.command, .option, .shift]
        for subset in subsets(of: familyList, minimumSize: 2) { specs.append(.combination(modifiers: Set(subset), keyCode: nil)) }
        for subset in subsets(of: universe, minimumSize: 2) { specs.append(.sidedCombination(modifiers: Set(subset), keyCode: nil)) }
        return specs
    }

    /// Walks every continuous hold of up to `maxDepth` modifier changes and returns, per pair of specs, whether
    /// some hold made both fire.
    private static func pairsThatFireTogether(specs: [QuestionKeySpec], maxDepth: Int) -> Set<[Int]> {
        var together: Set<[Int]> = []
        func walk(detectors: [QuestionKeyDetector], held: HeldModifiers, fired: [Bool], depth: Int) {
            if depth == maxDepth { return }
            for key in universe {
                var nextHeld = held
                if held.contains(key.heldBit) { nextHeld.subtract(key.heldBit) } else { nextHeld.formUnion(key.heldBit) }
                // Everything up ends the hold; the next press starts a new one.
                if nextHeld.isEmpty { continue }
                let input = QuestionKeyInput.modifiersChanged(
                    held: nextHeld, time: Date(timeIntervalSinceReferenceDate: 9_000 + Double(depth) * 0.01))
                var nextDetectors = detectors
                var nextFired = fired
                for index in 0..<nextDetectors.count where nextDetectors[index].handle(input).tap != nil { nextFired[index] = true }
                for first in 0..<nextFired.count where nextFired[first] {
                    for second in (first + 1)..<max(first + 1, nextFired.count) where nextFired[second] {
                        together.insert([first, second])
                    }
                }
                walk(detectors: nextDetectors, held: nextHeld, fired: nextFired, depth: depth + 1)
            }
        }
        for key in universe {
            let input = QuestionKeyInput.modifiersChanged(held: key.heldBit, time: Date(timeIntervalSinceReferenceDate: 8_999))
            var detectors = specs.map { QuestionKeyDetector(spec: $0) }
            var fired = [Bool](repeating: false, count: specs.count)
            for index in 0..<detectors.count where detectors[index].handle(input).tap != nil { fired[index] = true }
            walk(detectors: detectors, held: key.heldBit, fired: fired, depth: 1)
        }
        return together
    }

    @Test func noHoldFiresTwoKeysThatKeyOverlapSaysAreApart() {
        let specs = Self.allKeylessSpecs
        let together = Self.pairsThatFireTogether(specs: specs, maxDepth: 8)
        var missed: [String] = []
        for pair in together where !KeyOverlap.canFireBoth(specs[pair[0]], specs[pair[1]]) {
            missed.append("\(specs[pair[0]].displayName) and \(specs[pair[1]].displayName)")
        }
        #expect(missed.sorted() == [])
    }

    @Test func keyOverlapRefusesNothingThatNoHoldCanFire() {
        let specs = Self.allKeylessSpecs
        let together = Self.pairsThatFireTogether(specs: specs, maxDepth: 9)
        var tooCareful: [String] = []
        for first in 0..<specs.count {
            for second in first..<specs.count where KeyOverlap.canFireBoth(specs[first], specs[second]) {
                if !together.contains([first, second]) && first != second {
                    tooCareful.append("\(specs[first].displayName) and \(specs[second].displayName)")
                }
            }
        }
        #expect(tooCareful.sorted() == [])
    }
}
