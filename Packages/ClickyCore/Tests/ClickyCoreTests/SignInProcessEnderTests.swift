import Foundation
import Testing
@testable import ClickyCore

/// Real child processes: each stand-in is a shell script named like the tool, run by this test process,
/// which stays up until it is ended. Nothing here touches a real `claude` or `codex`.
/// Tests run in parallel inside one process, and other suites run short stand-in logins as children of it,
/// so each test here uses a tool name of its own, or a parent process of its own, to leave those alone.
struct SignInProcessEnderTests {
    private func makeStandIn(named toolName: String, in folder: URL) throws -> URL {
        let scriptURL = folder.appendingPathComponent(toolName)
        try "#!/bin/sh\nwhile :; do sleep 1; done\n".write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    private func start(_ scriptURL: URL, arguments: [String]) throws -> Process {
        let process = Process()
        process.executableURL = scriptURL
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    private func waitUntilEnded(_ process: Process, seconds: Double = 5) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        return !process.isRunning
    }

    /// Waits until the process has `count` children running, which a loaded machine can take a while to do.
    private func waitForChildCount(of parent: Process, count: Int, seconds: Double = 10) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let lister = Process()
            lister.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            lister.arguments = ["-P", String(parent.processIdentifier)]
            let outputPipe = Pipe()
            lister.standardOutput = outputPipe
            try? lister.run()
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            lister.waitUntilExit()
            let childCount = String(decoding: outputData, as: UTF8.self).split(separator: "\n").count
            if childCount >= count { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("signin-ender-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func endsAClaudeLoginAndLeavesAClaudeSessionProcessRunning() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let toolName = "claude-\(UUID().uuidString)"
        let claude = try makeStandIn(named: toolName, in: folder)
        let login = try start(claude, arguments: ["auth", "login", "--claudeai"])
        let sessionProcess = try start(claude, arguments: ["-p", "--input-format", "stream-json"])
        defer { sessionProcess.terminate(); login.terminate() }

        let endedCount = SignInProcessEnder.endLoginProcesses(
            toolName: toolName, loginArguments: ["auth", "login"], parentProcessID: getpid())

        #expect(endedCount == 1)
        #expect(waitUntilEnded(login))
        #expect(sessionProcess.isRunning)
    }

    @Test func endsACodexLoginButNotACodexLogout() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let toolName = "codex-\(UUID().uuidString)"
        let codex = try makeStandIn(named: toolName, in: folder)
        let login = try start(codex, arguments: ["login"])
        let logout = try start(codex, arguments: ["logout"])
        defer { login.terminate(); logout.terminate() }

        let endedCount = SignInProcessEnder.endLoginProcesses(
            toolName: toolName, loginArguments: ["login"], parentProcessID: getpid())

        #expect(endedCount == 1)
        #expect(waitUntilEnded(login))
        #expect(logout.isRunning)
    }

    @Test func endAllSignInsEndsBothProvidersLoginsOfOneParent() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try makeStandIn(named: "claude", in: folder)
        _ = try makeStandIn(named: "codex", in: folder)
        // A parent shell of its own starts both logins, so only they match and no other suite's process is touched.
        let parentURL = folder.appendingPathComponent("parent.sh")
        try """
        #!/bin/sh
        "\(folder.path)/claude" auth login --claudeai &
        "\(folder.path)/codex" login &
        wait
        """.write(to: parentURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parentURL.path)
        let parent = try start(parentURL, arguments: [])
        defer { parent.terminate() }
        #expect(waitForChildCount(of: parent, count: 2))

        let endedCount = SignInProcessEnder.endAllSignIns(parentProcessID: parent.processIdentifier)

        #expect(endedCount == 2)
    }

    @Test func leavesALoginOwnedByAnotherProcessAlone() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let toolName = "claude-\(UUID().uuidString)"
        let login = try start(try makeStandIn(named: toolName, in: folder), arguments: ["auth", "login"])
        defer { login.terminate() }

        // A parent id that is not this process: the login is ours, so nothing matches.
        let endedCount = SignInProcessEnder.endLoginProcesses(
            toolName: toolName, loginArguments: ["auth", "login"], parentProcessID: getpid() + 1)

        #expect(endedCount == 0)
        #expect(login.isRunning)
    }

    @Test func endsNothingWhenNoLoginIsRunning() {
        let endedCount = SignInProcessEnder.endLoginProcesses(
            toolName: "claude-\(UUID().uuidString)", loginArguments: ["auth", "login"], parentProcessID: getpid())
        #expect(endedCount == 0)
    }
}
