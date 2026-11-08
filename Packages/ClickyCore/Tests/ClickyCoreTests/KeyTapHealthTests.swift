import Foundation
import Testing
@testable import ClickyCore

/// When the key tap counts as lost: one retry, then one report.
struct KeyTapHealthTests {
    @Test func aWorkingTapNeverReportsAnything() {
        var health = KeyTapHealth()
        #expect(health.attemptFinished(succeeded: true) == .running)
        #expect(!health.isLost)
    }

    @Test func aFailedReinstallIsTriedOnceMoreAndThenReportedLostOnce() {
        var health = KeyTapHealth()
        #expect(health.attemptFinished(succeeded: false) == .tryAgain)
        #expect(!health.isLost)
        #expect(health.attemptFinished(succeeded: false) == .lost)
        #expect(health.isLost)
        // Later failures say nothing more.
        #expect(health.attemptFinished(succeeded: false) == .alreadyLost)
        #expect(health.attemptFinished(succeeded: false) == .alreadyLost)
    }

    @Test func aTapThatComesBackOnTheRetryIsNotLost() {
        var health = KeyTapHealth()
        #expect(health.attemptFinished(succeeded: false) == .tryAgain)
        #expect(health.attemptFinished(succeeded: true) == .running)
        #expect(!health.isLost)
        // The next trouble starts counting from zero.
        #expect(health.attemptFinished(succeeded: false) == .tryAgain)
    }

    @Test func aTapLostAgainAfterRecoveringIsReportedAgain() {
        var health = KeyTapHealth()
        _ = health.attemptFinished(succeeded: false)
        #expect(health.attemptFinished(succeeded: false) == .lost)
        #expect(health.attemptFinished(succeeded: true) == .running)
        _ = health.attemptFinished(succeeded: false)
        #expect(health.attemptFinished(succeeded: false) == .lost)
    }

    @Test func theNoticeNamesBothKeysAndWhatToDo() {
        let text = KeyTapNotice.lost
        #expect(text.contains("question key"))
        #expect(text.contains("chat key"))
        #expect(text.contains("Accessibility"))
        #expect(text.contains("System Settings"))
        #expect(text.contains("stop and start the session"))
        #expect(!text.contains("\u{2014}"))
    }
}
