import Foundation
import Testing
@testable import ClickyCore

/// Collects what an answer reports while it runs.
actor ClaudeProgressRecorder {
    private(set) var reports: [AnswerProgress] = []

    func record(_ report: AnswerProgress) {
        reports.append(report)
    }

    var count: Int { reports.count }

    var texts: [String] {
        reports.compactMap { report in
            if case .textSoFar(let text) = report { return text }
            return nil
        }
    }

    /// Waits (up to ten seconds) until at least `count` reports arrived.
    func waitForReports(count wanted: Int) async {
        for _ in 0..<500 {
            if reports.count >= wanted { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

/// Serialized: each test starts a freshly written stand-in script, and many at once slow the first start of
/// every script on this Mac enough to upset the start-up-sensitive timing tests in `ClaudeCLIProviderTests`.
@Suite(.serialized)
struct ClaudeStreamingTests {
    private typealias Trigger = ClaudeStandIn.QuestionTrigger

    private func makeProvider(
        _ standIn: ClaudeStandIn,
        answerTimeoutSeconds: Double = 20,
        brainToolServer: BrainToolServer? = nil,
        interruptGraceSeconds: Double = 5
    ) -> ClaudeCLIProvider {
        ClaudeCLIProvider(
            locations: standIn.locations(),
            executableURL: standIn.executableURL,
            environment: standIn.parentEnvironment,
            answerTimeoutSeconds: answerTimeoutSeconds,
            brainToolServer: brainToolServer,
            interruptGraceSeconds: interruptGraceSeconds
        )
    }

    private func question(_ text: String, brainNote: String = "") -> QuestionTurn {
        QuestionTurn(questionText: text, contextNote: "", images: [], brainNote: brainNote)
    }

    private func answer(
        _ provider: ClaudeCLIProvider,
        _ turn: QuestionTurn,
        request: AnswerRequest = AnswerRequest(model: "sonnet"),
        recorder: ClaudeProgressRecorder
    ) async throws -> ProviderAnswer {
        try await provider.answer(turn, request: request, progress: { report in await recorder.record(report) })
    }

    // MARK: Command line and environment

    @Test func withoutAServerTheFlagListIsTodaysPlusPartialMessages() {
        let arguments = ClaudeCommandLine.conversationArguments(model: "sonnet", instructions: "Be brief.")
        #expect(arguments == [
            "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--model", "sonnet", "--system-prompt", "Be brief.", "--tools", "", "--setting-sources", "",
            "--strict-mcp-config", "--disable-slash-commands", "--no-session-persistence", "--safe-mode",
            "--include-partial-messages",
        ])
    }

    @Test func withAServerSafeModeGoesAndTheOneMCPServerAndTwoAllowedToolsComeIn() throws {
        let server = BrainToolServer(
            executableURL: URL(fileURLWithPath: "/Apps/Clicky Fork.app/Contents/Helpers/brain-helper"),
            arguments: ["--index", "/data/index.db", "--folder", "/Users/me/notes"]
        )
        let arguments = ClaudeCommandLine.conversationArguments(model: "sonnet", instructions: "Be brief.", brainToolServer: server)
        #expect(arguments.contains("--safe-mode") == false)
        for kept in ["--strict-mcp-config", "--disable-slash-commands", "--no-session-persistence", "--include-partial-messages"] {
            #expect(arguments.contains(kept))
        }
        for (flag, value) in [("--tools", ""), ("--setting-sources", ""), ("--allowedTools", "mcp__brain__search_brain,mcp__brain__read_brain_file")] {
            let flagIndex = try #require(arguments.firstIndex(of: flag))
            #expect(arguments[flagIndex + 1] == value)
        }
        let configIndex = try #require(arguments.firstIndex(of: "--mcp-config"))
        let configJSON = arguments[configIndex + 1]
        // Sorted keys, compact: the same text every time.
        #expect(configJSON == #"{"mcpServers":{"brain":{"args":["--index","/data/index.db","--folder","/Users/me/notes"],"command":"/Apps/Clicky Fork.app/Contents/Helpers/brain-helper","type":"stdio"}}}"#)
        let parsed = try #require(JSONSerialization.jsonObject(with: Data(configJSON.utf8)) as? [String: Any])
        let servers = try #require(parsed["mcpServers"] as? [String: Any])
        #expect(servers.keys.sorted() == ["brain"])
    }

    @Test func theSummaryRunStaysInSafeModeWithNoTools() {
        let arguments = ClaudeCommandLine.oneShotArguments(model: "haiku", instructions: "Summarize.")
        #expect(arguments.contains("--safe-mode"))
        #expect(arguments.contains("--mcp-config") == false)
        #expect(arguments.contains("--include-partial-messages") == false)
    }

    @Test func aServerTurnsOffFileMentionsInTheChildEnvironment() async throws {
        let standIn = try ClaudeStandIn()
        let server = BrainToolServer(executableURL: URL(fileURLWithPath: "/bin/echo"), arguments: ["x"])
        let provider = makeProvider(standIn, brainToolServer: server)
        #expect(provider.supportsBrainTools)

        try await provider.startConversation(instructions: "x", model: "sonnet", recap: nil)
        await standIn.waitForStarts(count: 1)
        await provider.endConversation()

        #expect(standIn.environment(ofStart: 0)["CLAUDE_CODE_DISABLE_FILE_MENTIONS"] == "1")
        #expect(standIn.argv(ofStart: 0).contains("--safe-mode") == false)
        #expect(standIn.argv(ofStart: 0).contains("--mcp-config"))
        #expect(ClaudeStandIn.unexpectedVariableNames(in: standIn.environment(ofStart: 0)).isEmpty)
    }

    @Test func withoutAServerThereAreNoBrainTools() throws {
        let standIn = try ClaudeStandIn()
        #expect(makeProvider(standIn).supportsBrainTools == false)
    }

    // MARK: Streaming

    @Test func aStreamedAnswerReportsEveryDeltaAndReturnsTheJoinedText() async throws {
        let standIn = try ClaudeStandIn()
        let provider = makeProvider(standIn)
        let recorder = ClaudeProgressRecorder()
        try await provider.startConversation(instructions: "x", model: "sonnet", recap: nil)

        let result = try await answer(provider, question(Trigger.streamed), recorder: recorder)
        await provider.endConversation()

        #expect(result.text == ClaudeStandIn.defaultAnswer)
        #expect(await recorder.texts == [
            "The Save button ",
            "The Save button is at the top right. ",
            ClaudeStandIn.defaultAnswer,
        ])
        let firstTextSeconds = try #require(result.secondsToFirstText)
        #expect(firstTextSeconds > 0 && firstTextSeconds <= result.secondsToAnswer)
        #expect(result.wasCutShort == false)
        #expect(result.toolCalls.isEmpty)
    }

    @Test func aSearchedAnswerReportsPreambleToolCallFindingInOrderAndFillsTheTotals() async throws {
        let standIn = try ClaudeStandIn()
        let provider = makeProvider(standIn, brainToolServer: BrainToolServer(executableURL: URL(fileURLWithPath: "/bin/echo"), arguments: []))
        let recorder = ClaudeProgressRecorder()
        try await provider.startConversation(instructions: "x", model: "sonnet", recap: nil)

        let result = try await answer(provider, question(Trigger.search), recorder: recorder)
        await provider.endConversation()

        let expectedCall = BrainToolCall(tool: .searchBrain, argument: "design-vault port", argumentsFingerprint: #"{"query":"design-vault port"}"#)
        #expect(await recorder.reports == [
            .textSoFar("Searching the "),
            .textSoFar("Searching the brain for the port."),
            .toolCallStarted(.searchBrain),
            .toolCallMade(expectedCall),
            .toolCallFinished(expectedCall, paths: [ClaudeStandIn.searchResultPath], resultCharacterCount: 51),
            .textSoFar("Searching the brain for the port. design-vault runs "),
            .textSoFar("Searching the brain for the port. design-vault runs on port 4417."),
        ])
        #expect(result.text == "Searching the brain for the port. design-vault runs on port 4417.")
        #expect(result.toolCalls == [expectedCall])
        #expect(result.notesRead == [ClaudeStandIn.searchResultPath])
        #expect(result.toolResultCharacterCount == 51)
        #expect(result.secondsToFirstText != nil)
    }

    @Test func anAnswerWithNoDeltasFallsBackToTheResultTextAndHasNoFirstTextTime() async throws {
        let standIn = try ClaudeStandIn()
        let provider = makeProvider(standIn)
        let recorder = ClaudeProgressRecorder()
        try await provider.startConversation(instructions: "x", model: "sonnet", recap: nil)

        let result = try await answer(provider, question("plain"), recorder: recorder)
        await provider.endConversation()

        #expect(result.text == ClaudeStandIn.defaultAnswer)
        #expect(result.secondsToFirstText == nil)
        #expect(await recorder.texts == [ClaudeStandIn.defaultAnswer])
    }

    @Test func thinkingBlocksAreNotPartOfTheText() async throws {
        let standIn = try ClaudeStandIn()
        let provider = makeProvider(standIn)
        let recorder = ClaudeProgressRecorder()
        try await provider.startConversation(instructions: "x", model: "sonnet", recap: nil)

        let result = try await answer(provider, question(Trigger.thinking), recorder: recorder)
        await provider.endConversation()

        #expect(result.text == "Visible.")
        #expect(await recorder.texts == ["Visible."])
    }

    @Test func askStillWorksAndReturnsTheStreamedText() async throws {
        let standIn = try ClaudeStandIn()
        let provider = makeProvider(standIn)
        try await provider.startConversation(instructions: "x", model: "sonnet", recap: nil)

        let result = try await provider.ask(question(Trigger.streamed), model: "sonnet")
        await provider.endConversation()

        #expect(result.text == ClaudeStandIn.defaultAnswer)
    }

    // MARK: Timeout

    /// A tool that prints nothing at all is covered by `silentProcessTimesOutWithinThreeSecondsAndIsGone`.
    @Test func anAnswerThatKeepsStreamingNeverTimesOutEvenPastTheLimit() async throws {
        let standIn = try ClaudeStandIn()
        // Six deltas 0.5 s apart take about 3 s; the silence limit is 2 s.
        let provider = makeProvider(standIn, answerTimeoutSeconds: 2)
        let recorder = ClaudeProgressRecorder()
        try await provider.startConversation(instructions: "x", model: "sonnet", recap: nil)
        // Python's start-up must not count as silence.
        await standIn.waitForStarts(count: 1)

        let result = try await answer(provider, question(Trigger.trickle), recorder: recorder)
        await provider.endConversation()

        #expect(result.text == "a b c d e f")
    }

    // MARK: Repeat guard

    @Test func theThirdIdenticalCallInARowInterruptsAndReturnsTheTextSoFarCutShort() async throws {
        let standIn = try ClaudeStandIn()
        let provider = makeProvider(standIn)
        let recorder = ClaudeProgressRecorder()
        try await provider.startConversation(instructions: "x", model: "sonnet", recap: nil)

        let result = try await answer(provider, question(Trigger.repeatedCall), recorder: recorder)

        #expect(result.wasCutShort)
        #expect(result.text == "Looking.")
        #expect(result.toolCalls.count == 3)
        #expect(standIn.controlSubtypes == ["interrupt"])
        // The same process answers the next question.
        let next = try await answer(provider, question("plain"), recorder: recorder)
        await provider.endConversation()
        #expect(next.text == ClaudeStandIn.defaultAnswer)
        #expect(standIn.starts.count == 1)
    }

    // MARK: Interrupt

    @Test func stoppingARunningAnswerReturnsTheTextSoFarAndTheNextQuestionUsesTheSameProcess() async throws {
        let standIn = try ClaudeStandIn()
        let provider = makeProvider(standIn)
        let recorder = ClaudeProgressRecorder()
        try await provider.startConversation(instructions: "x", model: "sonnet", recap: nil)

        let heldAnswer = Task { try await answer(provider, question(Trigger.held), recorder: recorder) }
        await recorder.waitForReports(count: 1)
        await provider.stopCurrentAnswer()
        let result = try await heldAnswer.value

        #expect(result.wasCutShort)
        #expect(result.text == "Part one of a long answer.")
        #expect(standIn.controlSubtypes == ["interrupt"])
        let interrupt = try #require(standIn.controlRequests.first)
        #expect(interrupt["subtype"] as? String == "interrupt")

        let next = try await answer(provider, question("plain"), recorder: recorder)
        await provider.endConversation()
        #expect(next.text == ClaudeStandIn.defaultAnswer)
        #expect(next.wasCutShort == false)
        #expect(standIn.starts.count == 1)
    }

    @Test func aNewQuestionEndsTheRunningAnswerFirst() async throws {
        let standIn = try ClaudeStandIn()
        let provider = makeProvider(standIn)
        let recorder = ClaudeProgressRecorder()
        try await provider.startConversation(instructions: "x", model: "sonnet", recap: nil)

        let heldAnswer = Task { try await answer(provider, question(Trigger.held), recorder: recorder) }
        await recorder.waitForReports(count: 1)
        // No stopCurrentAnswer call: asking again must not write a second user line into a busy process.
        let next = try await answer(provider, question("plain"), recorder: ClaudeProgressRecorder())
        let first = try await heldAnswer.value
        await provider.endConversation()

        #expect(first.wasCutShort)
        #expect(next.text == ClaudeStandIn.defaultAnswer)
        #expect(standIn.starts.count == 1)
    }

    @Test func aToolThatIgnoresTheInterruptIsStoppedAfterTheGraceAndTheNextQuestionStartsAFreshProcessWithTheRecap() async throws {
        let standIn = try ClaudeStandIn(mode: .ignoreInterrupt)
        let provider = makeProvider(standIn, interruptGraceSeconds: 0.5)
        let recorder = ClaudeProgressRecorder()
        try await provider.startConversation(instructions: "x", model: "sonnet", recap: nil)

        let heldAnswer = Task { try await answer(provider, question(Trigger.held), recorder: recorder) }
        await recorder.waitForReports(count: 1)
        await provider.stopCurrentAnswer()
        let result = try await heldAnswer.value
        #expect(result.wasCutShort)
        #expect(result.text == "Part one of a long answer.")
        #expect(await standIn.waitForProcessToBeGone(pid: standIn.pid(ofStart: 0)))

        let next = try await answer(provider, question("plain"), recorder: recorder)
        await provider.endConversation()
        #expect(next.text == ClaudeStandIn.defaultAnswer)
        #expect(standIn.starts.count == 2)
        // The fresh process is told about the cut answer.
        let blocks = standIn.contentBlocks(ofUserLine: standIn.userMessages[1])
        let recapText = blocks.first?["text"] as? String ?? ""
        #expect(recapText.contains("Part one of a long answer."))
    }

    @Test func stoppingWithNoAnswerRunningDoesNothing() async throws {
        let standIn = try ClaudeStandIn()
        let provider = makeProvider(standIn)
        try await provider.startConversation(instructions: "x", model: "sonnet", recap: nil)
        await provider.stopCurrentAnswer()
        await provider.endConversation()
        #expect(standIn.controlSubtypes.isEmpty)
    }

    // MARK: Dig deeper

    @Test func digDeeperSwitchesModelAndEffortForOneQuestionThenRestoresBoth() async throws {
        let standIn = try ClaudeStandIn(startingEffortLevel: "medium")
        let provider = makeProvider(standIn)
        let recorder = ClaudeProgressRecorder()
        try await provider.startConversation(instructions: "x", model: "sonnet", recap: nil)

        _ = try await answer(provider, question("first"), recorder: recorder)
        #expect(standIn.controlSubtypes.isEmpty)

        let deeper = try await answer(provider, question("again, dig deeper"), request: AnswerRequest(model: "opus", effort: .high), recorder: recorder)
        #expect(deeper.model == "opus")
        #expect(standIn.controlSubtypes == ["set_model", "get_settings", "apply_flag_settings"])
        #expect(standIn.controlRequests[0]["model"] as? String == "opus")
        let applied = standIn.controlRequests[2]["settings"] as? [String: Any]
        #expect(applied?["effortLevel"] as? String == "high")

        let normal = try await answer(provider, question("back to normal"), recorder: recorder)
        await provider.endConversation()
        #expect(normal.model == "sonnet")
        #expect(standIn.controlSubtypes == ["set_model", "get_settings", "apply_flag_settings", "set_model", "apply_flag_settings"])
        #expect(standIn.controlRequests[3]["model"] as? String == "sonnet")
        let restored = standIn.controlRequests[4]["settings"] as? [String: Any]
        #expect(restored?["effortLevel"] as? String == "medium")
        #expect(standIn.starts.count == 1)
    }

    @Test func restoringWhenNoEffortWasEverSetAppliesNullToClearIt() async throws {
        let standIn = try ClaudeStandIn()
        let provider = makeProvider(standIn)
        let recorder = ClaudeProgressRecorder()
        try await provider.startConversation(instructions: "x", model: "sonnet", recap: nil)

        _ = try await answer(provider, question("deeper"), request: AnswerRequest(model: "sonnet", effort: .medium), recorder: recorder)
        _ = try await answer(provider, question("normal"), recorder: recorder)
        await provider.endConversation()

        #expect(standIn.controlSubtypes == ["get_settings", "apply_flag_settings", "apply_flag_settings"])
        let cleared = standIn.controlRequests[2]["settings"] as? [String: Any]
        #expect(cleared?.keys.contains("effortLevel") == true)
        #expect(cleared?["effortLevel"] is NSNull)
    }

    @Test func aRefusedEffortChangeStillAnswersOnTheModelAlone() async throws {
        let standIn = try ClaudeStandIn(mode: .refuseEffortChange)
        let provider = makeProvider(standIn)
        let recorder = ClaudeProgressRecorder()
        try await provider.startConversation(instructions: "x", model: "sonnet", recap: nil)

        let result = try await answer(provider, question("deeper"), request: AnswerRequest(model: "sonnet", effort: .high), recorder: recorder)
        await provider.endConversation()

        #expect(result.text == ClaudeStandIn.defaultAnswer)
    }

    // MARK: Stop and effort (fix wave)

    @Test func aStopThatLandsWhileANewQuestionWaitsForTheOldAnswerEndsTheNewQuestionUnsent() async throws {
        let standIn = try ClaudeStandIn(mode: .ignoreInterrupt)
        let provider = makeProvider(standIn, interruptGraceSeconds: 2)
        let recorder = ClaudeProgressRecorder()
        try await provider.startConversation(instructions: "x", model: "sonnet", recap: nil)

        let heldAnswer = Task { try await answer(provider, question(Trigger.held), recorder: recorder) }
        await recorder.waitForReports(count: 1)
        let waitingQuestion = Task { try await answer(provider, question("plain"), recorder: ClaudeProgressRecorder()) }
        // The new question is now inside the engine, waiting for the held answer, which ignores the interrupt.
        try await Task.sleep(nanoseconds: 500_000_000)
        await provider.stopCurrentAnswer()

        let second = try await waitingQuestion.value
        _ = try await heldAnswer.value
        await provider.endConversation()
        #expect(second.wasCutShort)
        #expect(second.text == "")
        #expect(standIn.userMessages.count == 1)
    }

    @Test func stopCurrentAnswerReturnsOnlyOnceTheEndedAnswerHasReturned() async throws {
        let standIn = try ClaudeStandIn()
        let provider = makeProvider(standIn)
        let recorder = ClaudeProgressRecorder()
        try await provider.startConversation(instructions: "x", model: "sonnet", recap: nil)
        let heldAnswer = Task { try await answer(provider, question(Trigger.held), recorder: recorder) }
        await recorder.waitForReports(count: 1)
        await provider.stopCurrentAnswer()
        #expect(provider.answersInside.numberInside == 0)
        _ = try await heldAnswer.value
        await provider.endConversation()
    }

    @Test func theAnswerSaysWhetherTheEffortWasApplied() async throws {
        let standIn = try ClaudeStandIn(startingEffortLevel: "medium")
        let provider = makeProvider(standIn)
        let recorder = ClaudeProgressRecorder()
        try await provider.startConversation(instructions: "x", model: "sonnet", recap: nil)
        let normal = try await answer(provider, question("plain"), recorder: recorder)
        let deeper = try await answer(provider, question("deeper"), request: AnswerRequest(model: "sonnet", effort: .high), recorder: recorder)
        await provider.endConversation()
        #expect(normal.effortWasApplied == nil)
        #expect(deeper.effortWasApplied == true)
    }

    @Test func aRefusedEffortChangeIsReportedAsNotApplied() async throws {
        let standIn = try ClaudeStandIn(mode: .refuseEffortChange)
        let provider = makeProvider(standIn)
        try await provider.startConversation(instructions: "x", model: "sonnet", recap: nil)
        let result = try await answer(provider, question("deeper"), request: AnswerRequest(model: "sonnet", effort: .high), recorder: ClaudeProgressRecorder())
        await provider.endConversation()
        #expect(result.effortWasApplied == false)
    }

    @Test func aRefusedRestoreIsRetriedThenTheProcessIsRestartedBeforeTheNextQuestion() async throws {
        let standIn = try ClaudeStandIn(startingEffortLevel: "medium")
        let provider = makeProvider(standIn)
        let recorder = ClaudeProgressRecorder()
        try await provider.startConversation(instructions: "x", model: "sonnet", recap: nil)
        _ = try await answer(provider, question("deeper"), request: AnswerRequest(model: "sonnet", effort: .high), recorder: recorder)
        try standIn.switchEffortRefusal(on: true)

        let next = try await answer(provider, question("plain again"), recorder: recorder)
        let after = try await answer(provider, question("and again"), recorder: recorder)
        await provider.endConversation()

        #expect(next.text == ClaudeStandIn.defaultAnswer)
        #expect(standIn.starts.count == 2)
        // One applied change for dig deeper, then the refused restore and its single retry.
        #expect(standIn.controlSubtypes.filter { $0 == "apply_flag_settings" }.count == 3)
        #expect(after.text == ClaudeStandIn.defaultAnswer)
        #expect(standIn.starts.count == 2)
    }

    // MARK: Question content

    @Test func theBrainNoteSitsAfterTheContextNoteAndBeforeTheQuestion() async throws {
        let standIn = try ClaudeStandIn()
        let provider = makeProvider(standIn)
        try await provider.startConversation(instructions: "x", model: "sonnet", recap: nil)
        let imageURL = standIn.directory.appendingPathComponent("one.jpg")
        try Data([0xFF, 0xD8, 0xFF]).write(to: imageURL)
        let turn = QuestionTurn(
            questionText: "what is the port",
            contextNote: "The user opened a document.",
            images: [TurnImage(fileURL: imageURL, label: "screen 1 of 1", pixelWidth: 10, pixelHeight: 10)],
            brainNote: "Notes found on this Mac:\nFile: /notes/a.md lines 1-2"
        )

        _ = try await provider.answer(turn, request: AnswerRequest(model: "sonnet"), progress: { _ in })
        await provider.endConversation()

        let blocks = standIn.contentBlocks(ofUserLine: standIn.userMessages[0])
        #expect(blocks.map { $0["type"] as? String } == ["text", "image", "text", "text", "text"])
        #expect(blocks.map { $0["text"] as? String } == [
            "screen 1 of 1", nil, "The user opened a document.",
            "Notes found on this Mac:\nFile: /notes/a.md lines 1-2", "Question: what is the port",
        ])
    }

    @Test func anEmptyBrainNoteLeavesTheUserLineAsItWasBefore() async throws {
        let standIn = try ClaudeStandIn()
        let provider = makeProvider(standIn)
        try await provider.startConversation(instructions: "x", model: "sonnet", recap: nil)

        _ = try await provider.answer(
            QuestionTurn(questionText: "what is this", contextNote: "Context.", images: []),
            request: AnswerRequest(model: "sonnet"),
            progress: { _ in }
        )
        await provider.endConversation()

        let blocks = standIn.contentBlocks(ofUserLine: standIn.userMessages[0])
        #expect(blocks.map { $0["text"] as? String } == ["Context.", "Question: what is this"])
    }
}
