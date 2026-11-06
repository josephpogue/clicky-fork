import Foundation
import Testing
@testable import ClickyCore

/// Real files, real child processes; the only fake is the stand-in `codex` script.
@Suite(.serialized)
struct CodexCLIProviderTests {
    private func makeImage(named name: String, bytes: [UInt8], in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    private func makeTwoImageTurn(standIn: CodexStandIn, question: String = "where is the save button") throws -> QuestionTurn {
        let firstImage = try makeImage(named: "first.jpg", bytes: [0xFF, 0xD8, 0x01], in: standIn.folder)
        let secondImage = try makeImage(named: "second.jpg", bytes: [0xFF, 0xD8, 0x02], in: standIn.folder)
        return QuestionTurn(
            questionText: question,
            contextNote: "The user opened Notes a minute ago.",
            images: [
                TurnImage(fileURL: firstImage, label: "screen 1 of 2, primary focus, 1280x800 pixels", pixelWidth: 1280, pixelHeight: 800),
                TurnImage(fileURL: secondImage, label: "screen 2 of 2, 1440x900 pixels", pixelWidth: 1440, pixelHeight: 900),
            ]
        )
    }

    private func textOnlyTurn(_ question: String = "what is this") -> QuestionTurn {
        QuestionTurn(questionText: question, contextNote: "", images: [])
    }

    @Test func providerIsChatGPT() throws {
        let standIn = try CodexStandIn()
        #expect(standIn.makeProvider().providerID == .chatgpt)
    }

    // MARK: First turn

    @Test func firstAskRunsExecWithTheRequiredArguments() async throws {
        let standIn = try CodexStandIn()
        let provider = standIn.makeProvider()
        let turn = try makeTwoImageTurn(standIn: standIn)
        try await provider.startConversation(instructions: "Be brief.", model: "gpt-a", recap: nil)

        _ = try await provider.ask(turn, model: "gpt-a")

        let calls = standIn.recordedExecCalls()
        #expect(calls.count == 1)
        let arguments = try #require(calls.first)
        #expect(arguments.first == "exec")
        #expect(!arguments.contains("resume"))
        #expect(arguments.contains("--json"))
        #expect(arguments.contains("--skip-git-repo-check"))
        #expect(arguments.contains("--ignore-user-config"))
        #expect(arguments.contains("--ignore-rules"))
        let sandboxIndex = try #require(arguments.firstIndex(of: "-s"))
        #expect(arguments[sandboxIndex + 1] == "read-only")
        #expect(!arguments.contains("--with-api-key"))
        let workingDirectoryIndex = try #require(arguments.firstIndex(of: "-C"))
        #expect(arguments[workingDirectoryIndex + 1] == standIn.locations.providerWorkingDirectory.path)

        // The prompt (one argument holding the question) comes before the first -i; one -i per image, in order.
        let promptIndex = try #require(arguments.firstIndex { $0.contains("Question: where is the save button") })
        let imageFlagIndexes = arguments.indices.filter { arguments[$0] == "-i" }
        #expect(imageFlagIndexes.count == 2)
        #expect(promptIndex < imageFlagIndexes[0])
        #expect(arguments[imageFlagIndexes[0] + 1] == turn.images[0].fileURL.path)
        #expect(arguments[imageFlagIndexes[1] + 1] == turn.images[1].fileURL.path)
    }

    @Test func promptHoldsLabelsInOrderThenContextNoteThenQuestion() async throws {
        let standIn = try CodexStandIn()
        let provider = standIn.makeProvider()
        let turn = try makeTwoImageTurn(standIn: standIn)
        try await provider.startConversation(instructions: "", model: "gpt-a", recap: nil)

        _ = try await provider.ask(turn, model: "gpt-a")

        let arguments = try #require(standIn.recordedExecCalls().first)
        let prompt = try #require(arguments.first { $0.contains("Question: where is the save button") })
        let firstLabel = try #require(prompt.range(of: "screen 1 of 2, primary focus, 1280x800 pixels"))
        let secondLabel = try #require(prompt.range(of: "screen 2 of 2, 1440x900 pixels"))
        let contextNote = try #require(prompt.range(of: "The user opened Notes a minute ago."))
        let question = try #require(prompt.range(of: "Question: where is the save button"))
        #expect(firstLabel.lowerBound < secondLabel.lowerBound)
        #expect(secondLabel.lowerBound < contextNote.lowerBound)
        #expect(contextNote.lowerBound < question.lowerBound)
        #expect(prompt.hasSuffix("Question: where is the save button"))
    }

    @Test func emptyContextNoteAddsNoBlankSection() async throws {
        let standIn = try CodexStandIn()
        let provider = standIn.makeProvider()
        try await provider.startConversation(instructions: "", model: "gpt-a", recap: nil)

        _ = try await provider.ask(textOnlyTurn("what is this"), model: "gpt-a")

        let arguments = try #require(standIn.recordedExecCalls().first)
        #expect(arguments.contains("Question: what is this"))
        #expect(!arguments.contains("-i"))
    }

    @Test func childGetsTheAppsCodexHomeAndNoApiKey() async throws {
        let standIn = try CodexStandIn()
        let provider = standIn.makeProvider(environment: [
            "OPENAI_API_KEY": "sk-test",
            "CODEX_HOME": "/somewhere/else",
            "PATH": "/usr/bin:/bin",
        ])
        try await provider.startConversation(instructions: "", model: "gpt-a", recap: nil)

        _ = try await provider.ask(textOnlyTurn(), model: "gpt-a")

        // Call 1 is `codex login status`, call 2 is the exec.
        let execCallNumber = try #require(standIn.recordedCalls().firstIndex { $0.first == "exec" }) + 1
        let environment = standIn.recordedEnvironment(callNumber: execCallNumber)
        #expect(environment["CODEX_HOME"] == standIn.locations.codexHomeDirectory.path)
        #expect(environment["OPENAI_API_KEY"] == nil)
        let workingDirectory = try #require(standIn.recordedWorkingDirectory(callNumber: execCallNumber))
        #expect(URL(fileURLWithPath: workingDirectory).resolvingSymlinksInPath().path
            == standIn.locations.providerWorkingDirectory.resolvingSymlinksInPath().path)
    }

