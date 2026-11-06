import Foundation
import Testing
@testable import ClickyCore

struct QuestionKeyStateMachineTests {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000)
    private func at(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }
    private func tap(_ pressed: Double, _ released: Double) -> LoneTap {
        LoneTap(pressedAt: at(pressed), releasedAt: at(released))
    }

    @Test func twoTapsAskAQuestionAndAThirdStartsAnother() {
        var machine = QuestionKeyStateMachine()
        #expect(machine.handleLoneTap(tap(0.0, 0.15)) == .questionStarted(at: at(0.15)))
        #expect(machine.handleLoneTap(tap(4.9, 5.0)) == .sendQuestion(speechFrom: at(0.15), speechTo: at(4.9)))
        #expect(machine.handleLoneTap(tap(8.0, 8.1)) == .questionStarted(at: at(8.1)))
    }

    @Test func resetForgetsAFirstTap() {
        var machine = QuestionKeyStateMachine()
        _ = machine.handleLoneTap(tap(0.0, 0.15))
        machine.reset()
        #expect(machine.handleLoneTap(tap(4.9, 5.0)) == .questionStarted(at: at(5.0)))
    }
}
