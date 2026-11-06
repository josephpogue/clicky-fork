import Foundation

/// A result that is decided once, by whichever of several parties reports first (the work, a
/// deadline). Unlike a task group, the waiter does not wait for the losers, so work that ignores
/// cancellation (a network retry loop, a framework call) cannot hold the caller past its deadline.
final class FirstResult<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var decidedResult: Result<Value, Error>?
    private var waitingContinuation: CheckedContinuation<Value, Error>?

    /// Records `result` if nothing was recorded before. Returns whether this call decided it.
    @discardableResult
    func finish(_ result: Result<Value, Error>) -> Bool {
        let (wasDecidedHere, continuationToResume) = lock.withLock {
            () -> (Bool, CheckedContinuation<Value, Error>?) in
            guard decidedResult == nil else { return (false, nil) }
            decidedResult = result
            let continuation = waitingContinuation
            waitingContinuation = nil
            return (true, continuation)
        }
        continuationToResume?.resume(with: result)
        return wasDecidedHere
    }

    /// Waits for the decided result.
    func value() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let alreadyDecided: Result<Value, Error>? = lock.withLock {
                if let decidedResult { return decidedResult }
                waitingContinuation = continuation
                return nil
            }
            if let alreadyDecided { continuation.resume(with: alreadyDecided) }
        }
    }
}

extension FirstResult {
    /// Runs `operation` against a deadline. When `seconds` pass first, the caller gets
    /// `timeoutError` at once and `operation` is cancelled (it may keep running if it ignores that).
    static func run(
        withinSeconds seconds: Double,
        timeoutError: Error,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let race = FirstResult<Value>()
        let work = Task {
            do { race.finish(.success(try await operation())) } catch { race.finish(.failure(error)) }
        }
        let deadline = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if !Task.isCancelled, race.finish(.failure(timeoutError)) { work.cancel() }
        }
        defer { deadline.cancel() }
        return try await race.value()
    }
}
