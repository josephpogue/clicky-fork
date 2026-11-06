import AVFoundation
import Foundation

/// The part of the microphone that touches the audio hardware: one engine, built for the input
/// device that is current when it starts. Split from `MicrophoneSampleSource` so the rebuild after
/// a device change can be tested with a stand-in.
protocol MicrophoneEngine: AnyObject, Sendable {
    /// Starts the hardware and delivers 16 kHz mono samples to `onSamples`. Calls
    /// `onConfigurationChange` when the system changed the input device or its format under it,
    /// after which this engine delivers nothing more. Throws `SpeechError.microphoneUnavailable`.
    func start(
        onSamples: @escaping @Sendable ([Float]) -> Void,
        onConfigurationChange: @escaping @Sendable () -> Void
    ) throws

    /// Releases the hardware at once. Safe to call twice, and after a configuration change.
    func stop()
}

/// The real engine: `AVAudioEngine` on the default input, converted to 16 kHz mono Float.
final class AVAudioEngineMicrophone: MicrophoneEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var configurationChangeObserver: NSObjectProtocol?

    func start(
        onSamples: @escaping @Sendable ([Float]) -> Void,
        onConfigurationChange: @escaping @Sendable () -> Void
    ) throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
            let converter = AVAudioConverter(from: inputFormat, to: PCMSampleConverter.targetFormat)
        else { throw SpeechError.microphoneUnavailable("no usable input device") }

        // A multi-channel interface (more than a stereo pair) would be mixed down across every channel, which
        // can cancel the voice to silence. Take the first channel, where a microphone's signal sits.
        if inputFormat.channelCount > 2 { converter.channelMap = [0] }

        let targetFormat = PCMSampleConverter.targetFormat
        let sampleRateRatio = targetFormat.sampleRate / inputFormat.sampleRate
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * sampleRateRatio) + 64
            guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
            var inputGiven = false
            var conversionError: NSError?
            // The converter keeps its resampling state between buffers, so a buffer is handed over once
            // and the converter is told no more data is ready (not that the stream ended).
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                if inputGiven {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                inputGiven = true
                inputStatus.pointee = .haveData
                return buffer
            }
            guard status != .error, let channel = output.floatChannelData, output.frameLength > 0 else { return }
            onSamples(Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength))))
        }

        // The system stops the engine when the input device or its format changes (headphones plugged
        // in, a Bluetooth microphone connecting, a sample rate change). Tell the owner, who rebuilds.
        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { _ in onConfigurationChange() }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            NotificationCenter.default.removeObserver(observer)
            inputNode.removeTap(onBus: 0)
            throw SpeechError.microphoneUnavailable(error.localizedDescription)
        }
        lock.withLock {
            self.engine = engine
            self.configurationChangeObserver = observer
        }
    }

    func stop() {
        let (runningEngine, observer) = lock.withLock { () -> (AVAudioEngine?, NSObjectProtocol?) in
            let current = (engine, configurationChangeObserver)
            engine = nil
            configurationChangeObserver = nil
            return current
        }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        runningEngine?.inputNode.removeTap(onBus: 0)
        runningEngine?.stop()
    }
}

/// The Mac's microphone, converted to 16 kHz mono Float. The engine runs only between `start()`
/// and `stop()`, so the microphone indicator is on only during a session.
///
/// When the input device changes mid-session the engine is rebuilt for the new device and the
/// samples keep flowing; the pipeline's timeline notices the short gap and re-anchors. When no
/// device can be opened (the only microphone was unplugged), it tries again every
/// `rebuildRetrySeconds` until one is there or the session stops.
public final class MicrophoneSampleSource: AudioSampleSource, @unchecked Sendable {
    private let makeEngine: @Sendable () -> MicrophoneEngine
    private let requestMicrophonePermission: @Sendable () async -> Bool
    private let rebuildRetrySeconds: Double

    private let lock = NSLock()
    private var engine: MicrophoneEngine?
    private var isListening = false
    /// Counts engines built; a notification from an engine that has been replaced is ignored.
    private var engineGeneration = 0
    private var deliverSamples: (@Sendable ([Float]) -> Void)?
    private var retryTask: Task<Void, Never>?

    public init() {
        self.makeEngine = { AVAudioEngineMicrophone() }
        self.requestMicrophonePermission = { await MicrophoneSampleSource.requestPermission() }
        self.rebuildRetrySeconds = 2
    }

    init(
        makeEngine: @escaping @Sendable () -> MicrophoneEngine,
        requestMicrophonePermission: @escaping @Sendable () async -> Bool = { true },
        rebuildRetrySeconds: Double = 2
    ) {
        self.makeEngine = makeEngine
        self.requestMicrophonePermission = requestMicrophonePermission
        self.rebuildRetrySeconds = rebuildRetrySeconds
    }

    /// Asks for microphone permission when it has not been asked yet; returns whether it is granted.
    /// `start()` calls this, so the prompt appears when a session starts and never at launch.
    public static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    public func start(
        onSamples: @escaping @Sendable ([Float]) -> Void,
        onFinished: @escaping @Sendable () -> Void
    ) async throws {
        guard await requestMicrophonePermission() else { throw SpeechError.microphonePermissionDenied }
        try lock.withLock {
            deliverSamples = onSamples
            try buildEngineWhileLocked()
            isListening = true
        }
    }

    public func stop() async {
        let (runningEngine, pendingRetry) = lock.withLock { () -> (MicrophoneEngine?, Task<Void, Never>?) in
            let current = (engine, retryTask)
            isListening = false
            engine = nil
            retryTask = nil
            deliverSamples = nil
            engineGeneration += 1
            return current
        }
        pendingRetry?.cancel()
        runningEngine?.stop()
    }

    /// Builds and starts an engine for the current input device. The caller holds `lock`.
    private func buildEngineWhileLocked() throws {
        guard let deliverSamples else { return }
        engineGeneration += 1
        let generation = engineGeneration
        let newEngine = makeEngine()
        try newEngine.start(
            onSamples: deliverSamples,
            onConfigurationChange: { [weak self] in self?.inputConfigurationChanged(generation: generation) })
        engine = newEngine
    }

    /// The input device or its format changed: drop the engine and build another for the new input.
    private func inputConfigurationChanged(generation: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard isListening, generation == engineGeneration else { return }
        engine?.stop()
        engine = nil
        rebuildEngineWhileLocked()
    }

    private func rebuildEngineWhileLocked() {
        do {
            try buildEngineWhileLocked()
        } catch {
            scheduleRebuildRetryWhileLocked()
        }
    }

    private func scheduleRebuildRetryWhileLocked() {
        let delayNanoseconds = UInt64(rebuildRetrySeconds * 1_000_000_000)
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled else { return }
            self?.retryRebuild()
        }
    }

    private func retryRebuild() {
        lock.lock()
        defer { lock.unlock() }
        guard isListening, engine == nil else { return }
        rebuildEngineWhileLocked()
    }
}
