import Foundation
import Testing
@testable import ClickyCore

struct ClaudeCLIProviderTests {
    private let firstImageBytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01, 0x02, 0x03])
    private let secondImageBytes = Data([0xFF, 0xD8, 0xFF, 0xE1, 0x0A, 0x0B])

    private func makeProvider(
        _ standIn: ClaudeStandIn,
        answerTimeoutSeconds: Double = 20
    ) -> ClaudeCLIProvider {
        ClaudeCLIProvider(
            locations: standIn.locations(),
            executableURL: standIn.executableURL,
            environment: standIn.parentEnvironment,
            answerTimeoutSeconds: answerTimeoutSeconds
        )
    }

    private func writeTwoImages(into folder: URL) throws -> [TurnImage] {
        let firstURL = folder.appendingPathComponent("one.jpg")
        let secondURL = folder.appendingPathComponent("two.jpg")
        try firstImageBytes.write(to: firstURL)
        try secondImageBytes.write(to: secondURL)
        return [
            TurnImage(fileURL: firstURL, label: "screen 1 of 2, primary focus, 1280x800 pixels", pixelWidth: 1280, pixelHeight: 800),
            TurnImage(fileURL: secondURL, label: "screen 2 of 2, 1280x800 pixels", pixelWidth: 1280, pixelHeight: 800),
        ]
    }

    private func textQuestion(_ text: String) -> QuestionTurn {
        QuestionTurn(questionText: text, contextNote: "", images: [])
    }

    private func textOf(_ block: [String: Any]) -> String {
        block["text"] as? String ?? ""
    }

    @Test func startsOneProcessWithTheSubscriptionOnlyFlagsAndNeverBare() async throws {
        let standIn = try ClaudeStandIn()
        let provider = makeProvider(standIn)

        try await provider.startConversation(instructions: "Answer briefly.", model: "sonnet", recap: "Earlier in this session: nothing yet.")
        // Starting sends no line, so nothing makes start wait for the child; wait for Python to record it.
        await standIn.waitForStarts(count: 1)
        await provider.endConversation()

        #expect(standIn.starts.count == 1)
        let argv = standIn.argv(ofStart: 0)
        #expect(argv.contains("-p"))
        #expect(argv.contains("--bare") == false)
        for (flag, value) in [
            ("--input-format", "stream-json"),
            ("--output-format", "stream-json"),
            ("--model", "sonnet"),
            ("--tools", ""),
            ("--system-prompt", "Answer briefly."),
            ("--setting-sources", ""),
        ] {
            let flagIndex = try #require(argv.firstIndex(of: flag), "missing \(flag)")
            #expect(argv[flagIndex + 1] == value)
        }
        #expect(argv.contains("--strict-mcp-config"))
        #expect(argv.contains("--disable-slash-commands"))
        #expect(argv.contains("--no-session-persistence"))
        #expect(argv.contains("--safe-mode"))
    }

    @Test func childGetsTheAppsLoginFolderAndNoApiKeyOrBaseUrl() async throws {
        let standIn = try ClaudeStandIn()
        let provider = makeProvider(standIn)

        try await provider.startConversation(instructions: "x", model: "sonnet", recap: "Earlier in this session: nothing.")
        await standIn.waitForStarts(count: 1)
        await provider.endConversation()

        let childEnvironment = standIn.environment(ofStart: 0)
        #expect(childEnvironment["CLAUDE_CONFIG_DIR"] == standIn.locations().claudeConfigDirectory.path)
        #expect(childEnvironment["ANTHROPIC_API_KEY"] == nil)
        #expect(childEnvironment["ANTHROPIC_BASE_URL"] == nil)
        #expect(childEnvironment["PATH"] != nil)
    }

    @Test func conversationChildGetsOnlyAllowedVariablesAndTheAppsLoginFolder() async throws {
        let standIn = try ClaudeStandIn()
        let provider = makeProvider(standIn)

        try await provider.startConversation(instructions: "x", model: "sonnet", recap: nil)
        await standIn.waitForStarts(count: 1)
        await provider.endConversation()

        let childEnvironment = standIn.environment(ofStart: 0)
        #expect(ClaudeStandIn.unexpectedVariableNames(in: childEnvironment) == [])
        for name in ClaudeStandIn.variablesThatMustNotReachTheChild.keys where name != "CLAUDE_CONFIG_DIR" {
            #expect(childEnvironment[name] == nil, "leaked \(name)")
        }
        #expect(childEnvironment["CLAUDE_CONFIG_DIR"] == standIn.locations().claudeConfigDirectory.path)
    }

    @Test func summaryChildGetsOnlyAllowedVariablesAndTheAppsLoginFolder() async throws {
        let standIn = try ClaudeStandIn()
        let provider = makeProvider(standIn)

        _ = try await provider.summarize("text", instructions: "Summarize.", model: "haiku")

        let childEnvironment = standIn.environment(ofStart: 0)
        #expect(ClaudeStandIn.unexpectedVariableNames(in: childEnvironment) == [])
        for name in ClaudeStandIn.variablesThatMustNotReachTheChild.keys where name != "CLAUDE_CONFIG_DIR" {
            #expect(childEnvironment[name] == nil, "leaked \(name)")
        }
        #expect(childEnvironment["CLAUDE_CONFIG_DIR"] == standIn.locations().claudeConfigDirectory.path)
    }

    @Test func startingWithARecapSendsNothingUntilTheFirstQuestionCarriesIt() async throws {
        let standIn = try ClaudeStandIn()
        let provider = makeProvider(standIn)

        try await provider.startConversation(instructions: "x", model: "sonnet", recap: "Earlier in this session: the user asked about Safari.")

        // Nothing goes to Claude between questions: the process is up and has been sent no line at all.
        await standIn.waitForStarts(count: 1)
        #expect(standIn.starts.count == 1)
        #expect(standIn.stdinLines.isEmpty)

        _ = try await provider.ask(textQuestion("where is the tab bar"), model: "sonnet")
        await provider.endConversation()

        let lines = standIn.userMessages
        #expect(lines.count == 1)
        let blocks = standIn.contentBlocks(ofUserLine: lines[0])
        #expect(textOf(blocks[0]) == "Earlier in this session: the user asked about Safari.")
        #expect(textOf(blocks[1]) == "Question: where is the tab bar")
    }

    @Test func recapIsNotRepeatedOnTheSecondQuestion() async throws {
        let standIn = try ClaudeStandIn()
        let provider = makeProvider(standIn)
        try await provider.startConversation(instructions: "x", model: "sonnet", recap: "Earlier in this session: a recap.")

        _ = try await provider.ask(textQuestion("first"), model: "sonnet")
        _ = try await provider.ask(textQuestion("second"), model: "sonnet")
        await provider.endConversation()

        let lines = standIn.userMessages
        #expect(lines.count == 2)
        #expect(standIn.contentBlocks(ofUserLine: lines[1]).map(textOf) == ["Question: second"])
    }

    @Test func askSendsLabelledImagesThenNoteThenQuestionAndReturnsTheAnswerUnchanged() async throws {
        let standIn = try ClaudeStandIn()
        let provider = makeProvider(standIn)
        let images = try writeTwoImages(into: standIn.directory)
        try await provider.startConversation(instructions: "x", model: "sonnet", recap: nil)

        let answer = try await provider.ask(
            QuestionTurn(questionText: "where is the save button", contextNote: "The user opened a document.", images: images),
            model: "sonnet"
        )
        await provider.endConversation()

        #expect(answer.text == "The Save button is at the top right. [POINT:1180,40:save button]")
        #expect(answer.model == "sonnet")
        #expect(answer.secondsToAnswer > 0)

        let lines = standIn.userMessages
        #expect(lines.count == 1)
        let blocks = standIn.contentBlocks(ofUserLine: lines[0])
        // label, image, label, image, context note, question
        #expect(blocks.count == 6)
        #expect(blocks.map { $0["type"] as? String } == ["text", "image", "text", "image", "text", "text"])
        #expect(textOf(blocks[0]) == images[0].label)
        #expect(textOf(blocks[2]) == images[1].label)
        for (blockIndex, expectedBytes) in [(1, firstImageBytes), (3, secondImageBytes)] {
            let source = try #require(blocks[blockIndex]["source"] as? [String: Any])
            #expect(source["type"] as? String == "base64")
            #expect(source["media_type"] as? String == "image/jpeg")
            #expect(Data(base64Encoded: source["data"] as? String ?? "") == expectedBytes)
        }
        #expect(textOf(blocks[4]) == "The user opened a document.")
        #expect(textOf(blocks[5]) == "Question: where is the save button")
    }

    @Test func emptyContextNoteIsLeftOut() async throws {
        let standIn = try ClaudeStandIn()
        let provider = makeProvider(standIn)
        try await provider.startConversation(instructions: "x", model: "sonnet", recap: nil)

        _ = try await provider.ask(textQuestion("what is this"), model: "sonnet")
        await provider.endConversation()

        let blocks = standIn.contentBlocks(ofUserLine: standIn.userMessages[0])
        #expect(blocks.count == 1)
        #expect(textOf(blocks[0]) == "Question: what is this")
    }

    @Test func secondAskGoesToTheSameProcess() async throws {
        let standIn = try ClaudeStandIn()
        let provider = makeProvider(standIn)
        try await provider.startConversation(instructions: "x", model: "sonnet", recap: nil)

        _ = try await provider.ask(textQuestion("first question"), model: "sonnet")
        _ = try await provider.ask(textQuestion("second question"), model: "sonnet")
        await provider.endConversation()

        #expect(standIn.starts.count == 1)
        let lines = standIn.userMessages
        #expect(lines.count == 2)
        #expect(Set(lines.compactMap { $0["pid"] as? Int }) == [standIn.pid(ofStart: 0)])
        #expect(textOf(standIn.contentBlocks(ofUserLine: lines[0])[0]) == "Question: first question")
        #expect(textOf(standIn.contentBlocks(ofUserLine: lines[1])[0]) == "Question: second question")
    }

    @Test func usageLimitAnswerBecomesUsageLimitReached() async throws {
        let standIn = try ClaudeStandIn(mode: .limit)
        let provider = makeProvider(standIn)
        try await provider.startConversation(instructions: "x", model: "sonnet", recap: nil)

        do {
            _ = try await provider.ask(textQuestion("anything"), model: "sonnet")
            Issue.record("expected a usage limit failure")
        } catch let failure as ProviderFailure {
            #expect(failure == .usageLimitReached(message: "You've hit your limit \u{00B7} resets 3pm"))
        }
        await provider.endConversation()
    }

    @Test func apiKeyLoginIsRejectedAndTheProcessStopped() async throws {
        let standIn = try ClaudeStandIn(mode: .apiKey)
        let provider = makeProvider(standIn)

        do {
            try await provider.startConversation(instructions: "x", model: "sonnet", recap: nil)
            _ = try await provider.ask(textQuestion("anything"), model: "sonnet")
            Issue.record("expected a not-subscription-login failure")
        } catch let failure as ProviderFailure {
            guard case .notSubscriptionLogin(let detail) = failure else {
                Issue.record("wrong failure \(failure)")
                return
            }
            #expect(detail.contains("ANTHROPIC_API_KEY"))
        }
        #expect(await standIn.waitForProcessToBeGone(pid: standIn.pid(ofStart: 0)))
    }

    @Test func noLoginBecomesNotSignedIn() async throws {
        let standIn = try ClaudeStandIn(mode: .notLoggedIn)
        let provider = makeProvider(standIn)
        try await provider.startConversation(instructions: "x", model: "sonnet", recap: nil)

        do {
            _ = try await provider.ask(textQuestion("anything"), model: "sonnet")
            Issue.record("expected a not-signed-in failure")
        } catch let failure as ProviderFailure {
            #expect(failure == .notSignedIn)
        }
        await provider.endConversation()
    }

    @Test func silentProcessTimesOutWithinThreeSecondsAndIsGone() async throws {
        let standIn = try ClaudeStandIn(mode: .silent)
        let provider = makeProvider(standIn, answerTimeoutSeconds: 1)
        try await provider.startConversation(instructions: "x", model: "sonnet", recap: nil)
        // The one-second clock should measure the silence, not how long a loaded Mac takes to start Python.
        await standIn.waitForStarts(count: 1)

        let startedAt = Date()
        do {
            _ = try await provider.ask(textQuestion("anything"), model: "sonnet")
            Issue.record("expected a timeout failure")
        } catch let failure as ProviderFailure {
            guard case .failed = failure else {
                Issue.record("wrong failure \(failure)")
                return
            }
        }
        #expect(Date().timeIntervalSince(startedAt) < 3)
        #expect(await standIn.waitForProcessToBeGone(pid: standIn.pid(ofStart: 0)))
    }

    @Test func differentModelIsChangedInPlaceOnTheSameProcess() async throws {
        let standIn = try ClaudeStandIn()
        let provider = makeProvider(standIn)
        try await provider.startConversation(instructions: "x", model: "sonnet", recap: nil)
        _ = try await provider.ask(textQuestion("first question"), model: "sonnet")

        let answer = try await provider.ask(textQuestion("second question"), model: "opus")
        await provider.endConversation()

        #expect(answer.model == "opus")
        #expect(standIn.starts.count == 1)
        let changeRequests = standIn.stdinLines.compactMap { ($0["message"] as? [String: Any]) }
            .filter { $0["type"] as? String == "control_request" }
        #expect(changeRequests.count == 1)
        // The exact line the Claude Agent SDK sends: the request id is the provider's first, "clicky-model-1".
        let expectedLine: NSDictionary = [
            "type": "control_request",
            "request_id": "clicky-model-1",
            "request": ["subtype": "set_model", "model": "opus"],
        ]
        #expect(NSDictionary(dictionary: changeRequests[0]) == expectedLine)
    }

    @Test func refusedModelChangeRestartsWithTheEarlierTurnsAsText() async throws {
        let standIn = try ClaudeStandIn(mode: .refuseModelChange)
        let provider = makeProvider(standIn)
        try await provider.startConversation(instructions: "x", model: "sonnet", recap: nil)
        _ = try await provider.ask(textQuestion("first question"), model: "sonnet")

        let answer = try await provider.ask(textQuestion("second question"), model: "opus")
        await provider.endConversation()

        #expect(answer.model == "opus")
        #expect(standIn.starts.count == 2)
        let secondArgv = standIn.argv(ofStart: 1)
        let modelIndex = try #require(secondArgv.firstIndex(of: "--model"))
        #expect(secondArgv[modelIndex + 1] == "opus")
        // The first process is gone and the new one's first user line carries the earlier question.
        #expect(await standIn.waitForProcessToBeGone(pid: standIn.pid(ofStart: 0)))
        let newProcessLines = standIn.userMessages.filter { $0["pid"] as? Int == standIn.pid(ofStart: 1) }
        #expect(newProcessLines.count == 1)
        let allText = standIn.contentBlocks(ofUserLine: newProcessLines[0]).map(textOf).joined(separator: "\n")
        #expect(allText.contains("first question"))
        #expect(allText.contains("The Save button is at the top right."))
        #expect(allText.contains("Question: second question"))
    }

    @Test func processThatDiedIsRestartedOnTheNextAskWithTheEarlierTurns() async throws {
        let standIn = try ClaudeStandIn(mode: .exitAfterFirstAnswer)
        let provider = makeProvider(standIn)
        try await provider.startConversation(instructions: "x", model: "sonnet", recap: nil)
        _ = try await provider.ask(textQuestion("first question"), model: "sonnet")
        #expect(await standIn.waitForProcessToBeGone(pid: standIn.pid(ofStart: 0)))

        let answer = try await provider.ask(textQuestion("second question"), model: "sonnet")
        await provider.endConversation()

        #expect(answer.text == ClaudeStandIn.defaultAnswer)
        #expect(standIn.starts.count == 2)
        let newProcessLines = standIn.userMessages.filter { $0["pid"] as? Int == standIn.pid(ofStart: 1) }
        let allText = standIn.contentBlocks(ofUserLine: newProcessLines[0]).map(textOf).joined(separator: "\n")
        #expect(allText.contains("first question"))
        #expect(allText.contains("Question: second question"))
    }

    @Test func endConversationClosesInputAndTheProcessExits() async throws {
        let standIn = try ClaudeStandIn()
        let provider = makeProvider(standIn)
        try await provider.startConversation(instructions: "x", model: "sonnet", recap: nil)
        _ = try await provider.ask(textQuestion("a question"), model: "sonnet")

        await provider.endConversation()

        #expect(await standIn.waitForProcessToBeGone(pid: standIn.pid(ofStart: 0)))
    }

    /// Waits (up to ten seconds) until the stand-in has been sent a model change request it is slow to answer.
    private func waitForModelChangeRequest(_ standIn: ClaudeStandIn) async {
        for _ in 0..<200 {
            let hasRequest = standIn.stdinLines.contains {
                ($0["message"] as? [String: Any])?["type"] as? String == "control_request"
            }
            if hasRequest { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    @Test func stopDuringAModelChangeWaitStopsTheQuestionAndStartsNoNewProcess() async throws {
        let standIn = try ClaudeStandIn(mode: .slowModelChange)
        let provider = makeProvider(standIn)
        try await provider.startConversation(instructions: "x", model: "sonnet", recap: nil)

        let question = Task { try await provider.ask(textQuestion("anything"), model: "opus") }
        await waitForModelChangeRequest(standIn)
        await provider.endConversation()

        do {
            _ = try await question.value
            Issue.record("expected the question to be stopped")
        } catch let failure as ProviderFailure {
            guard case .failed = failure else {
                Issue.record("wrong failure \(failure)")
                return
            }
        }
        // No second process was started, nothing was sent after Stop, and the first process is gone.
        #expect(standIn.starts.count == 1)
        #expect(standIn.userMessages.isEmpty)
        #expect(await standIn.waitForProcessToBeGone(pid: standIn.pid(ofStart: 0)))
    }

    @Test func aNewConversationDuringAModelChangeWaitDoesNotLetTheOldQuestionIn() async throws {
        let standIn = try ClaudeStandIn(mode: .slowModelChange)
        let provider = makeProvider(standIn)
        try await provider.startConversation(instructions: "x", model: "sonnet", recap: nil)

        let question = Task { try await provider.ask(textQuestion("old question"), model: "opus") }
        await waitForModelChangeRequest(standIn)
        await provider.endConversation()
        try await provider.startConversation(instructions: "x", model: "sonnet", recap: nil)

        do {
            _ = try await question.value
            Issue.record("expected the old question to be stopped")
        } catch is ProviderFailure {
        }
        // Only the old and the new conversation's processes exist; the old question sent nothing to either.
        await standIn.waitForStarts(count: 2)
        #expect(standIn.starts.count == 2)
        #expect(standIn.userMessages.isEmpty)
        await provider.endConversation()
        #expect(await standIn.waitForProcessToBeGone(pid: standIn.pid(ofStart: 1)))
    }

    @Test func summaryThatIgnoresTheStopRequestIsKilledAndTheCallReturns() async throws {
        let standIn = try ClaudeStandIn(mode: .ignoreTerminate)
        let provider = makeProvider(standIn, answerTimeoutSeconds: 3)
        let finished = FinishedFlag()
        let call = Task {
            _ = try? await provider.summarize("text", instructions: "Summarize.", model: "haiku")
            finished.markFinished()
        }
        // 3 s timeout (so Python has installed its handler) + 1.5 s before the kill, with room for a loaded Mac.
        for _ in 0..<240 where !finished.isFinished {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let didFinish = finished.isFinished
        if !didFinish {
            // Without the kill the call hangs for good; do not leave the stand-in behind.
            let standInPid = standIn.pid(ofStart: 0)
            if standInPid > 0 { kill(pid_t(standInPid), SIGKILL) }
            _ = await call.value
        }
        #expect(didFinish, "summarize never returned after the timeout")
        #expect(await standIn.waitForProcessToBeGone(pid: standIn.pid(ofStart: 0)))
    }

    @Test func missingCommandLineToolIsCliNotFound() async throws {
        let provider = ClaudeCLIProvider(
            locations: AppDataLocations(root: FileManager.default.temporaryDirectory.appendingPathComponent("none-\(UUID().uuidString)")),
            executableURL: URL(fileURLWithPath: "/nonexistent/claude"),
            environment: [:]
        )

        do {
            try await provider.startConversation(instructions: "x", model: "sonnet", recap: "Earlier in this session: x")
            Issue.record("expected cliNotFound")
        } catch let failure as ProviderFailure {
            #expect(failure == .cliNotFound)
        }
    }

    @Test func askBeforeStartIsAPlainFailure() async throws {
        let standIn = try ClaudeStandIn()
        let provider = makeProvider(standIn)

        do {
            _ = try await provider.ask(textQuestion("anything"), model: "sonnet")
            Issue.record("expected a failure")
        } catch let failure as ProviderFailure {
            guard case .failed = failure else {
                Issue.record("wrong failure \(failure)")
                return
            }
        }
    }

    @Test func summarizeRunsAShortTextOnlyProcessAndReturnsItsText() async throws {
        let standIn = try ClaudeStandIn()
        let provider = makeProvider(standIn)

        let summary = try await provider.summarize("Q: hi\nA: hello", instructions: "Summarize.", model: "haiku")

        #expect(summary == "Short summary text.")
        let run = try #require(standIn.summarizeRuns.first)
        let argv = run["argv"] as? [String] ?? []
        #expect(argv.contains("--input-format") == false)
        #expect(argv.contains("--bare") == false)
        #expect(argv.contains("-p"))
        let modelIndex = try #require(argv.firstIndex(of: "--model"))
        #expect(argv[modelIndex + 1] == "haiku")
        let promptIndex = try #require(argv.firstIndex(of: "--system-prompt"))
        #expect(argv[promptIndex + 1] == "Summarize.")
        #expect(run["stdin"] as? String == "Q: hi\nA: hello")
    }

    @Test func summarizeUsageLimitBecomesUsageLimitReached() async throws {
        let standIn = try ClaudeStandIn(mode: .limit)
        let provider = makeProvider(standIn)

        do {
            _ = try await provider.summarize("text", instructions: "Summarize.", model: "haiku")
            Issue.record("expected a usage limit failure")
        } catch let failure as ProviderFailure {
            guard case .usageLimitReached = failure else {
                Issue.record("wrong failure \(failure)")
                return
            }
        }
    }
}

private final class FinishedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }
    func markFinished() { lock.lock(); finished = true; lock.unlock() }
}