    @Test func answerComesBackUnchangedWithModelAndSeconds() async throws {
        let standIn = try CodexStandIn()
        let provider = standIn.makeProvider()
        try await provider.startConversation(instructions: "", model: "gpt-a", recap: nil)

        let answer = try await provider.ask(textOnlyTurn(), model: "gpt-a")

        #expect(answer.text == "Open the File menu and choose Save. [POINT:40,12:file menu]")
        #expect(answer.model == "gpt-a")
        #expect(answer.secondsToAnswer > 0)
        #expect(answer.secondsToAnswer < 10)
    }

    // MARK: Instructions

    @Test func instructionsGoInAsDeveloperInstructionsOnEveryTurn() async throws {
        let standIn = try CodexStandIn()
        let provider = standIn.makeProvider()
        // Quote and newline must be escaped as a TOML basic string: Say "hi" then newline then tab-free text.
        try await provider.startConversation(instructions: "Say \"hi\"\nthen stop.", model: "gpt-a", recap: nil)

        _ = try await provider.ask(textOnlyTurn("one"), model: "gpt-a")
        _ = try await provider.ask(textOnlyTurn("two"), model: "gpt-a")

        let expectedValue = #"developer_instructions="Say \"hi\"\nthen stop.""#
        for arguments in standIn.recordedExecCalls() {
            let configIndexes = arguments.indices.filter { arguments[$0] == "-c" }
            let configValues = configIndexes.map { arguments[$0 + 1] }
            #expect(configValues.contains(expectedValue))
        }
    }

    @Test func lowReasoningEffortIsRequested() async throws {
        let standIn = try CodexStandIn()
        let provider = standIn.makeProvider()
        try await provider.startConversation(instructions: "", model: "gpt-a", recap: nil)

        _ = try await provider.ask(textOnlyTurn(), model: "gpt-a")

        let arguments = try #require(standIn.recordedExecCalls().first)
        #expect(arguments.contains("model_reasoning_effort=low"))
    }

    // MARK: Second turn and model

    @Test func secondAskResumesTheThreadTheFirstOnePrinted() async throws {
        let standIn = try CodexStandIn()
        let provider = standIn.makeProvider()
        try await provider.startConversation(instructions: "", model: "gpt-a", recap: nil)

        _ = try await provider.ask(textOnlyTurn("one"), model: "gpt-a")
        _ = try await provider.ask(textOnlyTurn("two"), model: "gpt-a")

        let execCalls = standIn.recordedExecCalls()
        #expect(execCalls.count == 2)
        // The stand-in names the thread after the call that created it: call 1 is login status, call 2 the first exec.
        let printedThreadID = "thread-standin-2"
        let resumeArguments = execCalls[1]
        #expect(resumeArguments[0] == "exec")
        #expect(resumeArguments[1] == "resume")
        let threadIndex = try #require(resumeArguments.firstIndex(of: printedThreadID))
        let promptIndex = try #require(resumeArguments.firstIndex(of: "Question: two"))
        #expect(threadIndex < promptIndex)
        #expect(!resumeArguments.contains("--with-api-key"))
    }

