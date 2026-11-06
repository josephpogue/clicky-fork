import Foundation
import Testing
@testable import ClickySpeech

/// Shared by the speech tests: spoken clips made with the Mac's own `say`, and one Parakeet load.
enum SpeechTestSupport {
    static let sampleRate = 16_000.0

    /// Loaded once for the whole test run; loading reads the real model from the local cache.
    static let sharedParakeet: Task<ParakeetSpeechTranscriber, Error> = Task {
        try await ParakeetSpeechTranscriber.load()
    }

    /// Speaks `text` with `say` into a 16 kHz mono Float32 file and returns its samples.
    static func spokenSamples(_ text: String, voice: String? = nil) throws -> [Float] {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("clicky-speech-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let clipURL = folder.appendingPathComponent("clip.wav")

        let sayProcess = Process()
        sayProcess.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        var arguments = ["-o", clipURL.path, "--data-format=LEF32@16000"]
        if let voice { arguments += ["-v", voice] }
        arguments.append(text)
        sayProcess.arguments = arguments
        try sayProcess.run()
        sayProcess.waitUntilExit()
        #expect(sayProcess.terminationStatus == 0)
        return try AudioFileSampleSource.readSamples(from: clipURL)
    }

    /// `leadingQuietSeconds` of silence, then the clip, then silence up to `totalSeconds`.
    static func clipPlaced(_ clip: [Float], atSeconds: Double, totalSeconds: Double) -> [Float] {
        let leading = [Float](repeating: 0, count: Int(atSeconds * sampleRate))
        let trailingCount = max(0, Int(totalSeconds * sampleRate) - leading.count - clip.count)
        return leading + clip + [Float](repeating: 0, count: trailingCount)
    }
}

/// A clock the test moves by hand, so a session can be played out at any pace.
final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var currentDate: Date
    init(_ start: Date) { currentDate = start }
    var current: Date { lock.withLock { currentDate } }
    func set(_ date: Date) { lock.withLock { currentDate = date } }
}

/// A stand-in microphone that delivers what the test pushes, stamped by the test's clock.
final class ClockedSampleSource: AudioSampleSource, @unchecked Sendable {
    private let lock = NSLock()
    private var deliver: (@Sendable ([Float]) -> Void)?
    private let clock: ManualClock
    private(set) var stopCallCount = 0

    init(clock: ManualClock) { self.clock = clock }

    func start(
        onSamples: @escaping @Sendable ([Float]) -> Void, onFinished: @escaping @Sendable () -> Void
    ) async throws {
        lock.withLock { deliver = onSamples }
    }
    func stop() async { lock.withLock { stopCallCount += 1 } }

    /// Delivers `samples` as a microphone would: in 0.1 s chunks, each arriving the moment its
    /// audio ends. The first sample was heard at `startDate`, so sample i was heard at startDate + i / 16000.
    func play(_ samples: [Float], startingAt startDate: Date) {
        let chunkSampleCount = 1_600
        var chunkStart = 0
        while chunkStart < samples.count {
            let chunkEnd = min(chunkStart + chunkSampleCount, samples.count)
            clock.set(startDate.addingTimeInterval(Double(chunkEnd) / SpeechTestSupport.sampleRate))
            lock.withLock { deliver }?(Array(samples[chunkStart..<chunkEnd]))
            chunkStart = chunkEnd
        }
    }
}

extension SpeechTestSupport {
    static func silence(seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * sampleRate))
    }

    /// Lower-case words only, so a transcript compares with the sentence that was spoken.
    static func words(of text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0 == " " }
            .split(separator: " ").joined(separator: " ")
    }
}
