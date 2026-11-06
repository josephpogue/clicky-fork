import Foundation

/// Lets a caller wait for work that cannot itself be cancelled (a permission prompt, a model download) and
/// still stop waiting the moment its own task is cancelled. The work keeps running; its result is dropped.
public enum CancellableWait {
    /// The work's result, or nil when the calling task was cancelled first.
    public static func result<Value: Sendable>(
        of work: @escaping @Sendable () async -> Value
    ) async -> Value? {
        let race = FirstResultRace<Value>()
        Task { race.finish(with: await work()) }
        return await withTaskCancellationHandler {
            await race.firstResult()
        } onCancel: {
            race.finish(with: nil)
        }
    }
}

private final class FirstResultRace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var isFinished = false
    private var storedResult: Value?
    private var waitingContinuation: CheckedContinuation<Value?, Never>?

    func firstResult() async -> Value? {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isFinished {
                let result = storedResult
                lock.unlock()
                continuation.resume(returning: result)
            } else {
                waitingContinuation = continuation
                lock.unlock()
            }
        }
    }

    func finish(with result: Value?) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        storedResult = result
        let continuation = waitingContinuation
        waitingContinuation = nil
        lock.unlock()
        continuation?.resume(returning: result)
    }
}
