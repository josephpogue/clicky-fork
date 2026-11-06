import Foundation
import Testing
@testable import ClickyCore

private final class CollectedTexts: @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String] = []
    func add(_ progress: AnswerProgress) {
        if case .textSoFar(let text) = progress { lock.lock(); texts.append(text); lock.unlock() }
    }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return texts }
}

/// Ending an answer while a new question starts: the stop waits for the answer, answer numbers keep a late return
/// from clearing the next answer's state, a killed login check proves nothing, and the answer text rule.
@Suite(.serialized)
struct CodexOverlapTests {
    private func turn(brainNote: String = "") -> QuestionTurn {
        QuestionTurn(questionText: "what did I note", contextNote: "", images: [], brainNote: brainNote)
    }

    // MARK: Stop waits for the answer

    @Test func stopCurrentAnswerReturnsOnlyOnceTheExecHasEndedAndTheAnswerHasReturned() async throws {
        let standIn = try CodexStandIn()
        standIn.setMode("hang")
        let provider = standIn.makeProvider()
        try await provider.startConversation(instructions: "", model: "gpt-a", recap: nil)
        let pending = Task { try await provider.answer(turn(), request: AnswerRequest(model: "gpt-a"), progress: { _ in }) }
        #expect(await standIn.waitForCall(callNumber: 2, seconds: 15))
        let execProcessID = try #require(standIn.recordedProcessID(callNumber: 2))

        await provider.stopCurrentAnswer()

        #expect(CodexStandIn.processExists(execProcessID) == false)
        #expect(provider.hasAnswerInFlight == false)
        let answer = try await pending.value
        #expect(answer.wasCutShort)
    }

    // MARK: Answer numbers

    @Test func aLateReturningAnswerDoesNotClearTheNextAnswersState() async throws {
        let standIn = try CodexStandIn()
        let provider = standIn.makeProvider()
        provider.stopWaitSeconds = 0.05
        let endedAnswer = provider.beginAnswer()
        let nextAnswer = provider.beginAnswer()
        await provider.stopCurrentAnswer()
        #expect(provider.isStopRequested(forAnswerToken: nextAnswer))

        provider.finishAnswer(token: endedAnswer)

        #expect(provider.hasAnswerInFlight)
        #expect(provider.isStopRequested(forAnswerToken: nextAnswer))
        #expect(!provider.isStopRequested(forAnswerToken: endedAnswer))
        provider.finishAnswer(token: nextAnswer)
        #expect(!provider.hasAnswerInFlight)
    }

    // MARK: Login check

    @Test func aLoginCheckEndedByANewQuestionDoesNotCountAsChecked() async throws {
        let standIn = try CodexStandIn()
        standIn.setMode("hangstatus")
        let provider = standIn.makeProvider()
        try await provider.startConversation(instructions: "", model: "gpt-a", recap: nil)
        let pending = Task { try await provider.answer(turn(), request: AnswerRequest(model: "gpt-a"), progress: { _ in }) }
        #expect(await standIn.waitForCall(callNumber: 1, seconds: 15))
        await provider.stopCurrentAnswer()
        let ended = try await pending.value
        #expect(ended.wasCutShort)
        #expect(ended.text == "")

        standIn.setMode("apikey")
        await #expect(throws: ProviderFailure.self) {
            _ = try await provider.answer(turn(), request: AnswerRequest(model: "gpt-a"), progress: { _ in })
        }
        let loginChecks = standIn.recordedCalls().filter { $0.starts(with: ["login", "status"]) }
        #expect(loginChecks.count == 2)
        #expect(standIn.recordedExecCalls().isEmpty)
    }

    // MARK: Answer text

    @Test func withoutABrainNoteTheAnswerIsTheLastMessageAndStreamsThatMessage() async throws {
        let standIn = try CodexStandIn()
        standIn.setMode("twomessages")
        let provider = standIn.makeProvider()
        try await provider.startConversation(instructions: "", model: "gpt-a", recap: nil)
        let collected = CollectedTexts()
        let answer = try await provider.answer(turn(), request: AnswerRequest(model: "gpt-a"), progress: { collected.add($0) })
        #expect(answer.text == "Second finding. [POINT:40,12:file menu]")
        #expect(collected.all == ["First finding.", "Second finding. [POINT:40,12:file menu]"])
    }

    @Test func withABrainNoteEveryMessageJoinsIntoTheAnswer() async throws {
        let standIn = try CodexStandIn()
        standIn.setMode("twomessages")
        let provider = standIn.makeProvider()
        try await provider.startConversation(instructions: "", model: "gpt-a", recap: nil)
        let answer = try await provider.answer(turn(brainNote: "From notes/a.md: x"), request: AnswerRequest(model: "gpt-a"), progress: { _ in })
        #expect(answer.text == "First finding.\n\nSecond finding. [POINT:40,12:file menu]")
    }
}
