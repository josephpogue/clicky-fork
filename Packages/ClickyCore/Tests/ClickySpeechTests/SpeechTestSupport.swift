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
