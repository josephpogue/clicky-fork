import AVFoundation
import Foundation

/// Where the pipeline's audio comes from: 16 kHz mono Float samples, delivered in chunks.
public protocol AudioSampleSource: Sendable {
    /// Starts delivering. `onSamples` is called in order. `onFinished` is called when the source
    /// has no more audio (a file ends; a microphone never finishes by itself).
    func start(
        onSamples: @escaping @Sendable ([Float]) -> Void,
        onFinished: @escaping @Sendable () -> Void
    ) async throws

    /// Stops delivering and releases the device at once. Safe to call twice.
    func stop() async
}

/// Plays a prepared sample array, either with real timing or as fast as possible. Used by tests
/// and by anything that wants to run speech over a recording.
public final class AudioFileSampleSource: AudioSampleSource, @unchecked Sendable {
    private let samples: [Float]
    private let chunkSampleCount: Int
    private let playsInRealTime: Bool
    private let lock = NSLock()
    private var playbackTask: Task<Void, Never>?

    /// `chunkSeconds` is how much audio each delivery holds (the pipeline re-cuts it into 30 ms frames).
    public init(samples: [Float], playsInRealTime: Bool = false, chunkSeconds: Double = 0.1) {
        self.samples = samples
        self.playsInRealTime = playsInRealTime
        self.chunkSampleCount = max(1, Int(chunkSeconds * 16_000))
    }

    public convenience init(fileURL: URL, playsInRealTime: Bool = false) throws {
        self.init(samples: try Self.readSamples(from: fileURL), playsInRealTime: playsInRealTime)
    }

    /// Reads any audio file the system can open and converts it to 16 kHz mono Float.
    public static func readSamples(from fileURL: URL) throws -> [Float] {
        do {
            let file = try AVAudioFile(forReading: fileURL)
            let sourceFormat = file.processingFormat
            guard let sourceBuffer = AVAudioPCMBuffer(
                pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(file.length))
            else { throw SpeechError.audioFileUnreadable("could not allocate a buffer") }
            try file.read(into: sourceBuffer)
            return try PCMSampleConverter.sixteenKilohertzMonoSamples(from: sourceBuffer)
        } catch let error as SpeechError {
            throw error
        } catch {
            throw SpeechError.audioFileUnreadable(error.localizedDescription)
        }
    }

    public func start(
        onSamples: @escaping @Sendable ([Float]) -> Void,
        onFinished: @escaping @Sendable () -> Void
    ) async throws {
        let samples = self.samples
        let chunkSampleCount = self.chunkSampleCount
        let playsInRealTime = self.playsInRealTime
        let task = Task {
            var chunkStart = 0
            while chunkStart < samples.count, !Task.isCancelled {
                let chunkEnd = min(chunkStart + chunkSampleCount, samples.count)
                onSamples(Array(samples[chunkStart..<chunkEnd]))
                let chunkStartBeforeAdvance = chunkStart
                chunkStart = chunkEnd
                if playsInRealTime {
                    try? await Task.sleep(nanoseconds: UInt64(Double(chunkEnd - chunkStartBeforeAdvance) / 16_000 * 1_000_000_000))
                } else {
                    await Task.yield()
                }
            }
            if !Task.isCancelled { onFinished() }
        }
        lock.withLock { playbackTask = task }
    }

    public func stop() async {
        let task = lock.withLock { () -> Task<Void, Never>? in
            let running = playbackTask
            playbackTask = nil
            return running
        }
        task?.cancel()
    }
}

/// Converts PCM buffers of any format to 16 kHz mono Float samples.
enum PCMSampleConverter {
    static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    static func sixteenKilohertzMonoSamples(from buffer: AVAudioPCMBuffer) throws -> [Float] {
        if buffer.format.sampleRate == 16_000, buffer.format.channelCount == 1,
            buffer.format.commonFormat == .pcmFormatFloat32, let channel = buffer.floatChannelData
        {
            return Array(UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength)))
        }
        guard let converter = AVAudioConverter(from: buffer.format, to: targetFormat) else {
            throw SpeechError.audioFileUnreadable("no converter for \(buffer.format)")
        }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            throw SpeechError.audioFileUnreadable("could not allocate an output buffer")
        }
        var inputGiven = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if inputGiven {
                inputStatus.pointee = .endOfStream
                return nil
            }
            inputGiven = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error {
            throw SpeechError.audioFileUnreadable(conversionError?.localizedDescription ?? "conversion failed")
        }
        guard let channel = output.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
    }
}
