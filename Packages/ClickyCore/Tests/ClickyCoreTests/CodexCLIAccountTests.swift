import Foundation
import Testing
@testable import ClickyCore

@Suite(.serialized)
struct CodexCLIAccountTests {
    @Test func accountIsChatGPT() throws {
        let standIn = try CodexStandIn()
        #expect(standIn.makeAccount().providerID == .chatgpt)
    }

    @Test func loggedInUsingChatGPTIsSignedIn() async throws {
        let standIn = try CodexStandIn()
        let status = await standIn.makeAccount().status()
        #expect(status.isSignedIn)
        #expect(status.accountLabel == "ChatGPT")
        #expect(standIn.recordedCalls() == [["login", "status"]])
    }

    @Test func notLoggedInIsNotSignedIn() async throws {
        let standIn = try CodexStandIn()
        standIn.setMode("notloggedin")
        let status = await standIn.makeAccount().status()
        #expect(!status.isSignedIn)
        #expect(status.accountLabel == nil)
    }

    @Test func apiKeyLoginIsNotSignedInForThisApp() async throws {
        let standIn = try CodexStandIn()
        standIn.setMode("apikey")
        let status = await standIn.makeAccount().status()
        #expect(!status.isSignedIn)
    }

    @Test func statusUsesTheAppsCodexHomeAndNoApiKey() async throws {
        let standIn = try CodexStandIn()
        let account = standIn.makeAccount(environment: ["OPENAI_API_KEY": "sk-test", "CODEX_HOME": "/elsewhere"])
        _ = await account.status()
        let environment = standIn.recordedEnvironment(callNumber: 1)
        #expect(environment["CODEX_HOME"] == standIn.locations.codexHomeDirectory.path)
        #expect(environment["OPENAI_API_KEY"] == nil)
    }

    @Test func signInRunsPlainLoginNeverWithApiKey() async throws {
        let standIn = try CodexStandIn()
        try await standIn.makeAccount().signIn()
        #expect(standIn.recordedCalls() == [["login"]])
        let environment = standIn.recordedEnvironment(callNumber: 1)
        #expect(environment["CODEX_HOME"] == standIn.locations.codexHomeDirectory.path)
    }

    @Test func signInThatFailsThrowsFailed() async throws {
        let standIn = try CodexStandIn()
        standIn.setMode("loginfails")
        do {
            try await standIn.makeAccount().signIn()
            Issue.record("expected a failure")
        } catch let failure as ProviderFailure {
            guard case .failed = failure else {
                Issue.record("wrong failure: \(failure)")
                return
            }
        }
    }

    @Test func signOutRunsLogoutWithTheAppsHome() async throws {
        let standIn = try CodexStandIn()
        try await standIn.makeAccount().signOut()
        #expect(standIn.recordedCalls() == [["logout"]])
        #expect(standIn.recordedEnvironment(callNumber: 1)["CODEX_HOME"] == standIn.locations.codexHomeDirectory.path)
    }

    @Test func modelListKeepsListedModelsInPriorityOrder() async throws {
        let standIn = try CodexStandIn()
        // Priority order is 1, 2, 4 for the visible models; the hidden one (priority 3) is left out.
        standIn.setModelCatalogJSON("""
        {"models":[
          {"slug":"model-four","visibility":"list","priority":4},
          {"slug":"model-hidden","visibility":"hide","priority":3},
          {"slug":"model-one","visibility":"list","priority":1},
          {"slug":"model-two","visibility":"list","priority":2}
        ]}
        """)
        let models = await standIn.makeAccount().availableModels()
        #expect(models == ["model-one", "model-two", "model-four"])
        #expect(standIn.recordedCalls() == [["debug", "models"]])
    }

    @Test func modelListIsEmptyWhenTheCatalogCannotBeRead() async throws {
        let standIn = try CodexStandIn()
        standIn.setModelCatalogJSON("not json")
        #expect(await standIn.makeAccount().availableModels().isEmpty)
    }
}
