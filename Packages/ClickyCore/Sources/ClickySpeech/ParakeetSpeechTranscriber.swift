import FluidAudio
import Foundation

/// Local speech-to-text on FluidAudio's Parakeet TDT 0.6b v3 CoreML model.
///
/// The model lives in FluidAudio's cache (`~/Library/Application Support/FluidAudio/Models`).
/// `load()` reads it from there; only when it is missing does it download it once, which is the
/// only network use in the speech module.
public final class ParakeetSpeechTranscriber: SpeechTranscriber {
    /// What `engineName` reads for this engine; the app compares against it to say which engine it got.
    public static let engineDisplayName = "Parakeet TDT 0.6b v3"
    public let engineName = ParakeetSpeechTranscriber.engineDisplayName

    private let recognizer: AsrManager

    /// Seconds the last `load()` spent, for benchmarks and logs.
    public let loadSeconds: Double

    private init(recognizer: AsrManager, loadSeconds: Double) {
        self.recognizer = recognizer
        self.loadSeconds = loadSeconds
    }

    /// How long one attempt to download the model may take before the app gives up and uses Apple's recognizer.
    public static let downloadTimeoutSeconds = 300.0

    public static func load() async throws -> ParakeetSpeechTranscriber {
        try await load(
            loadFromCache: { try await AsrModels.loadFromCache(version: .v3) },
            download: { try await AsrModels.downloadAndLoad(version: .v3) },
            downloadTimeoutSeconds: downloadTimeoutSeconds)
    }

    /// Reads the model from the cache; when it is missing, downloads it once, giving up after
    /// `downloadTimeoutSeconds`. The download library retries timed-out requests for as long as it
    /// can, so on a Mac with no network it would otherwise never answer. A failure here sends
    /// `SpeechEngineFactory` to the Apple recognizer.
    static func load(
        loadFromCache: @escaping @Sendable () async throws -> AsrModels,
        download: @escaping @Sendable () async throws -> AsrModels,
        downloadTimeoutSeconds: Double
    ) async throws -> ParakeetSpeechTranscriber {
        let loadStarted = Date()
        let models: AsrModels
        do {
            models = try await loadFromCache()
        } catch {
            // Not in the cache (first run on this Mac): fetch it once, then load.
            // FluidAudio 0.18.2 honours this cancel: FileDownloader cancels its URLSession task, RetryPolicy's backoff sleep throws, and retries stop at 4 attempts.
            models = try await FirstResult<AsrModels>.run(
                withinSeconds: downloadTimeoutSeconds,
                timeoutError: SpeechError.speechModelDownloadTimedOut(seconds: downloadTimeoutSeconds),
                operation: download)
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
