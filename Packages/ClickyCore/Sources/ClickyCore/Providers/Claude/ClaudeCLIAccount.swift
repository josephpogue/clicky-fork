import Foundation

/// The app's own Claude sign-in: `claude auth login` and friends, run against the app's own login folder
/// so the user's own Claude Code login is never read, changed or signed out.
public final class ClaudeCLIAccount: ProviderAccount {
    public let providerID: ProviderID = .claude

    private let locations: AppDataLocations
    private let explicitExecutableURL: URL?
    private let parentEnvironment: [String: String]

    private static let quickCommandTimeoutSeconds = 30.0
    /// Sign-in waits for the user to finish in the browser.
    private static let signInTimeoutSeconds = 600.0

    /// The model names `--model` accepts. The CLI has no command that lists models, so these are its aliases,
    /// which always point at the latest model of each kind.
    private static let modelAliases = ["sonnet", "opus", "haiku"]

    public init(
        locations: AppDataLocations,
        executableURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.locations = locations
        explicitExecutableURL = executableURL
        parentEnvironment = environment
    }

    public func status() async -> ProviderAccountStatus {
        let signedOut = ProviderAccountStatus(isSignedIn: false, accountLabel: nil)
        guard let output = try? await runAuthCommand(["status", "--json"], timeoutSeconds: Self.quickCommandTimeoutSeconds),
              output.exitCode == 0,
              let status = try? JSONSerialization.jsonObject(with: Data(output.standardOutput.utf8)) as? [String: Any],
              status["loggedIn"] as? Bool == true else {
            return signedOut
        }
        let email = (status["email"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let plan = (status["subscriptionType"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let accountLabel: String?
        switch (email, plan) {
        case let (email?, plan?): accountLabel = "\(email) (\(plan))"
        case let (email?, nil): accountLabel = email
        case let (nil, plan?): accountLabel = plan
        case (nil, nil): accountLabel = nil
        }
        return ProviderAccountStatus(isSignedIn: true, accountLabel: accountLabel)
    }

    /// Opens the browser sign-in for the Claude subscription (not the Console, which bills API usage)
    /// and returns when the tool finishes.
    public func signIn() async throws {
        let output = try await runAuthCommand(["login", "--claudeai"], timeoutSeconds: Self.signInTimeoutSeconds)
        if output.didTimeOut {
            throw ProviderFailure.failed(message: "Claude sign-in timed out.")
        }
        if output.exitCode != 0 {
            throw ProviderFailure.failed(message: "Claude sign-in did not finish.")
        }
    }

    public func signOut() async throws {
        let output = try await runAuthCommand(["logout"], timeoutSeconds: Self.quickCommandTimeoutSeconds)
        if output.exitCode != 0 {
            throw ProviderFailure.failed(message: "Claude sign-out did not finish.")
        }
    }

    public func availableModels() async -> [String] {
        Self.modelAliases
    }

    private func runAuthCommand(_ arguments: [String], timeoutSeconds: Double) async throws -> ClaudeOneShotRunner.Output {
        let executableURL = try ClaudeCommandLine.resolveExecutable(explicit: explicitExecutableURL, environment: parentEnvironment)
        try? locations.createDirectories()
        return try await ClaudeOneShotRunner.run(
            executableURL: executableURL,
            arguments: ["auth"] + arguments,
            environment: ClaudeCommandLine.childEnvironment(base: parentEnvironment, locations: locations),
            workingDirectory: locations.providerWorkingDirectory,
            standardInputText: nil,
            timeoutSeconds: timeoutSeconds
        )
    }
}
