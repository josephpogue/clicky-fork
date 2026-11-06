import Testing
@testable import ClickyCore

/// A flight's hold and return timers act only while their flight is the current one.
struct PointerFlightTokensTests {
    @Test func theFlightThatJustBeganIsCurrent() {
        var tokens = PointerFlightTokens()
        let first = tokens.begin()
        #expect(tokens.isCurrent(first))
    }

    @Test func finishingTheCurrentFlightEndsIt() {
        var tokens = PointerFlightTokens()
        let first = tokens.begin()
        let finished = tokens.finish(first)
        #expect(finished)
        #expect(!tokens.isCurrent(first))
    }

    @Test func aNewFlightDuringTheOldOnesHoldMakesTheOldFinishAndTimersNoOps() {
        var tokens = PointerFlightTokens()
        let old = tokens.begin()
        let new = tokens.begin()
        #expect(!tokens.isCurrent(old))
        let finished = tokens.finish(old)
        #expect(!finished)
        #expect(tokens.isCurrent(new))
    }

    @Test func aNewFlightDuringTheOldOnesFlyBackMakesTheOldFinishANoOp() {
        var tokens = PointerFlightTokens()
        let old = tokens.begin()
        _ = tokens.begin()
        // The old fly-back reaches the cursor and reports the end of the old flight.
        let finished = tokens.finish(old)
        #expect(!finished)
    }

    @Test func stopDuringAHoldMakesTheHoldTimerANoOp() {
        var tokens = PointerFlightTokens()
        let flight = tokens.begin()
        tokens.cancel()
        #expect(!tokens.isCurrent(flight))
        let finished = tokens.finish(flight)
        #expect(!finished)
    }

    @Test func aFlightBeganAfterStopIsCurrent() {
        var tokens = PointerFlightTokens()
        _ = tokens.begin()
        tokens.cancel()
        let next = tokens.begin()
        #expect(tokens.isCurrent(next))
    }
}
