import Foundation
import Testing
@testable import ClickyCore

/// Collects what a provider reports while an answer is coming.
private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var reports: [AnswerProgress] = []

    func add(_ progress: AnswerProgress) {
        lock.lock(); reports.append(progress); lock.unlock()
    }

    var all: [AnswerProgress] { lock.lock(); defer { lock.unlock() }; return reports }
    var texts: [String] {
        all.compactMap { if case .textSoFar(let text) = $0 { return text } else { return nil } }
    }
}

/// Brain passages in the prompt, the per-question model and effort, streaming, and ending a running answer.
@Suite(.serialized)
struct CodexStreamingTests {
    private func turn(question: String = "what did I note", brainNote: String = "", contextNote: String = "") -> QuestionTurn {
        QuestionTurn(questionText: question, contextNote: contextNote, images: [], brainNote: brainNote)
    }

    private func firstExecArguments(_ standIn: CodexStandIn, index: Int = 0) throws -> [String] {
        let calls = standIn.recordedExecCalls()
        return try #require(calls.indices.contains(index) ? calls[index] : nil)
    }

    // MARK: Prompt

    @Test func promptOrderIsRecapLabelsContextNoteBrainNoteQuestion() {
        let imageURL = URL(fileURLWithPath: "/tmp/a.jpg")
        let fullTurn = QuestionTurn(
            questionText: "where",
            contextNote: "CONTEXT",
            images: [TurnImage(fileURL: imageURL, label: "LABEL", pixelWidth: 1, pixelHeight: 1)],
            brainNote: "BRAIN"
        )
        let prompt = CodexOutputParsing.promptText(for: fullTurn, recap: "RECAP")
        let positions = ["RECAP", "Image 1: LABEL", "CONTEXT", "BRAIN", "Question: where"].map { prompt.range(of: $0)?.lowerBound }
        #expect(positions.allSatisfy { $0 != nil })
        let sorted = positions.compactMap { $0 }
        #expect(sorted == sorted.sorted())
    }

    @Test func emptyBrainNoteLeavesThePromptExactlyAsToday() {
        let withoutNote = QuestionTurn(questionText: "q", contextNote: "ctx", images: [])
        let withEmptyNote = QuestionTurn(questionText: "q", contextNote: "ctx", images: [], brainNote: "")
        #expect(CodexOutputParsing.promptText(for: withEmptyNote) == "ctx\n\nQuestion: q")
        #expect(CodexOutputParsing.promptText(for: withEmptyNote) == CodexOutputParsing.promptText(for: withoutNote))
    }

    @Test func brainNoteReachesTheExecPrompt() async throws {
        let standIn = try CodexStandIn()
        let provider = standIn.makeProvider()
        try await provider.startConversation(instructions: "", model: "gpt-a", recap: nil)
        _ = try await provider.ask(turn(brainNote: "From notes/a.md: the lease ends in May."), model: "gpt-a")
        let arguments = try firstExecArguments(standIn)
        let prompt = try #require(arguments.first { $0.contains("Question: what did I note") })
        #expect(prompt == "From notes/a.md: the lease ends in May.\n\nQuestion: what did I note")
    }

    // MARK: Arguments

    @Test func normalQuestionKeepsTodaysModelAndEffortArguments() async throws {
        let standIn = try CodexStandIn()
        let provider = standIn.makeProvider()
        try await provider.startConversation(instructions: "", model: "gpt-a", recap: nil)
        _ = try await provider.answer(turn(), request: AnswerRequest(model: "gpt-a"), progress: { _ in })
        let arguments = try firstExecArguments(standIn)
        let modelIndex = try #require(arguments.firstIndex(of: "-m"))
        #expect(arguments[modelIndex + 1] == "gpt-a")
        #expect(arguments.contains("model_reasoning_effort=low"))
        #expect(!arguments.contains { $0.hasPrefix("model_reasoning_effort=") && $0 != "model_reasoning_effort=low" })
    }

    @Test func emptyModelOmitsTheModelFlag() async throws {
        let standIn = try CodexStandIn()
        let provider = standIn.makeProvider()
        try await provider.startConversation(instructions: "", model: "", recap: nil)
        _ = try await provider.answer(turn(), request: AnswerRequest(model: ""), progress: { _ in })
        #expect(!(try firstExecArguments(standIn)).contains("-m"))
    }

    @Test func digDeeperCarriesItsModelAndEffortForThatOneExecOnly() async throws {
        let standIn = try CodexStandIn()
        let provider = standIn.makeProvider()
        try await provider.startConversation(instructions: "", model: "gpt-a", recap: nil)
        _ = try await provider.answer(turn(), request: AnswerRequest(model: "gpt-5.5", effort: .high), progress: { _ in })
        _ = try await provider.answer(turn(), request: AnswerRequest(model: "gpt-a"), progress: { _ in })

        let deeper = try firstExecArguments(standIn, index: 0)
        let modelIndex = try #require(deeper.firstIndex(of: "-m"))
        #expect(deeper[modelIndex + 1] == "gpt-5.5")
        #expect(deeper.contains("model_reasoning_effort=high"))
        #expect(!deeper.contains("model_reasoning_effort=low"))

        let normalAgain = try firstExecArguments(standIn, index: 1)
        #expect(normalAgain.contains("resume"))
        let normalModelIndex = try #require(normalAgain.firstIndex(of: "-m"))
        #expect(normalAgain[normalModelIndex + 1] == "gpt-a")
        #expect(normalAgain.contains("model_reasoning_effort=low"))
        #expect(!normalAgain.contains("model_reasoning_effort=high"))
    }

