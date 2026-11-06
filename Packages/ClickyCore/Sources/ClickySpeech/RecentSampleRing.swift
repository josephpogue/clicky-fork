import Foundation

/// The most recent audio, addressed by absolute sample index since the session began.
/// Older samples fall off the front once more than `capacity` are held.
struct RecentSampleRing: Sendable {
    let capacity: Int
    private var samples: [Float] = []
    /// Absolute index of `samples[0]`.
    private(set) var firstIndex = 0

    init(capacity: Int) {
        self.capacity = capacity
    }

    /// Absolute index one past the newest sample.
    var endIndex: Int { firstIndex + samples.count }

    mutating func append(_ newSamples: [Float]) {
        samples.append(contentsOf: newSamples)
        // Trim in blocks of one second so the copy cost is spread out.
        if samples.count > capacity + 16_000 {
            let excess = samples.count - capacity
            samples.removeFirst(excess)
            firstIndex += excess
        }
    }

    /// Samples in `[from, to)`, clamped to what is held.
    func slice(from: Int, to: Int) -> [Float] {
        let lower = max(from, firstIndex)
        let upper = min(to, endIndex)
        guard lower < upper else { return [] }
        return Array(samples[(lower - firstIndex)..<(upper - firstIndex)])
    }
}
