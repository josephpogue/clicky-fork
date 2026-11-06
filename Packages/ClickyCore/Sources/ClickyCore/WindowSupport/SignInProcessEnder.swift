import Foundation

/// Ends `claude auth login` and `codex login` processes that this app started. Settings waits for the
/// browser sign-in inside the CLI process, so Cancel and Quit have to end that process from outside.
public enum SignInProcessEnder {
    /// How long a login gets to exit after the polite stop before it is forced.
    private static let graceSeconds = 2.0

    /// Ends every direct child of `parentProcessID` that is `toolName` run with `loginArguments`
    /// right after the tool name (so `claude auth login --claudeai` matches ["auth", "login"], while
    /// `claude -p` and `codex logout` do not). Returns how many it ended.
    @discardableResult
    public static func endLoginProcesses(toolName: String, loginArguments: [String], parentProcessID: Int32 = getpid()) -> Int {
        let matchingProcessIDs = runningProcesses()
            .filter { $0.parentProcessID == parentProcessID }
            .filter { isLogin(commandLine: $0.commandLine, toolName: toolName, loginArguments: loginArguments) }
            .map(\.processID)
        for processID in matchingProcessIDs {
            end(processID)
        }
        return matchingProcessIDs.count
    }

    /// Ends the Claude and ChatGPT logins together; used when the app quits.
    @discardableResult
    public static func endAllSignIns(parentProcessID: Int32 = getpid()) -> Int {
        endLoginProcesses(toolName: "claude", loginArguments: ["auth", "login"], parentProcessID: parentProcessID)
            + endLoginProcesses(toolName: "codex", loginArguments: ["login"], parentProcessID: parentProcessID)
    }

    // MARK: Matching

    private struct ProcessEntry {
        var processID: Int32
        var parentProcessID: Int32
        var commandLine: String
    }

    /// The tool may be run directly or through an interpreter (`/bin/sh /path/claude auth login`), and its
    /// folder may contain spaces, so the first word whose last path part is the tool name marks where the
    /// arguments start.
    private static func isLogin(commandLine: String, toolName: String, loginArguments: [String]) -> Bool {
        let words = commandLine.split(separator: " ").map(String.init)
        guard let toolIndex = words.firstIndex(where: { ($0 as NSString).lastPathComponent == toolName }) else { return false }
        let argumentWords = words[(toolIndex + 1)...]
        return Array(argumentWords.prefix(loginArguments.count)) == loginArguments
    }

    private static func runningProcesses() -> [ProcessEntry] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,command="]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: outputData, as: UTF8.self).split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let processID = Int32(parts[0]), let parentProcessID = Int32(parts[1]) else { return nil }
            return ProcessEntry(processID: processID, parentProcessID: parentProcessID, commandLine: String(parts[2]))
        }
    }

    // MARK: Ending

    private static func end(_ processID: Int32) {
        kill(processID, SIGTERM)
        let deadline = Date().addingTimeInterval(graceSeconds)
        // kill with signal 0 only checks whether the process still exists.
        while kill(processID, 0) == 0 && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if kill(processID, 0) == 0 {
            kill(processID, SIGKILL)
        }
    }
}
