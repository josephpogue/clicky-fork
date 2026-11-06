import Foundation

/// One stretch of speech, in seconds from the start of the audio.
public struct UtteranceSegment: Equatable, Sendable {
    public var start: TimeInterval
    public var end: TimeInterval

    public init(start: TimeInterval, end: TimeInterval) {
        self.start = start
        self.end = end
    }
}

/// Cuts a stream of audio frames into utterances by loudness. Pure: no clock, no audio device.
///
/// A frame counts as speech when its RMS level is well above an adaptive noise floor. A speech
/// stretch closes once `hangoverSeconds` of quiet follow it, so a short pause inside a sentence
/// does not split it. A stretch shorter than `minimumSpeechSeconds` is dropped as a blip, and one
/// longer than `maximumSpeechSeconds` is cut into pieces.
public struct EnergyUtteranceSegmenter: Sendable {
    public let hangoverSeconds: TimeInterval
    public let minimumSpeechSeconds: TimeInterval
    public let maximumSpeechSeconds: TimeInterval
    public let sampleRate: Double

    /// A frame is speech when its level is above `noiseFloor * speechToNoiseRatio` ...
    private let speechToNoiseRatio: Float = 4
    /// ... and never below this, so digital silence does not make every whisper of hiss "speech".
    private let absoluteMinimumThreshold: Float = 0.006
    private var noiseFloor: Float = 0.002

    private var openSpeechStart: TimeInterval?
    private var lastSpeechFrameEnd: TimeInterval = 0

    public init(
        sampleRate: Double = 16_000,
        hangoverSeconds: TimeInterval = 0.6,
        minimumSpeechSeconds: TimeInterval = 0.3,
        maximumSpeechSeconds: TimeInterval = 30
    ) {
        self.sampleRate = sampleRate
        self.hangoverSeconds = hangoverSeconds
        self.minimumSpeechSeconds = minimumSpeechSeconds
        self.maximumSpeechSeconds = maximumSpeechSeconds
    }

    /// Feeds one frame (about 30 ms). `startTime` is where the frame begins, in seconds.
    /// Returns the segments this frame closed (usually none).
    public mutating func append(samples: [Float], startTime: TimeInterval) -> [UtteranceSegment] {
        guard !samples.isEmpty else { return [] }
        let frameEnd = startTime + Double(samples.count) / sampleRate
        let level = Self.rootMeanSquare(of: samples)
        let threshold = max(absoluteMinimumThreshold, noiseFloor * speechToNoiseRatio)
        var closedSegments: [UtteranceSegment] = []

        if level > threshold {
            if openSpeechStart == nil {
                openSpeechStart = startTime
            }
            lastSpeechFrameEnd = frameEnd
            if let start = openSpeechStart, lastSpeechFrameEnd - start >= maximumSpeechSeconds {
                // Too long to keep as one piece: close it here and let the next loud frame open a new one.
                closedSegments.append(UtteranceSegment(start: start, end: lastSpeechFrameEnd))
                openSpeechStart = nil
            }
        } else {
            updateNoiseFloor(with: level)
            if let start = openSpeechStart, frameEnd - lastSpeechFrameEnd >= hangoverSeconds {
                closedSegments.append(UtteranceSegment(start: start, end: lastSpeechFrameEnd))
                openSpeechStart = nil
            }
        }
        return closedSegments.filter { $0.end - $0.start >= minimumSpeechSeconds }
    }

    /// Closes speech still open when the audio ends.
    public mutating func flush() -> [UtteranceSegment] {
        defer { openSpeechStart = nil }
        guard let start = openSpeechStart, lastSpeechFrameEnd - start >= minimumSpeechSeconds else { return [] }
        return [UtteranceSegment(start: start, end: lastSpeechFrameEnd)]
    }

    /// The floor falls to a quieter frame at once and creeps up toward a louder one, so a steady
    /// hum is learned within a second or two while a brief quiet word does not drag it up.
    private mutating func updateNoiseFloor(with level: Float) {
        if level < noiseFloor {
            noiseFloor = level
        } else {
            noiseFloor += (level - noiseFloor) * 0.05
        }
    }

    static func rootMeanSquare(of samples: [Float]) -> Float {
        var sumOfSquares: Float = 0
        for sample in samples { sumOfSquares += sample * sample }
        return (sumOfSquares / Float(samples.count)).squareRoot()
    }
}
