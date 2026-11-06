import Foundation
import Testing
@testable import ClickyCore

struct ClaudeCLIAccountTests {
    private func makeAccount(_ standIn: ClaudeStandIn) -> ClaudeCLIAccount {
        ClaudeCLIAccount(
            locations: standIn.locations(),
            executableURL: standIn.executableURL,
            environment: standIn.parentEnvironment
        )
    }

    @Test func statusIsSignedOutThenSignedInWithTheAccountLabelAfterSignIn() async throws {
        let standIn = try ClaudeStandIn()
        let account = makeAccount(standIn)

        let before = await account.status()
        #expect(before == ProviderAccountStatus(isSignedIn: false, accountLabel: nil))

        try await account.signIn()
        let after = await account.status()
        #expect(after == ProviderAccountStatus(isSignedIn: true, accountLabel: "person@example.test (max)"))
    }

    @Test func signInPicksTheClaudeSubscriptionLoginInTheAppsFolder() async throws {
        let standIn = try ClaudeStandIn()
        let account = makeAccount(standIn)

        try await account.signIn()

        let loginRun = try #require(standIn.authRuns.first)
        #expect(loginRun["argv"] as? [String] == ["auth", "login", "--claudeai"])
        #expect(loginRun["config"] as? String == standIn.locations().claudeConfigDirectory.path)
    }

    @Test func signOutLogsOutOfTheAppsFolderOnly() async throws {
        let standIn = try ClaudeStandIn()
        let account = makeAccount(standIn)
        try await account.signIn()

        try await account.signOut()

        #expect(await account.status().isSignedIn == false)
        let logoutRun = try #require(standIn.authRuns.first { ($0["argv"] as? [String])?[1] == "logout" })
        #expect(logoutRun["config"] as? String == standIn.locations().claudeConfigDirectory.path)
    }

    @Test func availableModelsAreTheAliasesTheCliAccepts() async throws {
        let standIn = try ClaudeStandIn()
        #expect(await makeAccount(standIn).availableModels() == ["sonnet", "opus", "haiku"])
    }

    @Test func missingCommandLineToolReadsAsSignedOutAndSignInSaysSo() async throws {
        let account = ClaudeCLIAccount(
            locations: AppDataLocations(root: FileManager.default.temporaryDirectory.appendingPathComponent("none-\(UUID().uuidString)")),
            executableURL: URL(fileURLWithPath: "/nonexistent/claude"),
            environment: [:]
        )

        #expect(await account.status() == ProviderAccountStatus(isSignedIn: false, accountLabel: nil))
        do {
            try await account.signIn()
            Issue.record("expected cliNotFound")
        } catch let failure as ProviderFailure {
            #expect(failure == .cliNotFound)
        }
    }
}
