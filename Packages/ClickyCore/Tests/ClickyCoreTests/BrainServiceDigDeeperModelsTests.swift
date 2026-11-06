import Testing

@testable import ClickyCore

@Suite("Brain service dig-deeper model lists")
struct BrainServiceDigDeeperModelsTests {
    @Test("Claude offers opus even before sign-in, when the row has no list")
    func claudeBeforeSignIn() {
        #expect(BrainServiceDigDeeperModels.claude(providerRowModels: []) == ["sonnet", "opus", "haiku"])
    }

    @Test("Claude uses the row's list and adds opus when the list lacks it")
    func claudeRowList() {
        #expect(BrainServiceDigDeeperModels.claude(providerRowModels: ["sonnet", "opus", "haiku"]) == ["sonnet", "opus", "haiku"])
        #expect(BrainServiceDigDeeperModels.claude(providerRowModels: ["sonnet"]) == ["sonnet", "opus"])
    }

    @Test("ChatGPT starts with the CLI default and then the row's models")
    func chatgpt() {
        #expect(BrainServiceDigDeeperModels.chatgpt(providerRowModels: []) == [""])
        #expect(BrainServiceDigDeeperModels.chatgpt(providerRowModels: ["gpt-a", "gpt-b"]) == ["", "gpt-a", "gpt-b"])
        #expect(BrainServiceDigDeeperModels.chatgpt(providerRowModels: ["", "gpt-a"]) == ["", "gpt-a"])
    }
}