    @Test func noToolIsEverGivenAndTheRestrictionsRideOnEveryCall() async throws {
        let standIn = try CodexStandIn()
        let provider = standIn.makeProvider()
        try await provider.startConversation(instructions: "", model: "gpt-a", recap: nil)
        _ = try await provider.answer(turn(brainNote: "a passage"), request: AnswerRequest(model: "gpt-a", effort: .high), progress: { _ in })
        _ = try await provider.answer(turn(), request: AnswerRequest(model: "gpt-a"), progress: { _ in })

        #expect(provider.supportsBrainTools == false)
        let execCalls = standIn.recordedExecCalls()
        #expect(execCalls.count == 2)
        for arguments in execCalls {
            let joined = arguments.joined(separator: "\u{1}")
            #expect(joined.contains(CodexToolRestrictions.arguments.joined(separator: "\u{1}")))
            #expect(!arguments.contains { $0.contains("mcp_servers") })
        }
    }

    // MARK: Streaming

    @Test func eachAgentMessageIsReportedWithEverythingSoFar() async throws {
        let standIn = try CodexStandIn()
        standIn.setMode("twomessages")
        let provider = standIn.makeProvider()
        try await provider.startConversation(instructions: "", model: "gpt-a", recap: nil)
        let log = ProgressLog()

        let answer = try await provider.answer(turn(brainNote: "From notes/a.md: x"), request: AnswerRequest(model: "gpt-a"), progress: { log.add($0) })

        #expect(log.texts == ["First finding.", "First finding.\n\nSecond finding. [POINT:40,12:file menu]"])
        #expect(answer.text == "First finding.\n\nSecond finding. [POINT:40,12:file menu]")
        #expect(answer.wasCutShort == false)
        #expect(answer.toolCalls.isEmpty)
        let secondsToFirstText = try #require(answer.secondsToFirstText)
        #expect(secondsToFirstText > 0 && secondsToFirstText <= answer.secondsToAnswer)
    }

    @Test func askStillReturnsTheSameJoinedText() async throws {
        let standIn = try CodexStandIn()
        standIn.setMode("twomessages")
        let provider = standIn.makeProvider()
        try await provider.startConversation(instructions: "", model: "gpt-a", recap: nil)
        let answer = try await provider.ask(turn(brainNote: "From notes/a.md: x"), model: "gpt-a")
        #expect(answer.text == "First finding.\n\nSecond finding. [POINT:40,12:file menu]")
    }

    // MARK: Ending a running answer

    @Test func stopCurrentAnswerReturnsTheTextSoFarAndTheNextQuestionWorks() async throws {
        let standIn = try CodexStandIn()
        standIn.setMode("slowtwomessages")
        let provider = standIn.makeProvider()
        try await provider.startConversation(instructions: "", model: "gpt-a", recap: nil)
        let log = ProgressLog()

        let pending = Task {
            try await provider.answer(turn(), request: AnswerRequest(model: "gpt-a"), progress: { log.add($0) })
        }
        // Wait until the first message has been reported, then end the answer.
        let deadline = Date().addingTimeInterval(15)
        while log.texts.isEmpty, Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(log.texts == ["First finding."])
        await provider.stopCurrentAnswer()

        let answer = try await pending.value
        #expect(answer.text == "First finding.")
        #expect(answer.wasCutShort == true)

        standIn.setMode("normal")
        let next = try await provider.answer(turn(), request: AnswerRequest(model: "gpt-a"), progress: { _ in })
        #expect(next.text == CodexStandIn.answerText)
        #expect(next.wasCutShort == false)
    }

    @Test func stopCurrentAnswerWithNothingRunningDoesNothing() async throws {
        let standIn = try CodexStandIn()
        let provider = standIn.makeProvider()
        try await provider.startConversation(instructions: "", model: "gpt-a", recap: nil)
        await provider.stopCurrentAnswer()
        let answer = try await provider.answer(turn(), request: AnswerRequest(model: "gpt-a"), progress: { _ in })
        #expect(answer.wasCutShort == false)
        #expect(answer.text == CodexStandIn.answerText)
    }

    @Test func stoppingBeforeTheFirstMessageReturnsEmptyTextCutShort() async throws {
        let standIn = try CodexStandIn()
        standIn.setMode("hang")
        let provider = standIn.makeProvider()
        try await provider.startConversation(instructions: "", model: "gpt-a", recap: nil)
        let pending = Task {
            try await provider.answer(turn(), request: AnswerRequest(model: "gpt-a"), progress: { _ in })
        }
        #expect(await standIn.waitForCall(callNumber: 2, seconds: 15))
        await provider.stopCurrentAnswer()
        let answer = try await pending.value
        #expect(answer.text == "")
        #expect(answer.wasCutShort == true)
        #expect(answer.secondsToFirstText == nil)
    }

    @Test func endingTheConversationStillThrowsInsteadOfReturningCutShort() async throws {
        let standIn = try CodexStandIn()
        standIn.setMode("hang")
        let provider = standIn.makeProvider()
        try await provider.startConversation(instructions: "", model: "gpt-a", recap: nil)
        let pending = Task {
            try await provider.answer(turn(), request: AnswerRequest(model: "gpt-a"), progress: { _ in })
        }
        #expect(await standIn.waitForCall(callNumber: 2, seconds: 15))
        await provider.endConversation()
        await #expect(throws: ProviderFailure.self) { _ = try await pending.value }
    }
}
