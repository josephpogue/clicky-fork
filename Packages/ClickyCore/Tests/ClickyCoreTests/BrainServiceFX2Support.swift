import Foundation

/// A temporary folder tree for the FX2 brain tests. Never reads the real brain.
struct BrainTempTree {
    let root: URL

    init(name: String = "brain-fx2") throws {
        // Resolved, so `/var` and `/private/var` never make two spellings of one folder.
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: String(cString: realpath(base.path, nil)))
    }

    func folder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func write(_ relativePath: String, _ contents: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    func url(_ relativePath: String) -> URL { root.appendingPathComponent(relativePath) }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

/// Heavy synchronous work (SQLite builds, thousands of file writes) started on its OWN thread, never on Swift's
/// cooperative pool. A test that runs such work on a pool thread holds that thread for seconds, and the timers and
/// continuations of every other test in the same process wait behind it.
final class DedicatedThreadJob<Result: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: Swift.Result<Result, Error>?
    private var continuation: CheckedContinuation<Result, Error>?

    init(_ work: @escaping @Sendable () throws -> Result) {
        let thread = Thread { [self] in
            let finished: Swift.Result<Result, Error>
            do { finished = .success(try work()) } catch { finished = .failure(error) }
            lock.lock()
            outcome = finished
            let waiting = continuation
            continuation = nil
            lock.unlock()
            waiting?.resume(with: finished)
        }
        thread.qualityOfService = .utility
        // Room for the deep recursion of a big folder walk.
        thread.stackSize = 8 * 1024 * 1024
        thread.start()
    }

    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return outcome != nil }

    /// Suspends (without holding a pool thread) until the work ends, then returns its result or throws its error.
    func value() async throws -> Result {
        try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Result, Error>) in
            lock.lock()
            if let outcome {
                lock.unlock()
                waiter.resume(with: outcome)
            } else {
                continuation = waiter
                lock.unlock()
            }
        }
    }
}
