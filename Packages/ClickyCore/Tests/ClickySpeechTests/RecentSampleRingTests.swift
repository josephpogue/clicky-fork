import Testing
@testable import ClickySpeech

@Suite struct RecentSampleRingTests {
    /// Every sample holds its own absolute index, so a slice shows exactly which samples came back.
    private func ringHolding(sampleCount: Int, capacity: Int) -> RecentSampleRing {
        var ring = RecentSampleRing(capacity: capacity)
        ring.append((0..<sampleCount).map { Float($0) })
        return ring
    }

    @Test func holdsEverythingUntilItPassesCapacityPlusOneSecond() {
        // 20_000 capacity + 16_000 slack = 36_000; exactly that many are still all held.
        let ring = ringHolding(sampleCount: 36_000, capacity: 20_000)
        #expect(ring.firstIndex == 0)
        #expect(ring.endIndex == 36_000)
    }

    @Test func wrapsAtCapacityAndKeepsTheNewestSamples() {
        // 36_001 samples pass the 36_000 limit: 36_001 - 20_000 = 16_001 fall off the front.
        let ring = ringHolding(sampleCount: 36_001, capacity: 20_000)
        #expect(ring.firstIndex == 16_001)
        #expect(ring.endIndex == 36_001)
        let held = ring.slice(from: 0, to: 40_000)
        #expect(held.count == 20_000)
        #expect(held.first == 16_001)
        #expect(held.last == 36_000)
    }

    @Test func aRangeOlderThanTheRingReturnsOnlyWhatIsStillHeld() {
        let ring = ringHolding(sampleCount: 36_001, capacity: 20_000)
        // 15_998..<16_004 straddles the edge: indexes 16_001, 16_002, 16_003 are held.
        #expect(ring.slice(from: 15_998, to: 16_004) == [16_001, 16_002, 16_003])
        // Entirely older than the ring: nothing.
        #expect(ring.slice(from: 0, to: 16_001).isEmpty)
    }

    @Test func aRangeBeyondTheNewestSampleIsClampedToIt() {
        let ring = ringHolding(sampleCount: 100, capacity: 20_000)
        #expect(ring.slice(from: 98, to: 150) == [98, 99])
        #expect(ring.slice(from: 100, to: 150).isEmpty)
    }
}
