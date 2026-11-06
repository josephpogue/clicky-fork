import FluidAudio
import Foundation

/// Local speech-to-text on FluidAudio's Parakeet TDT 0.6b v3 CoreML model.
///
/// The model lives in FluidAudio's cache (`~/Library/Application Support/FluidAudio/Models`).
/// `load()` reads it from there; only when it is missing does it download it once, which is the
/// only network use in the speech module.
public final class ParakeetSpeechTranscriber: SpeechTranscriber {
    public let engineName = "Parakeet TDT 0.6b v3"

    private let recognizer: AsrManager

    /// Seconds the last `load()` spent, for benchmarks and logs.
    public let loadSeconds: Double

    private init(recognizer: AsrManager, loadSeconds: Double) {
        self.recognizer = recognizer
        self.loadSeconds = loadSeconds
    }

    public static func load() async throws -> ParakeetSpeechTranscriber {
        let loadStarted = Date()
        let models: AsrModels
        do {
            models = try await AsrModels.loadFromCache(version: .v3)
        } catch {
            // Not in the cache (first run on this Mac): fetch it once, then load.
            models = try await AsrModels.downloadAndLoad(version: .v3)
        }
        let recognizer = AsrManager(config: .default)
        try await recognizer.loadModels(models)
        return ParakeetSpeechTranscriber(
            recognizer: recognizer, loadSeconds: Date().timeIntervalSince(loadStarted))
    }

    public func transcribe(samples: [Float], sampleRate: Double) async throws -> String {
        guard sampleRate == 16_000 else { throw SpeechError.unsupportedSampleRate(sampleRate) }
        // The decoder keeps state between calls, so each utterance starts from a fresh one.
        var decoderState = TdtDecoderState.make(decoderLayers: await recognizer.decoderLayerCount)
        let result = try await recognizer.transcribe(samples, decoderState: &decoderState)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
