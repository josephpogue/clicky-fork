import Testing
@testable import ClickyCore

/// Measured on the test Mac after `tccutil reset Accessibility` in a running session: `AXIsProcessTrusted()` kept
/// returning true, the tap stayed enabled and a listen-only tap could still be made, but a tap that can remove
/// events could not be made at once. So the loss is read from that last check.
@Suite("Fix4Tap: telling that Accessibility was taken away")
struct Fix4TapTests {
    @Test("A removing tap that can no longer be made means Accessibility is gone, though the cached answer says trusted")
    func removingTapCannotBeMadeWhileCachedAnswerSaysTrusted() {
        #expect(KeyTapHealth.accessibilityEnded(
            wasTrusted: true, isTrusted: true, tapRemovesEvents: true, canMakeRemovingTap: false))
    }

    @Test("Everything still works: nothing ended")
    func everythingStillWorks() {
        #expect(!KeyTapHealth.accessibilityEnded(
            wasTrusted: true, isTrusted: true, tapRemovesEvents: true, canMakeRemovingTap: true))
    }

    @Test("A watch-only tap keeps working without Accessibility, so a failed removing tap alone says nothing")
    func watchOnlyTapIsNotLostWhenRemovingTapCannotBeMade() {
        #expect(!KeyTapHealth.accessibilityEnded(
            wasTrusted: true, isTrusted: true, tapRemovesEvents: false, canMakeRemovingTap: false))
    }

    @Test("The system's own answer going from trusted to not trusted still counts, whatever the tap is")
    func systemAnswerFlippingStillCounts() {
        #expect(KeyTapHealth.accessibilityEnded(
            wasTrusted: true, isTrusted: false, tapRemovesEvents: false, canMakeRemovingTap: true))
    }

    @Test("Untrusted both times with a watch-only tap is not a new loss")
    func alreadyUntrustedIsNotNew() {
        #expect(!KeyTapHealth.accessibilityEnded(
            wasTrusted: false, isTrusted: false, tapRemovesEvents: false, canMakeRemovingTap: false))
    }

    @Test("The loss is reported once: a failed rebuild is tried again, the second failure says lost, then nothing")
    func lossIsReportedOnce() {
        var health = KeyTapHealth()
        #expect(health.attemptFinished(succeeded: false) == .tryAgain)
        #expect(health.attemptFinished(succeeded: false) == .lost)
        #expect(health.attemptFinished(succeeded: false) == .alreadyLost)
    }
}
