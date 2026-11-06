import Foundation

/// Runs a command line tool to completion and collects what it printed. Used for `claude auth ...` and the summary.
enum ClaudeOneShotRunner {
    struct Output {
        var exitCode: Int32
        var standardOutput: String
        var standardError: String
        var didTimeOut: Bool
    }

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
                var outputData = Data()
                var errorData = Data()
                readGroup.enter()
                DispatchQueue.global().async {
                    outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    readGroup.leave()
                }
                readGroup.enter()
                DispatchQueue.global().async {
                    errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
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
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: timeoutItem)

                process.waitUntilExit()
                timeoutItem.cancel()
                readGroup.wait()

                timeoutLock.lock()
                let timedOut = didTimeOut
                timeoutLock.unlock()
                continuation.resume(returning: Output(
                    exitCode: process.terminationStatus,
                    standardOutput: String(decoding: outputData, as: UTF8.self),
                    standardError: String(decoding: errorData, as: UTF8.self),
                    didTimeOut: timedOut
                ))
            }
        }
    }
}
