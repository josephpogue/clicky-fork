import Foundation
import Testing

@testable import ClickyCore

@Suite("Session Start waits for the index only briefly")
struct BrainServiceStartWaitTests {
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    @Test func aRefreshThatNeverFinishesReleasesStartAtTheCap() async {
        let release = Flag()
        let started = Date()
        await BrainServiceStartWait.waitUntilDone(orAfter: 0.3) {
            // A first build of a big folder: it ends only when the test lets it.
            while !release.isSet { try? await Task.sleep(nanoseconds: 20_000_000) }
        }
        let waited = Date().timeIntervalSince(started)
        release.set()
        // At least the cap (it did not return early); the upper bound only proves it did not wait for the build.
        #expect(waited >= 0.25 && waited < 10)
    }

    @Test func aRefreshThatIsAlreadyCurrentReturnsAtOnce() async {
        let started = Date()
        await BrainServiceStartWait.waitUntilDone(orAfter: 20) {}
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test func theRefreshKeepsRunningAfterStartIsReleased() async throws {
        let letItFinish = Flag()
        let finished = Flag()
        await BrainServiceStartWait.waitUntilDone(orAfter: 0.1) {
            while !letItFinish.isSet { try? await Task.sleep(nanoseconds: 20_000_000) }
            finished.set()
        }
        #expect(!finished.isSet)
        letItFinish.set()
        for _ in 0..<200 where !finished.isSet { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(finished.isSet)
    }

    @Test func theDefaultCapIsOneAndAHalfSeconds() {
        #expect(BrainServiceStartWait.defaultSeconds == 1.5)
    }
}