    @Test func modelChangeApplyFromTheNextQuestion() async throws {
        let standIn = try CodexStandIn()
        let provider = standIn.makeProvider()
        try await provider.startConversation(instructions: "", model: "a", recap: nil)

        _ = try await provider.ask(textOnlyTurn("one"), model: "a")
        let second = try await provider.ask(textOnlyTurn("two"), model: "b")

        let execCalls = standIn.recordedExecCalls()
        let firstModelIndex = try #require(execCalls[0].firstIndex(of: "-m"))
        #expect(execCalls[0][firstModelIndex + 1] == "a")
        let secondModelIndex = try #require(execCalls[1].firstIndex(of: "-m"))
        #expect(execCalls[1][secondModelIndex + 1] == "b")
        #expect(execCalls[1].contains("resume"))
        #expect(second.model == "b")
    }

    // MARK: Start and end of a conversation

    @Test func startingAgainForgetsTheThread() async throws {
        let standIn = try CodexStandIn()
        let provider = standIn.makeProvider()
        try await provider.startConversation(instructions: "", model: "a", recap: nil)
        _ = try await provider.ask(textOnlyTurn("one"), model: "a")

        try await provider.startConversation(instructions: "", model: "a", recap: nil)
        _ = try await provider.ask(textOnlyTurn("two"), model: "a")

        let execCalls = standIn.recordedExecCalls()
        #expect(execCalls.count == 2)
        #expect(!execCalls[1].contains("resume"))
    }

    @Test func recapIsSentAsTheFirstTurnOfTheNewThreadAndTheNextAskResumesIt() async throws {
        let standIn = try CodexStandIn()
        let provider = standIn.makeProvider()

        try await provider.startConversation(
            instructions: "Be brief.",
            model: "a",
            recap: "Q: how do I save? A: Press Command S."
        )
        _ = try await provider.ask(textOnlyTurn("and print?"), model: "a")

        let execCalls = standIn.recordedExecCalls()
        #expect(execCalls.count == 2)
        let recapPrompt = try #require(execCalls[0].first { $0.contains("Earlier in this session") })
        #expect(recapPrompt.contains("Q: how do I save? A: Press Command S."))
        #expect(!execCalls[0].contains("resume"))
        // The recap turn was call 2 (call 1 was the login check), so its thread is thread-standin-2.
        #expect(execCalls[1].contains("resume"))
        #expect(execCalls[1].contains("thread-standin-2"))
    }

    @Test func summarizeIsAOneOffTextRunThatKeepsNoThread() async throws {
        let standIn = try CodexStandIn()
        let provider = standIn.makeProvider()
        try await provider.startConversation(instructions: "", model: "a", recap: nil)

        let summary = try await provider.summarize("The user saved a file.", instructions: "Summarize in one line.", model: "a")
        _ = try await provider.ask(textOnlyTurn("one"), model: "a")

        #expect(summary == "Open the File menu and choose Save. [POINT:40,12:file menu]")
        let execCalls = standIn.recordedExecCalls()
        #expect(execCalls.count == 2)
        #expect(execCalls[0].contains("The user saved a file."))
        #expect(execCalls[0].contains(#"developer_instructions="Summarize in one line.""#))
        #expect(!execCalls[0].contains("-i"))
        // The summary kept no thread, so the next question starts a new one.
        #expect(!execCalls[1].contains("resume"))
    }

    // MARK: Failures

    @Test func usageLimitWordingBecomesUsageLimitReached() async throws {
        let standIn = try CodexStandIn()
        standIn.setMode("limit")
        let provider = standIn.makeProvider()
        try await provider.startConversation(instructions: "", model: "a", recap: nil)

        do {
            _ = try await provider.ask(textOnlyTurn(), model: "a")
            Issue.record("expected a usage limit failure")
        } catch let failure as ProviderFailure {
            guard case .usageLimitReached(let message) = failure else {
                Issue.record("wrong failure: \(failure)")
                return
            }
            #expect(message.contains("hit your usage limit"))
        }
    }

