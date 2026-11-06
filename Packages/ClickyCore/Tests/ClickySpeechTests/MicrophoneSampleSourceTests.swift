import Foundation
import Testing
@testable import ClickySpeech

/// A stand-in for the audio hardware: records what the source did to it and lets the test play the
/// part of the system (deliver samples, announce that the input device changed).
private final class FakeMicrophoneEngine: MicrophoneEngine, @unchecked Sendable {
    private let lock = NSLock()
    private let failsToStart: Bool
    private var deliverSamples: (@Sendable ([Float]) -> Void)?
    private var announceConfigurationChange: (@Sendable () -> Void)?
    private var started = false
    private var stopCount = 0

    init(failsToStart: Bool = false) { self.failsToStart = failsToStart }

    var isRunning: Bool { lock.withLock { started } }
    var timesStopped: Int { lock.withLock { stopCount } }

    func start(
        onSamples: @escaping @Sendable ([Float]) -> Void,
        onConfigurationChange: @escaping @Sendable () -> Void
    ) throws {
        if failsToStart { throw SpeechError.microphoneUnavailable("no usable input device") }
        lock.withLock {
            deliverSamples = onSamples
            announceConfigurationChange = onConfigurationChange
            started = true
        }
    }

    func stop() {
        lock.withLock {
            started = false
            stopCount += 1
        }
    }

    func hear(_ samples: [Float]) { lock.withLock { deliverSamples }?(samples) }
    /// What macOS does when headphones are plugged in: the engine stops and the owner is told.
    func inputDeviceChanged() {
        lock.withLock { started = false }
        lock.withLock { announceConfigurationChange }?()
    }
}

/// Hands out the engines the source asks for, in order, and remembers them.
private final class EngineSupply: @unchecked Sendable {
    private let lock = NSLock()
    private var upcoming: [FakeMicrophoneEngine]
    private(set) var handedOut: [FakeMicrophoneEngine] = []

    init(_ engines: [FakeMicrophoneEngine]) { upcoming = engines }

    func next() -> FakeMicrophoneEngine {
        lock.withLock {
            let engine = upcoming.isEmpty ? FakeMicrophoneEngine() : upcoming.removeFirst()
            handedOut.append(engine)
            return engine
        }
    }
    var engines: [FakeMicrophoneEngine] { lock.withLock { handedOut } }
}

private final class HeardSamples: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [Float] = []
    func add(_ samples: [Float]) { lock.withLock { all += samples } }
    var heard: [Float] { lock.withLock { all } }
}

@Suite struct MicrophoneSampleSourceTests {
    private func makeSource(_ supply: EngineSupply, permission: Bool = true, retrySeconds: Double = 0.05)
        -> MicrophoneSampleSource
    {
        MicrophoneSampleSource(
            makeEngine: { supply.next() }, requestMicrophonePermission: { permission },
            rebuildRetrySeconds: retrySeconds)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() { try await Task.sleep(nanoseconds: 20_000_000) }
    }

    @Test func aDeviceChangeRebuildsTheEngineAndTheSamplesKeepFlowing() async throws {
        let supply = EngineSupply([])
        let source = makeSource(supply)
        let heard = HeardSamples()
        try await source.start(onSamples: { heard.add($0) }, onFinished: {})
        let first = try #require(supply.engines.first)
        first.hear([1, 2])

        first.inputDeviceChanged()
        #expect(supply.engines.count == 2)
        let second = supply.engines[1]
        #expect(second.isRunning)
        #expect(first.timesStopped >= 1)
        second.hear([3, 4])
        #expect(heard.heard == [1, 2, 3, 4])
        await source.stop()
    }

    @Test func eachDeviceChangeBuildsAnotherEngine() async throws {
        let supply = EngineSupply([])
        let source = makeSource(supply)
        try await source.start(onSamples: { _ in }, onFinished: {})
        supply.engines[0].inputDeviceChanged()
        supply.engines[1].inputDeviceChanged()
        #expect(supply.engines.count == 3)
        #expect(supply.engines[2].isRunning)
        #expect(!supply.engines[1].isRunning)
        await source.stop()
    }

    @Test func aRebuildThatFindsNoDeviceIsRetriedUntilOneIsThere() async throws {
        // The first engine works; after the change, two attempts find nothing, the third succeeds.
        let supply = EngineSupply([
            FakeMicrophoneEngine(), FakeMicrophoneEngine(failsToStart: true), FakeMicrophoneEngine(failsToStart: true),
        ])
        let source = makeSource(supply)
        let heard = HeardSamples()
        try await source.start(onSamples: { heard.add($0) }, onFinished: {})
        supply.engines[0].inputDeviceChanged()

        try await waitUntil { supply.engines.count == 4 }
        #expect(supply.engines.count == 4)
        let recovered = supply.engines[3]
        #expect(recovered.isRunning)
        recovered.hear([9])
        #expect(heard.heard == [9])
        await source.stop()
    }

    @Test func nothingIsRebuiltAfterStop() async throws {
        let supply = EngineSupply([])
        let source = makeSource(supply)
        try await source.start(onSamples: { _ in }, onFinished: {})
        let only = supply.engines[0]
        await source.stop()
        #expect(only.timesStopped >= 1)

        only.inputDeviceChanged()
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(supply.engines.count == 1)
    }

    @Test func stopCancelsARetryThatIsWaiting() async throws {
        let supply = EngineSupply([FakeMicrophoneEngine(), FakeMicrophoneEngine(failsToStart: true)])
        let source = makeSource(supply, retrySeconds: 0.1)
        try await source.start(onSamples: { _ in }, onFinished: {})
        supply.engines[0].inputDeviceChanged()
        #expect(supply.engines.count == 2)
        await source.stop()
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(supply.engines.count == 2)
    }

    @Test func aMicrophoneThatCannotStartFailsStartWithTheReason() async throws {
        let supply = EngineSupply([FakeMicrophoneEngine(failsToStart: true)])
        let source = makeSource(supply)
        await #expect(throws: SpeechError.microphoneUnavailable("no usable input device")) {
            try await source.start(onSamples: { _ in }, onFinished: {})
        }
    }

    @Test func deniedPermissionFailsStartWithoutBuildingAnEngine() async throws {
        let supply = EngineSupply([])
        let source = makeSource(supply, permission: false)
        await #expect(throws: SpeechError.microphonePermissionDenied) {
            try await source.start(onSamples: { _ in }, onFinished: {})
        }
        #expect(supply.engines.isEmpty)
    }
}
