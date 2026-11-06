import Foundation
import Testing
@testable import ClickySpeech

@Suite struct SampleTimelineTests {
    private static let origin = Date(timeIntervalSince1970: 1_800_000_000)

    private static func isSameMoment(_ first: Date?, _ second: Date) -> Bool {
        guard let first else { return false }
        return abs(first.timeIntervalSince(second)) < 0.0001
    }

    @Test func nothingMapsBeforeAudioArrives() {
        let timeline = SampleTimeline()
        #expect(timeline.sampleZeroDate == nil)
        #expect(timeline.sampleIndex(for: Self.origin) == nil)
        #expect(timeline.date(forSampleIndex: 0) == nil)
    }

    @Test func theFirstChunkFixesWhereSampleZeroSits() {
        // A 0.1 s chunk (1_600 samples) that arrives at origin + 4 s was heard from origin + 3.9 s.
        var timeline = SampleTimeline()
        timeline.recordChunk(chunkSampleCount: 1_600, arrivedAt: Self.origin.addingTimeInterval(4))
        #expect(Self.isSameMoment(timeline.sampleZeroDate, Self.origin.addingTimeInterval(3.9)))
        // origin + 5.9 s is 2 s after sample 0: sample 32_000.
        #expect(timeline.sampleIndex(for: Self.origin.addingTimeInterval(5.9)) == 32_000)
        #expect(Self.isSameMoment(timeline.date(forSampleIndex: 32_000), Self.origin.addingTimeInterval(5.9)))
    }

    @Test func steadyChunksNeverReanchor() {
        var timeline = SampleTimeline()
        var cameAfterGap = false
        // Ten chunks of 0.1 s, each arriving 0.1 s after the last, one of them 0.05 s late.
        for chunkNumber in 1...10 {
            let jitter = chunkNumber == 5 ? 0.05 : 0.0
            cameAfterGap = timeline.recordChunk(
                chunkSampleCount: 1_600,
                arrivedAt: Self.origin.addingTimeInterval(Double(chunkNumber) * 0.1 + jitter)) || cameAfterGap
        }
        #expect(!cameAfterGap)
        #expect(timeline.anchors.count == 1)
    }

    @Test func aGapReanchorsSoLaterSamplesMapToTheirRealTime() {
        var timeline = SampleTimeline()
        // 1 s of audio heard from origin to origin + 1 s.
        timeline.recordChunk(chunkSampleCount: 16_000, arrivedAt: Self.origin.addingTimeInterval(1))
        // Then 10 s of nothing; the next 1 s chunk ends at origin + 12 s, so it was heard from origin + 11 s.
        let cameAfterGap = timeline.recordChunk(chunkSampleCount: 16_000, arrivedAt: Self.origin.addingTimeInterval(12))
        #expect(cameAfterGap)
        // Sample 16_000 is the first after the gap.
        #expect(Self.isSameMoment(timeline.date(forSampleIndex: 16_000), Self.origin.addingTimeInterval(11)))
        #expect(timeline.sampleIndex(for: Self.origin.addingTimeInterval(11.5)) == 24_000)
        // Before the gap the old anchor still holds.
        #expect(timeline.sampleIndex(for: Self.origin.addingTimeInterval(0.5)) == 8_000)
        // A time inside the gap maps to the first sample after it.
        #expect(timeline.sampleIndex(for: Self.origin.addingTimeInterval(6)) == 16_000)
    }

    @Test func aTimePastTheNewestAudioExtendsForward() {
        var timeline = SampleTimeline()
        timeline.recordChunk(chunkSampleCount: 16_000, arrivedAt: Self.origin.addingTimeInterval(1))
        // Sample 0 at origin; origin + 3 s is sample 48_000, which has not arrived yet.
        #expect(timeline.sampleIndex(for: Self.origin.addingTimeInterval(3)) == 48_000)
    }
}
