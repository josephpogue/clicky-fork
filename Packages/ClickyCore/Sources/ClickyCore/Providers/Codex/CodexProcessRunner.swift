import Foundation

/// What one run of the `codex` tool produced.
struct CodexProcessResult {
    /// Standard output, split into lines.
    var outputLines: [String]
    var standardErrorText: String
    var exitStatus: Int32
    var didTimeOut: Bool
    /// The caller's line check asked to stop early, so the process was terminated on purpose.
    var wasStoppedEarly: Bool
    /// `terminateEverything()` ended the process.
    var wasCancelled: Bool
    var couldNotStart: Bool
}

/// Runs the `codex` tool as a child process with a time limit, and can end every process it started.
/// Standard input is always /dev/null, because `codex exec` waits for stdin when it is open.
final class CodexProcessRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var runningProcessesByID: [Int32: Process] = [:]
    private var cancelledProcessIDs: Set<Int32> = []

    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL,
        timeoutSeconds: Double,
        shouldStopAfterLine: (@Sendable (String) -> Bool)? = nil
    ) async -> CodexProcessResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = self.runBlocking(
                    executableURL: executableURL,
                    arguments: arguments,
                    environment: environment,
                    workingDirectory: workingDirectory,
                    timeoutSeconds: timeoutSeconds,
                    shouldStopAfterLine: shouldStopAfterLine
                )
                continuation.resume(returning: result)
            }
        }
    }

    /// Terminates every process this runner started that is still running.
    func terminateEverything() {
        lock.lock()
        let processes = Array(runningProcessesByID)
        for (processID, _) in processes {
            cancelledProcessIDs.insert(processID)
        }
        lock.unlock()
        for (_, process) in processes {
            Self.terminateAndEscalate(process)
        }
    }

    // MARK: Blocking implementation

    private func runBlocking(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL,
        timeoutSeconds: Double,
        shouldStopAfterLine: (@Sendable (String) -> Bool)?
    ) -> CodexProcessResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = workingDirectory
        process.standardInput = FileHandle.nullDevice
        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()
        process.standardOutput = standardOutputPipe
        process.standardError = standardErrorPipe

        let exitSemaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exitSemaphore.signal() }

        do {
            try process.run()
        } catch {
            return CodexProcessResult(
                outputLines: [], standardErrorText: "\(error.localizedDescription)", exitStatus: -1,
                didTimeOut: false, wasStoppedEarly: false, wasCancelled: false, couldNotStart: true
            )
        }
        let processID = process.processIdentifier
        lock.lock()
        runningProcessesByID[processID] = process
        lock.unlock()

        let flags = RunFlags()
        let readersFinished = DispatchGroup()

        readersFinished.enter()
        var capturedStandardError = Data()
        DispatchQueue.global().async {
            capturedStandardError = standardErrorPipe.fileHandleForReading.readDataToEndOfFile()
            readersFinished.leave()
        }

        readersFinished.enter()
        var capturedLines: [String] = []
        DispatchQueue.global().async {
            var pending = Data()
            let reader = standardOutputPipe.fileHandleForReading
            while true {
                let chunk = reader.availableData
                if chunk.isEmpty { break }
                pending.append(chunk)
                while let newlineIndex = pending.firstIndex(of: 0x0A) {
                    let lineData = pending[pending.startIndex..<newlineIndex]
                    pending.removeSubrange(pending.startIndex...newlineIndex)
                    let line = String(decoding: lineData, as: UTF8.self)
                    capturedLines.append(line)
                    if let shouldStopAfterLine, shouldStopAfterLine(line), !flags.markStoppedEarly() {
                        Self.terminateAndEscalate(process)
                    }
                }
            }
            if !pending.isEmpty {
                capturedLines.append(String(decoding: pending, as: UTF8.self))
            }
            readersFinished.leave()
        }

        let timeoutItem = DispatchWorkItem {
            flags.markTimedOut()
            Self.terminateAndEscalate(process)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: timeoutItem)

        exitSemaphore.wait()
        timeoutItem.cancel()

        // A grandchild that inherited the pipes could keep them open after codex itself is gone.
        if readersFinished.wait(timeout: .now() + 2) == .timedOut {
            try? standardOutputPipe.fileHandleForReading.close()
            try? standardErrorPipe.fileHandleForReading.close()
            _ = readersFinished.wait(timeout: .now() + 1)
        }

        lock.lock()
        runningProcessesByID[processID] = nil
        let wasCancelled = cancelledProcessIDs.remove(processID) != nil
        lock.unlock()

        return CodexProcessResult(
            outputLines: capturedLines,
            standardErrorText: String(decoding: capturedStandardError, as: UTF8.self),
            exitStatus: process.terminationStatus,
            didTimeOut: flags.timedOut,
            wasStoppedEarly: flags.stoppedEarly,
            wasCancelled: wasCancelled,
            couldNotStart: false
        )
    }

    /// Asks the process to end, and kills it if it is still there a second later.
    private static func terminateAndEscalate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let processID = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            if process.isRunning {
                kill(processID, SIGKILL)
            }
        }
    }
}

/// Flags the timer and the reader threads set while a run is in progress.
private final class RunFlags: @unchecked Sendable {
    private let lock = NSLock()
    private var timedOutValue = false
    private var stoppedEarlyValue = false

    var timedOut: Bool { lock.lock(); defer { lock.unlock() }; return timedOutValue }
    var stoppedEarly: Bool { lock.lock(); defer { lock.unlock() }; return stoppedEarlyValue }

    func markTimedOut() {
        lock.lock(); timedOutValue = true; lock.unlock()
    }

    /// Returns true when it was already marked, so the caller terminates only once.
    func markStoppedEarly() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let wasAlreadyMarked = stoppedEarlyValue
        stoppedEarlyValue = true
        return wasAlreadyMarked
    }
}
