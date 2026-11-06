import AVFoundation
import Foundation

/// The Mac's microphone, converted to 16 kHz mono Float. The engine runs only between `start()`
/// and `stop()`, so the microphone indicator is on only during a session.
public final class MicrophoneSampleSource: AudioSampleSource, @unchecked Sendable {
    private let lock = NSLock()
    private var engine: AVAudioEngine?

    public init() {}

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
        guard await Self.requestPermission() else { throw SpeechError.microphonePermissionDenied }

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

        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            throw SpeechError.microphoneUnavailable(error.localizedDescription)
        }
        lock.withLock { self.engine = engine }
    }

    public func stop() async {
        let running = lock.withLock { () -> AVAudioEngine? in
            let current = engine
            engine = nil
            return current
        }
        running?.inputNode.removeTap(onBus: 0)
        running?.stop()
    }
}
