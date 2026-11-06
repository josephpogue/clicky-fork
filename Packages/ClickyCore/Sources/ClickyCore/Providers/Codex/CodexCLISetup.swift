import Foundation

/// What the provider and the account share: where the `codex` binary is, what environment it gets,
/// and how to read `codex login status`.
struct CodexCLISetup: Sendable {
    let locations: AppDataLocations
    let executableURLOverride: URL?
    let parentEnvironment: [String: String]

    /// The binary: the given one, else `$CLICKY_CODEX_BIN`, else the usual install folders.
    func resolveExecutable() throws -> URL {
        if let executableURLOverride {
            guard FileManager.default.isExecutableFile(atPath: executableURLOverride.path) else {
                throw ProviderFailure.cliNotFound
            }
            return executableURLOverride
        }
        guard let found = ProviderProcessSupport.locateExecutable(
            named: "codex",
            environmentOverrideKey: "CLICKY_CODEX_BIN",
            environment: parentEnvironment,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        ) else {
            throw ProviderFailure.cliNotFound
        }
        return found
    }

    /// No API keys or inherited logins; `CODEX_HOME` is the app's own folder, so the user's own Codex is never touched.
    var childEnvironment: [String: String] {
        ProviderProcessSupport.scrubbedEnvironment(
            base: parentEnvironment,
            adding: ["CODEX_HOME": locations.codexHomeDirectory.path]
        )
    }

    /// Makes sure the working folder and `CODEX_HOME` exist before a process is started in them.
    func prepareDirectories() throws {
        do {
            try locations.createDirectories()
        } catch {
            throw ProviderFailure.failed(message: "Could not create the app's folders.")
        }
    }

    func readLoginState(runner: CodexProcessRunner, executableURL: URL) async -> CodexLoginState {
        let result = await runner.run(
            executableURL: executableURL,
            arguments: ["login", "status"],
            environment: childEnvironment,
            workingDirectory: locations.providerWorkingDirectory,
            timeoutSeconds: 15
        )
        if result.couldNotStart || result.didTimeOut { return .unknown }
        let combinedText = result.outputLines.joined(separator: "\n") + "\n" + result.standardErrorText
        return CodexOutputParsing.parseLoginState(from: combinedText)
    }
}
