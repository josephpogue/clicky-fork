import Foundation

/// Runs a command line tool to completion and collects what it printed. Used for `claude auth ...` and the summary.
enum ClaudeOneShotRunner {
    struct Output {
        var exitCode: Int32
        var standardOutput: String
        var standardError: String
        var didTimeOut: Bool
    }

    /// How long a tool that ignored the polite stop request gets before it is killed.
    static let secondsBetweenTerminateAndKill = 1.5
    /// How long to wait for the output readers once the tool has exited.
    static let secondsToWaitForReaders = 2.0

    /// Blocking work runs on a dispatch thread, so the async caller never ties up the cooperative pool.
    static func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL,
        standardInputText: String?,
        timeoutSeconds: Double
    ) async throws -> Output {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = executableURL
                process.arguments = arguments
                process.environment = environment
                process.currentDirectoryURL = workingDirectory

                let outputPipe = Pipe()
                let errorPipe = Pipe()
                let inputPipe = Pipe()
                process.standardOutput = outputPipe
                process.standardError = errorPipe
                process.standardInput = inputPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: ProviderFailure.cliNotFound)
                    return
                }

                let readGroup = DispatchGroup()
                let collected = CollectedOutput()
                readGroup.enter()
                DispatchQueue.global().async {
                    collected.storeOutput(outputPipe.fileHandleForReading.readDataToEndOfFile())
                    readGroup.leave()
                }
                readGroup.enter()
                DispatchQueue.global().async {
                    collected.storeError(errorPipe.fileHandleForReading.readDataToEndOfFile())
                    readGroup.leave()
                }

                // Written on its own thread so a long text never blocks on a full pipe while the tool is still starting.
                let inputText = standardInputText ?? ""
                DispatchQueue.global().async {
                    try? inputPipe.fileHandleForWriting.write(contentsOf: Data(inputText.utf8))
                    try? inputPipe.fileHandleForWriting.close()
                }

                var didTimeOut = false
                let timeoutLock = NSLock()
                let timeoutItem = DispatchWorkItem {
                    timeoutLock.lock()
                    didTimeOut = true
                    timeoutLock.unlock()
                    process.terminate()
                    // A tool that ignores the polite request is killed shortly after, so the caller (Stop included)
                    // never waits on it for good.
                    let processID = process.processIdentifier
                    DispatchQueue.global().asyncAfter(deadline: .now() + Self.secondsBetweenTerminateAndKill) {
                        if process.isRunning {
                            kill(processID, SIGKILL)
                        }
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: timeoutItem)

                process.waitUntilExit()
                timeoutItem.cancel()
                // A grandchild that inherited the pipes could keep them open after the tool itself is gone; the
                // readers are then left behind and whatever they have not stored yet is dropped.
                _ = readGroup.wait(timeout: .now() + Self.secondsToWaitForReaders)

                timeoutLock.lock()
                let timedOut = didTimeOut
                timeoutLock.unlock()
                continuation.resume(returning: Output(
                    exitCode: process.terminationStatus,
                    standardOutput: String(decoding: collected.outputData, as: UTF8.self),
                    standardError: String(decoding: collected.errorData, as: UTF8.self),
                    didTimeOut: timedOut
                ))
            }
        }
    }
}

/// What the reader threads stored, behind a lock because a reader can still finish after the caller gave up on it.
private final class CollectedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var storedOutput = Data()
    private var storedError = Data()

    var outputData: Data { lock.lock(); defer { lock.unlock() }; return storedOutput }
    var errorData: Data { lock.lock(); defer { lock.unlock() }; return storedError }

    func storeOutput(_ data: Data) { lock.lock(); storedOutput = data; lock.unlock() }
    func storeError(_ data: Data) { lock.lock(); storedError = data; lock.unlock() }
}