    @Test func notLoggedInBecomesNotSignedIn() async throws {
        let standIn = try CodexStandIn()
        standIn.setMode("notloggedin")
        let provider = standIn.makeProvider()
        try await provider.startConversation(instructions: "", model: "a", recap: nil)

        await #expect(throws: ProviderFailure.notSignedIn) {
            _ = try await provider.ask(textOnlyTurn(), model: "a")
        }
    }

    @Test func unauthorizedRepliesBecomeNotSignedInAndStopTheProcessEarly() async throws {
        let standIn = try CodexStandIn()
        standIn.setMode("unauthorized")
        let provider = standIn.makeProvider(answerTimeoutSeconds: 20)
        try await provider.startConversation(instructions: "", model: "a", recap: nil)

        let started = Date()
        await #expect(throws: ProviderFailure.notSignedIn) {
            _ = try await provider.ask(textOnlyTurn(), model: "a")
        }
        // The stand-in would sleep 1000 s; the provider must not wait for the 20 s timeout.
        #expect(Date().timeIntervalSince(started) < 10)
        let execCallNumber = try #require(standIn.recordedCalls().firstIndex { $0.first == "exec" }) + 1
        let processID = try #require(standIn.recordedProcessID(callNumber: execCallNumber))
        #expect(await CodexStandIn.waitForProcessToExit(processID, seconds: 3))
    }

    @Test func apiKeyLoginMakesAskThrowNotSubscriptionLogin() async throws {
        let standIn = try CodexStandIn()
        standIn.setMode("apikey")
        let provider = standIn.makeProvider()
        try await provider.startConversation(instructions: "", model: "a", recap: nil)

        do {
            _ = try await provider.ask(textOnlyTurn(), model: "a")
            Issue.record("expected notSubscriptionLogin")
        } catch let failure as ProviderFailure {
            guard case .notSubscriptionLogin(let detail) = failure else {
                Issue.record("wrong failure: \(failure)")
                return
            }
            #expect(detail.contains("API key"))
        }
        // No exec was ever started on an API key login.
        #expect(standIn.recordedExecCalls().isEmpty)
    }

    @Test func hangingCodexTimesOutAsFailedAndTheProcessIsGone() async throws {
        let standIn = try CodexStandIn()
        standIn.setMode("hang")
        let provider = standIn.makeProvider(answerTimeoutSeconds: 1)
        try await provider.startConversation(instructions: "", model: "a", recap: nil)

        let started = Date()
        do {
            _ = try await provider.ask(textOnlyTurn(), model: "a")
            Issue.record("expected a timeout failure")
        } catch let failure as ProviderFailure {
            guard case .failed(let message) = failure else {
                Issue.record("wrong failure: \(failure)")
                return
            }
            #expect(!message.isEmpty)
            #expect(!message.contains("\n"))
        }
        #expect(Date().timeIntervalSince(started) < 4)
        let execCallNumber = try #require(standIn.recordedCalls().firstIndex { $0.first == "exec" }) + 1
        let processID = try #require(standIn.recordedProcessID(callNumber: execCallNumber))
        #expect(await CodexStandIn.waitForProcessToExit(processID, seconds: 3))
    }

    @Test func missingExecutableIsCliNotFound() async throws {
        let standIn = try CodexStandIn()
        let provider = CodexCLIProvider(
            locations: standIn.locations,
            executableURL: standIn.folder.appendingPathComponent("no-such-codex"),
            environment: [:]
        )
        try await provider.startConversation(instructions: "", model: "a", recap: nil)

        await #expect(throws: ProviderFailure.cliNotFound) {
            _ = try await provider.ask(textOnlyTurn(), model: "a")
        }
    }

    @Test func endConversationStopsARunningProcess() async throws {
        let standIn = try CodexStandIn()
        standIn.setMode("hang")
        let provider = standIn.makeProvider(answerTimeoutSeconds: 60)
        try await provider.startConversation(instructions: "", model: "a", recap: nil)

        let pendingAsk = Task { () -> Bool in
            do {
                _ = try await provider.ask(textOnlyTurn(), model: "a")
                return false
            } catch {
                return true
            }
        }
        // Call 1 is the login check, call 2 is the exec that hangs.
        #expect(await standIn.waitForCall(callNumber: 2, seconds: 5))
        let processID = try #require(standIn.recordedProcessID(callNumber: 2))

        await provider.endConversation()

        #expect(await CodexStandIn.waitForProcessToExit(processID, seconds: 3))
        #expect(await pendingAsk.value)
    }

    @Test func nothingTheProviderRunsEverUsesAnApiKey() async throws {
        let standIn = try CodexStandIn()
        let provider = standIn.makeProvider(environment: ["CODEX_API_KEY": "x", "OPENAI_API_KEY": "sk-test"])
        try await provider.startConversation(instructions: "", model: "a", recap: "Q: a A: b")
        _ = try await provider.ask(textOnlyTurn(), model: "a")
        _ = try await provider.summarize("text", instructions: "", model: "a")

        for (index, arguments) in standIn.recordedCalls().enumerated() {
            #expect(!arguments.contains("--with-api-key"))
            let environment = standIn.recordedEnvironment(callNumber: index + 1)
            #expect(environment["OPENAI_API_KEY"] == nil)
            #expect(environment["CODEX_API_KEY"] == nil)
        }
    }
}
