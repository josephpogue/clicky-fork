import Testing
@testable import ClickySpeech

/// Builds 16 kHz audio from described pieces and feeds it to the segmenter in 30 ms frames.
private enum SyntheticAudio {
    static let sampleRate = 16_000.0
    static let frameSampleCount = 480 // 30 ms at 16 kHz

    /// Deterministic white noise in [-amplitude, amplitude] (a simple linear congruential generator).
    static func noise(seconds: Double, amplitude: Float, seed: UInt64) -> [Float] {
        var state = seed
        return (0..<Int(seconds * sampleRate)).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let unit = Float((state >> 33) & 0xFFFF) / 65535.0 // 0...1
            return (unit * 2 - 1) * amplitude
        }
    }

    static func segments(for audio: [Float]) -> [UtteranceSegment] {
        var segmenter = EnergyUtteranceSegmenter()
        var closed: [UtteranceSegment] = []
        var frameStart = 0
        while frameStart < audio.count {
            let frameEnd = min(frameStart + frameSampleCount, audio.count)
            closed += segmenter.append(
                samples: Array(audio[frameStart..<frameEnd]),
                startTime: Double(frameStart) / sampleRate
            )
            frameStart = frameEnd
        }
        closed += segmenter.flush()
        return closed
    }
}

@Suite struct EnergyUtteranceSegmenterTests {
    @Test func twoBurstsInQuietNoiseGiveTwoSegments() {
        // 1 s quiet, 2 s burst (1.0-3.0), 1 s quiet, 1.5 s burst (4.0-5.5), 2 s quiet.
        let audio =
            SyntheticAudio.noise(seconds: 1, amplitude: 0.001, seed: 1)
            + SyntheticAudio.noise(seconds: 2, amplitude: 0.3, seed: 2)
            + SyntheticAudio.noise(seconds: 1, amplitude: 0.001, seed: 3)
            + SyntheticAudio.noise(seconds: 1.5, amplitude: 0.3, seed: 4)
            + SyntheticAudio.noise(seconds: 2, amplitude: 0.001, seed: 5)
        let segments = SyntheticAudio.segments(for: audio)
        #expect(segments.count == 2)
        guard segments.count == 2 else { return }
        #expect(abs(segments[0].start - 1.0) < 0.1)
        #expect(abs(segments[0].end - 3.0) < 0.1)
        #expect(abs(segments[1].start - 4.0) < 0.1)
        #expect(abs(segments[1].end - 5.5) < 0.1)
    }

    @Test func gapShorterThanHangoverDoesNotSplit() {
        // Burst 1.0-2.0, quiet gap 0.4 s (under the 0.6 s hangover), burst 2.4-3.0, then quiet.
        let audio =
            SyntheticAudio.noise(seconds: 1.0, amplitude: 0.001, seed: 1)
            + SyntheticAudio.noise(seconds: 1.0, amplitude: 0.3, seed: 2)
            + SyntheticAudio.noise(seconds: 0.4, amplitude: 0.001, seed: 3)
            + SyntheticAudio.noise(seconds: 0.6, amplitude: 0.3, seed: 4)
            + SyntheticAudio.noise(seconds: 2.0, amplitude: 0.001, seed: 5)
        let segments = SyntheticAudio.segments(for: audio)
        #expect(segments.count == 1)
        guard let only = segments.first else { return }
        #expect(abs(only.start - 1.0) < 0.1)
        #expect(abs(only.end - 3.0) < 0.1)
    }

    @Test func burstShorterThanMinimumSpeechIsDropped() {
        let audio =
            SyntheticAudio.noise(seconds: 1.0, amplitude: 0.001, seed: 1)
            + SyntheticAudio.noise(seconds: 0.2, amplitude: 0.3, seed: 2)
            + SyntheticAudio.noise(seconds: 2.0, amplitude: 0.001, seed: 3)
        #expect(SyntheticAudio.segments(for: audio).isEmpty)
    }

    @Test func speechLongerThanMaximumIsSplit() {
        // 1 s quiet then 70 s of continuous speech-level noise: the 30 s cap makes 30 + 30 + 10 s.
        let audio =
            SyntheticAudio.noise(seconds: 1.0, amplitude: 0.001, seed: 1)
            + SyntheticAudio.noise(seconds: 70, amplitude: 0.3, seed: 2)
        let segments = SyntheticAudio.segments(for: audio)
        #expect(segments.count == 3)
        #expect(segments.allSatisfy { $0.end - $0.start <= 30.1 })
    }

    @Test func flushClosesSpeechStillOpen() {
        // The audio stops during speech: nothing closed it yet, so only flush reports it.
        let audio =
            SyntheticAudio.noise(seconds: 1.0, amplitude: 0.001, seed: 1)
            + SyntheticAudio.noise(seconds: 1.0, amplitude: 0.3, seed: 2)
        var segmenter = EnergyUtteranceSegmenter()
        var closedBeforeFlush: [UtteranceSegment] = []
        var frameStart = 0
        while frameStart < audio.count {
            let frameEnd = min(frameStart + 480, audio.count)
            closedBeforeFlush += segmenter.append(
                samples: Array(audio[frameStart..<frameEnd]), startTime: Double(frameStart) / 16_000)
            frameStart = frameEnd
        }
        #expect(closedBeforeFlush.isEmpty)
        let flushed = segmenter.flush()
        #expect(flushed.count == 1)
    }
}
