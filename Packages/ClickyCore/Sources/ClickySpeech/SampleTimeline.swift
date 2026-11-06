import Foundation

/// Maps wall-clock times to sample indexes and back.
///
/// The timeline is anchored to the audio itself, never to when the session was asked to start:
/// the first chunk to arrive fixes where sample 0 sits on the clock, so the delay of a microphone
/// permission prompt cannot shift anything. A chunk that arrives well after the previous one ended
/// (sleep and wake, a device switch, a stalled source) opens a new anchor, so samples after the
/// gap map to the time they were really heard. Samples stay contiguous across a gap; only the
/// clock jumps.
///
/// A chunk's audio is taken to end at the moment it arrives, which is how a microphone tap
/// behaves (the callback fires once the buffer is full). That is off by at most one buffer
/// (about 85 ms at 48 kHz), the jitter of the callback.
struct SampleTimeline: Sendable {
    static let sampleRate = 16_000.0
    /// How much later than expected a chunk may start before the clock is re-anchored. Ordinary
    /// callback jitter is a few milliseconds, so anything near this is a real interruption.
    static let gapThresholdSeconds = 0.25

    struct Anchor: Sendable, Equatable {
        /// Index of the first sample after this anchor was set.
        let firstSampleIndex: Int
        /// Wall-clock time at which that sample was heard.
        let date: Date
    }

    private(set) var anchors: [Anchor] = []
    /// Index of the next sample to arrive; also the count of samples delivered so far.
    private(set) var deliveredSampleCount = 0

    /// Wall-clock time of sample 0; nil until the first audio arrives.
    var sampleZeroDate: Date? {
        guard let firstAnchor = anchors.first else { return nil }
        return firstAnchor.date.addingTimeInterval(-Double(firstAnchor.firstSampleIndex) / Self.sampleRate)
    }

    /// Records a chunk of `chunkSampleCount` samples whose audio ended at `arrivedAt`.
    /// Returns true when the chunk came after a gap, so the caller can close the speech before it.
    @discardableResult
    mutating func recordChunk(chunkSampleCount: Int, arrivedAt: Date) -> Bool {
        let chunkDurationSeconds = Double(chunkSampleCount) / Self.sampleRate
        let chunkStartDate = arrivedAt.addingTimeInterval(-chunkDurationSeconds)
        var cameAfterGap = false

        if let latestAnchor = anchors.last {
            let expectedStartDate = latestAnchor.date.addingTimeInterval(
                Double(deliveredSampleCount - latestAnchor.firstSampleIndex) / Self.sampleRate)
            if chunkStartDate.timeIntervalSince(expectedStartDate) > Self.gapThresholdSeconds {
                anchors.append(Anchor(firstSampleIndex: deliveredSampleCount, date: chunkStartDate))
                cameAfterGap = true
            }
        } else {
            anchors.append(Anchor(firstSampleIndex: deliveredSampleCount, date: chunkStartDate))
        }
        deliveredSampleCount += chunkSampleCount
        return cameAfterGap
    }

    /// The index of the sample heard at `date`. A time inside a gap maps to the first sample after
    /// the gap; a time past the newest audio extends forward, so a caller can wait for it to arrive.
    /// Nil before any audio has arrived.
    func sampleIndex(for date: Date) -> Int? {
        guard !anchors.isEmpty else { return nil }
        var anchorPosition = 0
        for position in 0..<anchors.count where anchors[position].date <= date {
            anchorPosition = position
        }
        let anchor = anchors[anchorPosition]
        let index = anchor.firstSampleIndex + Int((date.timeIntervalSince(anchor.date) * Self.sampleRate).rounded())
        if anchorPosition + 1 < anchors.count {
            return min(index, anchors[anchorPosition + 1].firstSampleIndex)
        }
        return index
    }

    /// The time at which the sample at `index` was heard. Nil before any audio has arrived.
    func date(forSampleIndex index: Int) -> Date? {
        guard !anchors.isEmpty else { return nil }
        var anchorPosition = 0
        for position in 0..<anchors.count where anchors[position].firstSampleIndex <= index {
            anchorPosition = position
        }
        let anchor = anchors[anchorPosition]
        return anchor.date.addingTimeInterval(Double(index - anchor.firstSampleIndex) / Self.sampleRate)
    }
}
