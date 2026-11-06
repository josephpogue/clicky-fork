import Foundation

/// Lines the child printed, handed to async code one at a time with a deadline.
final class ClaudeLineChannel: @unchecked Sendable {
    enum Event {
        case line(String)
        case ended
        case timedOut
    }

    private let lock = NSLock()
    private var bufferedLines: [String] = []
    private var hasEnded = false
    private var waiter: (id: Int, continuation: CheckedContinuation<Event, Never>)?
    private var nextWaiterID = 0

    func push(_ line: String) {
        lock.lock()
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.continuation.resume(returning: .line(line))
        } else {
            bufferedLines.append(line)
            lock.unlock()
        }
    }

    func finish() {
        lock.lock()
        hasEnded = true
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.continuation.resume(returning: .ended)
        } else {
            lock.unlock()
        }
    }

    func nextEvent(timeoutSeconds: Double) async -> Event {
        await withCheckedContinuation { continuation in
            lock.lock()
            if !bufferedLines.isEmpty {
                let line = bufferedLines.removeFirst()
                lock.unlock()
                continuation.resume(returning: .line(line))
                return
            }
            if hasEnded {
                lock.unlock()
                continuation.resume(returning: .ended)
                return
            }
            nextWaiterID += 1
            let waiterID = nextWaiterID
            waiter = (waiterID, continuation)
            lock.unlock()

            DispatchQueue.global().asyncAfter(deadline: .now() + max(timeoutSeconds, 0)) { [self] in
                lock.lock()
                guard let waiter, waiter.id == waiterID else {
                    lock.unlock()
                    return
                }
                self.waiter = nil
                lock.unlock()
                waiter.continuation.resume(returning: .timedOut)
            }
        }
    }
}

/// One long-lived `claude` child process that takes stream-json lines on stdin and prints them on stdout.
final class ClaudeConversationProcess: @unchecked Sendable {
    /// The model the process is answering with right now (changes after an in-place model change).
    var model: String
    /// The effort applied to this process for dig deeper; nil while it runs on the setting it started with.
    var appliedEffort: AnswerEffort?
    /// What the tool reported as its effort before the first change (nil when none was ever set), so it can be put back.
    var startingEffortLevel: String?
    var hasCapturedStartingEffort = false
    let lines = ClaudeLineChannel()
    private let process = Process()
    private let inputHandle: FileHandle

    var isRunning: Bool { process.isRunning }

    init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL,
        model: String
    ) throws {
        self.model = model
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = workingDirectory
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        inputHandle = inputPipe.fileHandleForWriting

        do {
            try process.run()
        } catch {
            throw ProviderFailure.cliNotFound
        }

        let outputHandle = outputPipe.fileHandleForReading
        let channel = lines
        let reader = Thread {
            var pendingBytes = Data()
            while true {
                let chunk = outputHandle.availableData
                if chunk.isEmpty { break }
                pendingBytes.append(chunk)
                while let newlineIndex = pendingBytes.firstIndex(of: 0x0A) {
                    let lineBytes = pendingBytes[pendingBytes.startIndex..<newlineIndex]
                    pendingBytes.removeSubrange(pendingBytes.startIndex...newlineIndex)
                    channel.push(String(decoding: lineBytes, as: UTF8.self))
                }
            }
            if !pendingBytes.isEmpty {
                channel.push(String(decoding: pendingBytes, as: UTF8.self))
            }
            channel.finish()
        }
        reader.start()
    }

    var processIdentifier: Int32 { process.processIdentifier }

    /// Writes one JSON object as one line.
    func send(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        do {
            try inputHandle.write(contentsOf: data + Data([0x0A]))
        } catch {
            throw ProviderFailure.failed(message: "Claude stopped unexpectedly.")
        }
    }

    /// Closes stdin so the tool can finish on its own, waits `gracePeriodSeconds`, then terminates it.
    /// Returns once the process is gone.
    func stop(gracePeriodSeconds: Double) async {
        try? inputHandle.close()
        if await waitForExit(seconds: gracePeriodSeconds) { return }
        process.terminate()
        if await waitForExit(seconds: 1.5) { return }
        kill(process.processIdentifier, SIGKILL)
        _ = await waitForExit(seconds: 1.5)
    }

    private func waitForExit(seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while process.isRunning {
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }
}
