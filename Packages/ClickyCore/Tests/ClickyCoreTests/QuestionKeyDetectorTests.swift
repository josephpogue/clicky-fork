import Foundation
import Testing
@testable import ClickyCore

/// Times are seconds from a fixed start. Key 54 is right Command, 55 is left Command.
struct QuestionKeyDetectorTests {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000)
    private func at(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }

    private func rightCommand(down: Bool, others: Bool = false, _ seconds: Double) -> KeyboardInputEvent {
        .modifierFlagsChanged(keyCode: 54, isTargetKeyDown: down, otherModifiersHeld: others, time: at(seconds))
    }
    private func leftCommand(down: Bool, _ seconds: Double) -> KeyboardInputEvent {
        .modifierFlagsChanged(keyCode: 55, isTargetKeyDown: false, otherModifiersHeld: down, time: at(seconds))
    }
    private func shift(down: Bool, targetDown: Bool, _ seconds: Double) -> KeyboardInputEvent {
        .modifierFlagsChanged(keyCode: 56, isTargetKeyDown: targetDown, otherModifiersHeld: down, time: at(seconds))
    }

    private func feed(_ events: [KeyboardInputEvent]) -> [LoneTap] {
        var detector = LoneModifierTapDetector()
        return events.compactMap { detector.handle($0) }
    }

    @Test func cleanTapIsReported() {
        let taps = feed([rightCommand(down: true, 0.0), rightCommand(down: false, 0.15)])
        #expect(taps == [LoneTap(pressedAt: at(0.0), releasedAt: at(0.15))])
    }

    @Test func keyPressedDuringHoldIsNotATap() {
        let taps = feed([
            rightCommand(down: true, 0.0),
            .keyDown(keyCode: 8, time: at(0.1)),
            rightCommand(down: false, 0.2),
        ])
        #expect(taps.isEmpty)
    }

    @Test func mouseClickDuringHoldIsNotATap() {
        let taps = feed([
            rightCommand(down: true, 0.0),
            .mouseButtonDown(time: at(0.1)),
            rightCommand(down: false, 0.2),
        ])
        #expect(taps.isEmpty)
    }

    @Test func leftCommandHeldFirstIsNotATap() {
        let taps = feed([
            leftCommand(down: true, 0.0),
            rightCommand(down: true, others: true, 0.1),
            rightCommand(down: false, others: true, 0.2),
            leftCommand(down: false, 0.3),
        ])
        #expect(taps.isEmpty)
    }

    @Test func aHoldJustUnderOneSecondIsATap() {
        let taps = feed([rightCommand(down: true, 0.0), rightCommand(down: false, 0.99)])
        #expect(taps == [LoneTap(pressedAt: at(0.0), releasedAt: at(0.99))])
    }

    @Test func aHoldOfExactlyOneSecondIsNotATap() {
        // The detector counts a hold only when it is shorter than the maximum, so 1.0 s is a long press.
        let taps = feed([rightCommand(down: true, 0.0), rightCommand(down: false, 1.0)])
        #expect(taps.isEmpty)
    }

    @Test func aHoldOfOnePointZeroOneSecondsIsNotATap() {
        let taps = feed([rightCommand(down: true, 0.0), rightCommand(down: false, 1.01)])
        #expect(taps.isEmpty)
    }

    @Test func aLoneLeftCommandTapIsNotATap() {
        let taps = feed([leftCommand(down: true, 0.0), leftCommand(down: false, 0.1)])
        #expect(taps.isEmpty)
    }

    @Test func longHoldIsNotATap() {
        let taps = feed([rightCommand(down: true, 0.0), rightCommand(down: false, 1.5)])
        #expect(taps.isEmpty)
    }

    @Test func shiftHeldFirstIsNotATap() {
        let taps = feed([
            shift(down: true, targetDown: false, 0.0),
            rightCommand(down: true, others: true, 0.1),
            rightCommand(down: false, others: true, 0.2),
        ])
        #expect(taps.isEmpty)
    }

    @Test func shiftPressedWhileTargetHeldIsNotATap() {
        let taps = feed([
            rightCommand(down: true, 0.0),
            shift(down: true, targetDown: true, 0.05),
            shift(down: false, targetDown: true, 0.1),
            rightCommand(down: false, 0.2),
        ])
        #expect(taps.isEmpty)
    }

    @Test func detectorRecoversAfterARejectedTap() {
        let taps = feed([
            rightCommand(down: true, 0.0),
            .keyDown(keyCode: 8, time: at(0.1)),
            rightCommand(down: false, 0.2),
            rightCommand(down: true, 1.0),
            rightCommand(down: false, 1.1),
        ])
        #expect(taps == [LoneTap(pressedAt: at(1.0), releasedAt: at(1.1))])
    }
}
