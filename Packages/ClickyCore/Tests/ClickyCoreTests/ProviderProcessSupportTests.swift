import Foundation
import Testing
@testable import ClickyCore

struct ProviderProcessSupportTests {
    @Test func scrubbedEnvironmentDropsKeysAndLoginFoldersThenAddsTheGivenOnes() {
        let base = [
            "PATH": "/usr/bin",
            "ANTHROPIC_API_KEY": "x",
            "MY_API_KEY": "y",
            "CODEX_HOME": "/elsewhere",
            "HOME": "/h",
        ]

        let result = ProviderProcessSupport.scrubbedEnvironment(
            base: base,
            adding: ["CODEX_HOME": "/app/codex"]
        )

        #expect(result == ["PATH": "/usr/bin", "HOME": "/h", "CODEX_HOME": "/app/codex"])
    }

    @Test func scrubbedEnvironmentDropsEveryNamedTokenAndClaudeConfig() {
        let base = [
            "ANTHROPIC_AUTH_TOKEN": "a",
            "CLAUDE_CODE_OAUTH_TOKEN": "b",
            "OPENAI_API_KEY": "c",
            "CODEX_API_KEY": "d",
            "CLAUDE_CONFIG_DIR": "/e",
            "KEEP": "1",
        ]

        let result = ProviderProcessSupport.scrubbedEnvironment(base: base, adding: [:])

        #expect(result == ["KEEP": "1"])
    }

    @Test func overridePointingAtAnExecutableWins() throws {
        let sandbox = try makeSandboxFolder()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let overrideStub = try writeExecutableStub(at: sandbox.appendingPathComponent("custom/claude"))
        _ = try writeExecutableStub(at: sandbox.appendingPathComponent("home/.local/bin/claude"))

        let located = ProviderProcessSupport.locateExecutable(
            named: "claude",
            environmentOverrideKey: "CLICKY_CLAUDE_BIN",
            environment: ["CLICKY_CLAUDE_BIN": overrideStub.path],
            homeDirectory: sandbox.appendingPathComponent("home")
        )

        #expect(located?.path == overrideStub.path)
    }

    @Test func missingOverrideFallsBackToTheLocalBinFolder() throws {
        let sandbox = try makeSandboxFolder()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let home = sandbox.appendingPathComponent("home")
        let localStub = try writeExecutableStub(at: home.appendingPathComponent(".local/bin/claude"))

        let located = ProviderProcessSupport.locateExecutable(
            named: "claude",
            environmentOverrideKey: "CLICKY_CLAUDE_BIN",
            environment: ["CLICKY_CLAUDE_BIN": sandbox.appendingPathComponent("missing").path],
            homeDirectory: home
        )

        #expect(located?.path == localStub.path)
    }

    @Test func nothingFoundGivesNil() throws {
        let sandbox = try makeSandboxFolder()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let located = ProviderProcessSupport.locateExecutable(
            named: "clicky-no-such-cli-\(UUID().uuidString)",
            environmentOverrideKey: "CLICKY_NO_SUCH_BIN",
            environment: [:],
            homeDirectory: sandbox
        )

        #expect(located == nil)
    }

    private func makeSandboxFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("clicky-core-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func writeExecutableStub(at fileURL: URL) throws -> URL {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "#!/bin/sh\nexit 0\n".write(to: fileURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fileURL.path)
        return fileURL
    }
}
