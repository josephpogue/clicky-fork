import Foundation
import Testing
@testable import ClickyCore

@Suite("Session question flow: the brain, streaming and ended answers")
struct SessionQuestionFlowBrainTests {
    private typealias Stream = FakeAnswerProvider.ScriptedStream

    private static let leasePassage = BrainPassage(
        path: "/notes/lease.md", heading: "Term", startLine: 4, endLine: 9, text: "The lease ends in May.", score: 3
    )
    private static let depositPassage = BrainPassage(
        path: "/notes/deposit.md", heading: nil, startLine: 1, endLine: 2, text: "Deposit is 1500.", score: 2
    )
    private static let pointTag = "[POINT:1180,40:save button:screen1]"

    private func startedHarness(
        questions: [String], isBrainOn: Bool = true, passages: [BrainPassage] = [], mapPaths: [String] = [],
        digDeeperRequest: (@Sendable (ProviderID) async -> AnswerRequest)? = nil
    ) async throws -> FlowHarness {
        let harness = FlowHarness(
            questions: questions, isBrainOn: isBrainOn, passages: passages, brainMapPaths: mapPaths,
            digDeeperRequest: digDeeperRequest
        )
        try await harness.flow.begin()
        return harness
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<300 where !condition() { try await Task.sleep(nanoseconds: 10_000_000) }
    }

    // MARK: Instructions

    @Test func theBrainOffUsesTodaysInstructionsAndSearchesNothing() async throws {
        let harness = try await startedHarness(questions: ["where is it"], isBrainOn: false, passages: [Self.leasePassage])

        await harness.askQuestion()

        #expect(harness.claude.starts.map(\.instructions) == ["Be brief."])
        #expect(harness.passageSearches.isEmpty)
        #expect(harness.claude.askedTurns[0].brainNote == "")
        let kinds = harness.log.kinds
        #expect(!kinds.contains { if case .passagesAttached = $0 { return true } else { return false } })
    }

