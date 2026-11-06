import Foundation

/// Session Start waits for the index refresh only briefly: the refresh keeps running and later questions use what it
/// has written, so a first build of a big folder never holds Start on "Starting Claude".
public enum BrainServiceStartWait {
    public static let defaultSeconds = 1.5

    /// Returns when `operation` finishes or after `seconds`, whichever is first. The operation is never cancelled.
    public static func waitUntilDone(
        orAfter seconds: Double = defaultSeconds, _ operation: @escaping @Sendable () async -> Void
    ) async {
        let gate = OnceGate()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            gate.install(continuation)
            Task.detached {
                await operation()
                gate.open()
            }
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
                gate.open()
            }
        }
    }

    /// Resumes its continuation exactly once, whichever side opens it first.
    private final class OnceGate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var isOpen = false

        func install(_ continuation: CheckedContinuation<Void, Never>) {
            lock.lock()
            self.continuation = continuation
            lock.unlock()
        }

        func open() {
            lock.lock()
            let toResume = isOpen ? nil : continuation
            if toResume != nil { isOpen = true; continuation = nil }
            lock.unlock()
            toResume?.resume()
        }
    }
}
