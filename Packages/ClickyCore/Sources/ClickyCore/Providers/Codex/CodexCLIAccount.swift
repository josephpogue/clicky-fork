import Foundation

/// Signs the user in to ChatGPT through the official `codex` tool, in the app's own `CODEX_HOME`.
public final class CodexCLIAccount: ProviderAccount, @unchecked Sendable {
    public let providerID: ProviderID = .chatgpt

    private let setup: CodexCLISetup
    private let runner = CodexProcessRunner()
    /// The browser sign-in waits for the user, so it gets a long limit.
    private let signInTimeoutSeconds: Double = 600

    public init(
        locations: AppDataLocations,
        executableURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        setup = CodexCLISetup(locations: locations, executableURLOverride: executableURL, parentEnvironment: environment)
    }

    /// Signed in only for a ChatGPT login. An API key login counts as not signed in, because the app is subscription only.
    public func status() async -> ProviderAccountStatus {
        guard let executableURL = try? setup.resolveExecutable(), (try? setup.prepareDirectories()) != nil else {
            return ProviderAccountStatus(isSignedIn: false, accountLabel: nil)
        }
        let state = await setup.readLoginState(runner: runner, executableURL: executableURL)
        if state == .chatGPT {
            return ProviderAccountStatus(isSignedIn: true, accountLabel: "ChatGPT")
        }
        return ProviderAccountStatus(isSignedIn: false, accountLabel: nil)
    }

    /// Runs `codex login`, which opens the browser for the ChatGPT sign-in, and waits for it to finish.
    /// It never uses `--with-api-key`.
    public func signIn() async throws {
        let executableURL = try setup.resolveExecutable()
        try setup.prepareDirectories()
        let result = await runner.run(
            executableURL: executableURL,
            arguments: ["login"],
            environment: setup.childEnvironment,
            workingDirectory: setup.locations.providerWorkingDirectory,
            timeoutSeconds: signInTimeoutSeconds
        )
        if result.couldNotStart { throw ProviderFailure.cliNotFound }
        if result.didTimeOut { throw ProviderFailure.failed(message: "The ChatGPT sign-in took too long. Try again.") }
        if result.exitStatus != 0 {
            throw ProviderFailure.failed(message: "The ChatGPT sign-in did not finish.")
        }
    }

    public func signOut() async throws {
        let executableURL = try setup.resolveExecutable()
        try setup.prepareDirectories()
        let result = await runner.run(
            executableURL: executableURL,
            arguments: ["logout"],
            environment: setup.childEnvironment,
            workingDirectory: setup.locations.providerWorkingDirectory,
            timeoutSeconds: 30
        )
        if result.couldNotStart { throw ProviderFailure.cliNotFound }
        if result.didTimeOut || result.exitStatus != 0 {
            throw ProviderFailure.failed(message: "Could not sign out of ChatGPT.")
        }
    }

    /// The models in `codex debug models` whose `visibility` is `"list"`, best first (by `priority`).
    /// Entries marked `"hide"` are internal helpers (auto-review and similar) that a person is not meant to pick.
    /// The catalog is fetched for the signed-in account, so a ChatGPT login lists what it can use.
    public func availableModels() async -> [String] {
        guard let executableURL = try? setup.resolveExecutable(), (try? setup.prepareDirectories()) != nil else { return [] }
        let result = await runner.run(
            executableURL: executableURL,
            arguments: ["debug", "models"],
            environment: setup.childEnvironment,
            workingDirectory: setup.locations.providerWorkingDirectory,
            timeoutSeconds: 30
        )
        if result.couldNotStart || result.didTimeOut || result.exitStatus != 0 { return [] }
        let catalogText = result.outputLines.joined(separator: "\n")
        guard let data = catalogText.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = object["models"] as? [[String: Any]] else { return [] }

        let listedModels: [(slug: String, priority: Int)] = entries.compactMap { entry in
            guard let slug = entry["slug"] as? String, entry["visibility"] as? String == "list" else { return nil }
            return (slug, entry["priority"] as? Int ?? Int.max)
        }
        return listedModels.sorted { $0.priority < $1.priority }.map(\.slug)
    }
}