    @Test func aToolProviderGetsPassagesAndToolsWithTheMapPaths() async throws {
        let harness = FlowHarness(questions: [], isBrainOn: true, brainMapPaths: ["/notes/index.md"])
        harness.claude.setSupportsBrainTools(true)
        try await harness.flow.begin()

        #expect(harness.claude.starts.map(\.instructions) == [
            AnswerInstructions.questionInstructions(brainAccess: .passagesAndTools(mapPaths: ["/notes/index.md"]))
        ])
    }

    @Test func aProviderWithoutToolsGetsPassagesOnlyAtStartRestartAndSwitch() async throws {
        let harness = FlowHarness(questions: (1...16).map { "question \($0)" }, isBrainOn: true, brainMapPaths: ["/x.md"])
        let passagesOnly = AnswerInstructions.questionInstructions(brainAccess: .passagesOnly)
        try await harness.flow.begin()
        #expect(harness.claude.starts.map(\.instructions) == [passagesOnly])

        for _ in 1...16 { await harness.askQuestion() }
        #expect(harness.claude.starts.count == 2)
        #expect(harness.claude.starts[1].instructions == passagesOnly)

        harness.chatgpt.setSupportsBrainTools(true)
        await harness.flow.switchProvider(to: .chatgpt)
        #expect(harness.chatgpt.starts.map(\.instructions) == [
            AnswerInstructions.questionInstructions(brainAccess: .passagesAndTools(mapPaths: ["/x.md"]))
        ])
    }

    // MARK: Passages

    @Test func passagesRideWithTheQuestionAndAreLoggedRightAfterIt() async throws {
        let harness = try await startedHarness(
            questions: ["when does the lease end"], passages: [Self.leasePassage, Self.depositPassage]
        )

        await harness.askQuestion()

        let searches = harness.passageSearches
        #expect(searches.count == 1)
        #expect(searches[0].query == "when does the lease end")
        #expect(searches[0].appName == "Xcode")
        #expect(searches[0].windowTitle == "Clicky")
        let attachedNote = BrainPassageNote.text(for: [Self.leasePassage, Self.depositPassage])
        #expect(harness.claude.askedTurns[0].brainNote == attachedNote)
        #expect(harness.log.kinds == [
            .questionStarted,
            .question(text: "when does the lease end", shotGroupID: 101, earlierShotGroupIDs: []),
            .passagesAttached(paths: ["/notes/lease.md", "/notes/deposit.md"]),
            .answerTiming(secondsToFirstText: nil, toolCallCount: 0, wasCutShort: false),
            .answer(text: "Answer 1.", provider: .claude, model: "sonnet", secondsToAnswer: 2.5, pointLabel: nil),
        ])
    }

    @Test func noPassagesAddNoEventAndAnEmptyNote() async throws {
        let harness = try await startedHarness(questions: ["where is the save button"], passages: [])

        await harness.askQuestion()

        #expect(harness.claude.askedTurns[0].brainNote == "")
        #expect(!harness.log.kinds.contains { if case .passagesAttached = $0 { return true } else { return false } })
    }

    // MARK: Dig deeper

    @Test func digDeeperAsksWithTheStrongerRequestAndSearchesWithThePreviousQuestion() async throws {
        let harness = try await startedHarness(
            questions: ["what is the lease term", "dig deeper on the deposit"], passages: [Self.leasePassage],
            digDeeperRequest: { _ in AnswerRequest(model: "opus", effort: .high) }
        )

        await harness.askQuestion()
        await harness.askQuestion()

        #expect(harness.claude.askedRequests == [
            AnswerRequest(model: "sonnet", effort: nil), AnswerRequest(model: "opus", effort: .high),
        ])
        #expect(harness.passageSearches.map(\.query) == ["what is the lease term", "what is the lease term the deposit"])
        // The question is sent and logged as spoken.
        #expect(harness.claude.askedTurns[1].questionText == "dig deeper on the deposit")
        let kinds = harness.log.kinds
        // The dig deeper line is written once the provider has answered (it names the effort really applied), so it
        // follows the question and its passages and comes right before the answer's timing line.
        let askedIndex = try #require(kinds.firstIndex(of: .digDeeperAsked(model: "opus", effort: "high")))
        #expect(kinds[askedIndex - 3] == .questionStarted)
        #expect(kinds[askedIndex - 2] == .question(text: "dig deeper on the deposit", shotGroupID: 102, earlierShotGroupIDs: []))
        #expect(kinds[askedIndex - 1] == .passagesAttached(paths: ["/notes/lease.md"]))
        #expect(kinds[askedIndex + 1] == .answerTiming(secondsToFirstText: nil, toolCallCount: 0, wasCutShort: false))
        #expect(kinds.filter { if case .digDeeperAsked = $0 { return true } else { return false } }.count == 1)
    }

    @Test func digDeeperAsFirstQuestionSearchesWithTheWordsAfterIt() async throws {
        let harness = try await startedHarness(
            questions: ["dig deeper into the roof repair"],
            digDeeperRequest: { _ in AnswerRequest(model: "opus", effort: nil) }
        )

        await harness.askQuestion()

        #expect(harness.passageSearches.map(\.query) == ["the roof repair"])
        #expect(harness.log.kinds.contains(.digDeeperAsked(model: "opus", effort: nil)))
    }

    @Test func digDeeperWithoutAConfiguredRequestIsAnOrdinaryQuestion() async throws {
        let harness = try await startedHarness(questions: ["dig deeper on the deposit"], digDeeperRequest: nil)

        await harness.askQuestion()

        #expect(harness.claude.askedRequests == [AnswerRequest(model: "sonnet", effort: nil)])
        #expect(harness.passageSearches.map(\.query) == ["dig deeper on the deposit"])
        #expect(!harness.log.kinds.contains { if case .digDeeperAsked = $0 { return true } else { return false } })
    }

    // MARK: Streaming

    @Test func streamedTextShowsNoPartialTagAndThePointerFliesOnce() async throws {
        let harness = try await startedHarness(questions: ["where is save"], isBrainOn: false)
        let finalText = "The Save button is up here. \(Self.pointTag)"
        harness.claude.scriptStreams([Stream(
            progress: [
                .textSoFar("The Save"),
                .textSoFar("The Save button is up here. [POINT:11"),
                .textSoFar(finalText),
                .textSoFar(finalText),
            ],
            finalText: finalText
        )])

        await harness.askQuestion()

        #expect(harness.output.textChanges == ["The Save", "The Save button is up here."])
        #expect(harness.output.pointers.count == 1)
        #expect(harness.output.pointers[0].label == "save button")
        #expect(harness.output.pointers[0].globalPoint == CGPoint(x: 1327.5, y: 855))
        // The final answer comes after every progress output and does not fly the pointer again.
        #expect(harness.output.callOrder == ["text", "text", "pointer", "answer"])
        #expect(harness.output.answers.map(\.spokenText) == ["The Save button is up here."])
    }

    @Test func aPointerNotFlownWhileStreamingFliesWithTheFinalAnswer() async throws {
        let harness = try await startedHarness(questions: ["where is save"], isBrainOn: false)
        harness.claude.scriptStreams([Stream(
            progress: [.toolCallStarted(.searchBrain)], finalText: "Up here. \(Self.pointTag)"
        )])

        await harness.askQuestion()

        #expect(harness.output.callOrder == ["checking", "answer", "pointer"])
        #expect(harness.output.pointers.count == 1)
    }

    @Test func theCheckingLineShowsOncePerRunOfToolCalls() async throws {
        let harness = try await startedHarness(questions: ["what does my lease say"])
        let search = BrainToolCall(tool: .searchBrain, argument: "lease term", argumentsFingerprint: "a")
        let read = BrainToolCall(tool: .readBrainFile, argument: "/notes/lease.md", argumentsFingerprint: "b")
        harness.claude.scriptStreams([Stream(
            progress: [
                .toolCallStarted(.searchBrain), .toolCallMade(search),
                .toolCallStarted(.readBrainFile), .toolCallMade(read),
                .textSoFar("It ends in May."),
                .toolCallStarted(.searchBrain),
            ],
            finalText: "It ends in May.", toolCalls: [search, read]
        )])

        await harness.askQuestion()

        // One line before any text, none for the second call of the same run, one more after new text.
        #expect(harness.output.checkingNotesCount == 2)
        #expect(harness.output.callOrder == ["checking", "text", "checking", "answer"])
    }

    @Test func noCheckingLineWhenTheAnswerTextAlreadySaysItIsChecking() async throws {
        let harness = try await startedHarness(questions: ["what does my lease say"])
        harness.claude.scriptStreams([Stream(
            progress: [.textSoFar("Let me check your notes."), .toolCallStarted(.searchBrain)],
            finalText: "Let me check your notes. It ends in May."
        )])

        await harness.askQuestion()

        #expect(harness.output.checkingNotesCount == 0)
    }

    @Test func toolCallsAreLoggedInOrderBeforeTheTimingAndTheAnswer() async throws {
        let harness = try await startedHarness(questions: ["what does my lease say"], passages: [Self.leasePassage])
        let search = BrainToolCall(tool: .searchBrain, argument: "lease term", argumentsFingerprint: "a")
        let read = BrainToolCall(tool: .readBrainFile, argument: "/notes/lease.md", argumentsFingerprint: "b")
        harness.claude.scriptStreams([Stream(
            progress: [.toolCallMade(search), .toolCallMade(read), .textSoFar("May.")],
            finalText: "May.", secondsToFirstText: 0.4, toolCalls: [search, read]
        )])

        await harness.askQuestion()

        #expect(harness.log.kinds == [
            .questionStarted,
            .question(text: "what does my lease say", shotGroupID: 101, earlierShotGroupIDs: []),
            .passagesAttached(paths: ["/notes/lease.md"]),
            .brainToolCalled(tool: "search_brain", argument: "lease term"),
            .brainToolCalled(tool: "read_brain_file", argument: "/notes/lease.md"),
            .answerTiming(secondsToFirstText: 0.4, toolCallCount: 2, wasCutShort: false),
            .answer(text: "May.", provider: .claude, model: "sonnet", secondsToAnswer: 2.5, pointLabel: nil),
        ])
    }

    @Test func theNotesReadAreThePassagePathsThenTheProvidersWithoutRepeats() async throws {
        let harness = try await startedHarness(
            questions: ["what does my lease say"], passages: [Self.leasePassage, Self.depositPassage]
        )
        harness.claude.scriptStreams([Stream(
            finalText: "May.", notesRead: ["/notes/deposit.md", "/notes/extra.md"]
        )])

        await harness.askQuestion()

        #expect(harness.output.answerNotesRead == [["/notes/lease.md", "/notes/deposit.md", "/notes/extra.md"]])
    }

    // MARK: Budget

    @Test func toolResultCharactersCountTowardsTheConversationLimit() async throws {
        let harness = try await startedHarness(questions: ["first", "second", "third"])
        harness.claude.scriptStreams([Stream(finalText: "One.", toolResultCharacterCount: 170_000)])

        await harness.askQuestion()
        #expect(harness.claude.starts.count == 1)
        await harness.askQuestion()
        // The big tool result used up the limit, so the next question begins a fresh conversation.
        #expect(harness.claude.starts.count == 2)
        await harness.askQuestion()
        #expect(harness.claude.starts.count == 2)
    }

    @Test func attachedPassageCharactersCountTowardsTheConversationLimit() async throws {
        let bigPassage = BrainPassage(
            path: "/notes/big.md", heading: nil, startLine: 1, endLine: 2,
            text: String(repeating: "a", count: 170_000), score: 1
        )
        let harness = try await startedHarness(questions: ["first", "second"], passages: [bigPassage])

        await harness.askQuestion()
        await harness.askQuestion()

        #expect(harness.claude.starts.count == 2)
    }

    // MARK: A new question ends the answer still coming

    @Test func aNewQuestionEndsTheOldAnswerAndTheNewAnswerShowsNormally() async throws {
        let harness = try await startedHarness(questions: ["first question", "second question"], isBrainOn: false)
        harness.claude.scriptStreams([
            Stream(
                progress: [.textSoFar("Partial answer")], pausesAfterProgress: true,
                progressAfterStop: [.textSoFar("Stale words after the stop"), .toolCallStarted(.searchBrain)],
                notesRead: ["/notes/a.md"]
            ),
            Stream(progress: [.textSoFar("Second answer.")], finalText: "Second answer."),
        ])

        let firstQuestion = Task { await harness.askQuestion() }
        try await waitUntil { !harness.output.textChanges.isEmpty }
        await harness.askQuestion()
        _ = await firstQuestion.value

        #expect(harness.claude.stopRequestCount == 1)
        #expect(harness.output.cutShorts.count == 1)
        #expect(harness.output.cutShorts[0].visibleText == "Partial answer")
        #expect(harness.output.cutShorts[0].notesRead == ["/notes/a.md"])
        // The old question gets no answer card, no notice, and no say over the phase.
        #expect(harness.output.answers.map(\.spokenText) == ["Second answer."])
        #expect(harness.output.notices.isEmpty)
        #expect(harness.output.phases == [
            .listening, .transcribing, .waitingForAnswer(provider: .claude),
            .listening, .transcribing, .waitingForAnswer(provider: .claude), .idle,
        ])
        // Late reports from the ended answer are dropped.
        #expect(!harness.output.textChanges.contains("Stale words after the stop"))
        #expect(harness.output.checkingNotesCount == 0)
        let kinds = harness.log.kinds
        #expect(kinds.contains(.answerTiming(secondsToFirstText: 0.4, toolCallCount: 0, wasCutShort: true)))
        #expect(kinds.contains(.answer(text: "Partial answer", provider: .claude, model: "sonnet", secondsToAnswer: 1.0, pointLabel: nil)))
        #expect(kinds.contains(.answer(text: "Second answer.", provider: .claude, model: "sonnet", secondsToAnswer: 2.5, pointLabel: nil)))
        #expect(await harness.flow.answeredQuestionCount == 1)
    }

    @Test func aFailureOfTheEndedAnswerShowsNothingAndLeavesThePhaseAlone() async throws {
        let harness = try await startedHarness(questions: ["first question"])
        harness.claude.script([.failure(.failed(message: "late failure"))])
        harness.claude.holdNextAnswer()

        let firstQuestion = Task { await harness.askQuestion() }
        try await waitUntil { !harness.claude.askedTurns.isEmpty }
        let outcome = await harness.flow.handle(.questionStarted(at: FlowHarness.startTime))
        _ = await firstQuestion.value

        #expect(outcome == .accepted)
        #expect(harness.output.notices.isEmpty)
        #expect(harness.output.offers.isEmpty)
        #expect(harness.output.phases.last == .listening)
        #expect(harness.log.kinds.contains { if case .answerFailed = $0 { return true } else { return false } })
    }

    @Test func aTapWhileListeningOrTranscribingIsStillIgnored() async throws {
        let harness = try await startedHarness(questions: ["only"])
        _ = await harness.flow.handle(.questionStarted(at: FlowHarness.startTime))

        let secondTap = await harness.flow.handle(.questionStarted(at: FlowHarness.startTime))

        #expect(secondTap == .ignoredBecauseBusy)
        #expect(harness.claude.stopRequestCount == 0)
    }

    // MARK: Stop during a streaming answer

    @Test func stopDuringAStreamingAnswerEndsItLogsWhatArrivedAndShowsNothing() async throws {
        let harness = try await startedHarness(questions: ["first question"], isBrainOn: false)
        harness.claude.scriptStreams([Stream(
            progress: [.textSoFar("Partial answer")], pausesAfterProgress: true,
            progressAfterStop: [.textSoFar("Stale words after the stop")]
        )])

        let question = Task { await harness.askQuestion() }
        try await waitUntil { !harness.output.textChanges.isEmpty }
        _ = await harness.flow.finish(summaryEnabled: false)
        _ = await question.value

        #expect(harness.claude.stopRequestCount == 1)
        #expect(harness.output.answers.isEmpty)
        #expect(harness.output.cutShorts.isEmpty)
        #expect(harness.output.notices.isEmpty)
        #expect(harness.output.textChanges == ["Partial answer"])
        let kinds = harness.log.kinds
        #expect(kinds.contains(.answerTiming(secondsToFirstText: 0.4, toolCallCount: 0, wasCutShort: true)))
        #expect(kinds.contains(.answer(text: "Partial answer", provider: .claude, model: "sonnet", secondsToAnswer: 1.0, pointLabel: nil)))
        #expect(kinds.last == .sessionStopped)
    }
}
