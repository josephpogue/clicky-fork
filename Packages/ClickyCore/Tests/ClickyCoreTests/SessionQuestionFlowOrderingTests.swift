import Foundation
import Testing
@testable import ClickyCore

/// Fix wave 2, group W1: a new question, Stop or an answer's return landing inside the flow's own awaits. The app pairs
/// every answer report with its answer by number, so each answer sends one ended report or none, and nothing for an
/// ended answer ever reaches the screen, voice or pointer.
@Suite("Session question flow: ordering inside the flow's awaits")
struct SessionQuestionFlowOrderingTests {
    private typealias Stream = FakeAnswerProvider.ScriptedStream

    private static let leasePassage = BrainPassage(
        path: "/notes/lease.md", heading: "Term", startLine: 4, endLine: 9, text: "The lease ends in May.", score: 3
    )

    private func startedHarness(
        questions: [String], isBrainOn: Bool = false,
        digDeeperRequest: (@Sendable (ProviderID) async -> AnswerRequest)? = nil
    ) async throws -> FlowHarness {
        let harness = FlowHarness(
            questions: questions, isBrainOn: isBrainOn, passages: isBrainOn ? [Self.leasePassage] : [],
            digDeeperRequest: digDeeperRequest
        )
        try await harness.flow.begin()
        return harness
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<300 where !condition() { try await Task.sleep(nanoseconds: 10_000_000) }
    }

    private func settle() async throws { try await Task.sleep(nanoseconds: 60_000_000) }

    private func tapNewQuestion(_ harness: FlowHarness) async -> SessionSignalOutcome {
        await harness.flow.handle(.questionStarted(at: FlowHarness.startTime.addingTimeInterval(5)))
    }

    private func sendQuestion(_ harness: FlowHarness) async -> SessionSignalOutcome {
        await harness.flow.handle(.sendQuestion(
            speechFrom: FlowHarness.startTime, speechTo: FlowHarness.startTime.addingTimeInterval(3)
        ))
    }

    // MARK: Every question has its own number

    @Test func twoQuestionsOneAfterTheOtherCarryDifferentAnswerNumbers() async throws {
        let harness = try await startedHarness(questions: ["one", "two"])
        await harness.askQuestion()
        await harness.askQuestion()
        #expect(harness.output.askedAnswerNumbers.count == 2)
        #expect(Set(harness.output.askedAnswerNumbers).count == 2)
        #expect(harness.output.finalAnswerNumbers == harness.output.askedAnswerNumbers)
    }

    // MARK: Finding 1: the answer's own log writes are awaited before it is shown

    @Test(arguments: ["timing line", "answer line"])
    func aNewQuestionDuringTheAnswersLogWritesGetsOneEndedReportAndNoSecondCard(heldWrite: String) async throws {
        let harness = try await startedHarness(questions: ["first question", "second question"])
        harness.claude.scriptStreams([
            Stream(progress: [.textSoFar("Old answer.")], finalText: "Old answer."),
        ])
        let logGate = TestGate()
        harness.logHold.holdNextWrite(where: { kind in
            switch kind {
            case .answerTiming: return heldWrite == "timing line"
            case .answer: return heldWrite == "answer line"
            default: return false
            }
        }, at: logGate)
        let first = Task { await harness.askQuestion() }
        await logGate.waitUntilReached()
        let oldNumber = try #require(harness.output.askedAnswerNumbers.first)

        // The new question's tap lands while the old answer is being logged; the phase is still waiting for it.
        let outcome = await tapNewQuestion(harness)
        logGate.open()
        _ = await first.value
        try await settle()

        #expect(outcome == .accepted)
        #expect(harness.output.finalAnswerNumbers.isEmpty)
        #expect(harness.output.answers.isEmpty)
        #expect(harness.output.pointers.isEmpty)
        #expect(harness.output.cutAnswerNumbers == [oldNumber])
        #expect(harness.output.cutReasons == [.completedAfterNewerQuestion])
        #expect(harness.output.cutShorts.map(\.visibleText) == ["Old answer."])
    }

    @Test func anAnswerThatWasCutShortOnItsOwnAndSupersededDuringItsLogWriteReportsNewerQuestion() async throws {
        let harness = try await startedHarness(questions: ["first question", "second question"])
        harness.claude.scriptStreams([
            Stream(progress: [.textSoFar("Going round in")], endsEarlyOnItsOwn: true),
        ])
        let logGate = TestGate()
        harness.logHold.holdNextWrite(where: { if case .answer = $0 { return true } else { return false } }, at: logGate)
        let first = Task { await harness.askQuestion() }
        await logGate.waitUntilReached()
        _ = await tapNewQuestion(harness)
        logGate.open()
        _ = await first.value
        try await settle()

        #expect(harness.output.cutReasons == [.newerQuestion])
        #expect(harness.output.cutShorts.map(\.visibleText) == ["Going round in"])
        #expect(harness.output.finalAnswerNumbers.isEmpty)
    }

    @Test func stopDuringTheAnswersLogWriteSendsNothingForIt() async throws {
        let harness = try await startedHarness(questions: ["first question"])
        harness.claude.scriptStreams([Stream(progress: [.textSoFar("Old answer.")], finalText: "Old answer.")])
        let logGate = TestGate()
        harness.logHold.holdNextWrite(where: { if case .answer = $0 { return true } else { return false } }, at: logGate)
        let first = Task { await harness.askQuestion() }
        await logGate.waitUntilReached()
        let stopping = Task { await harness.flow.finish(summaryEnabled: false) }
        try await settle()
        logGate.open()
        _ = await first.value
        _ = await stopping.value

        #expect(harness.output.finalAnswerNumbers.isEmpty)
        #expect(harness.output.cutAnswerNumbers.isEmpty)
        #expect(harness.output.notices.isEmpty)
    }

    // MARK: Finding 2: a failure is judged after its log write

    @Test(arguments: ["text streamed", "no text"])
    func aFailureSupersededDuringItsLogWriteShowsNoNoticeAndReportsOnce(streamed: String) async throws {
        let harness = try await startedHarness(questions: ["first question", "second question"])
        let progress: [AnswerProgress] = streamed == "text streamed" ? [.textSoFar("Partial answer")] : []
        harness.claude.scriptStreams([
            Stream(progress: progress, failureAfterProgress: .usageLimitReached(message: "limit")),
        ])
        let logGate = TestGate()
        harness.logHold.holdNextWrite(where: { if case .answerFailed = $0 { return true } else { return false } }, at: logGate)
        let first = Task { await harness.askQuestion() }
        await logGate.waitUntilReached()
        let oldNumber = try #require(harness.output.askedAnswerNumbers.first)
        _ = await tapNewQuestion(harness)
        logGate.open()
        _ = await first.value
        try await settle()

        #expect(harness.output.notices.isEmpty)
        #expect(harness.output.offers.isEmpty)
        #expect(harness.output.cutAnswerNumbers == [oldNumber])
        #expect(harness.output.cutReasons == [.newerQuestion])
        #expect(harness.output.cutShorts.map(\.visibleText) == [streamed == "text streamed" ? "Partial answer" : ""])
    }

    @Test func aFailureOfTheOlderAnswerDoesNotReportTheNewerAnswersText() async throws {
        let harness = try await startedHarness(questions: ["first question", "second question"])
        harness.claude.scriptStreams([
            Stream(progress: [.textSoFar("Old partial")], failureAfterProgress: .failed(message: "boom")),
            Stream(progress: [.textSoFar("New partial")], pausesAfterProgress: true),
        ])
        let logGate = TestGate()
        harness.logHold.holdNextWrite(where: { if case .answerFailed = $0 { return true } else { return false } }, at: logGate)
        let first = Task { await harness.askQuestion() }
        await logGate.waitUntilReached()
        _ = await tapNewQuestion(harness)
        let second = Task { await sendQuestion(harness) }
        try await waitUntil { harness.output.textChanges.contains("New partial") }
        logGate.open()
        _ = await first.value
        try await settle()
        harness.claude.releasePausedStream()
        _ = await second.value

        #expect(harness.output.cutShorts.map(\.visibleText).first == "Old partial")
    }

    // MARK: Finding 3: the waiting phase is in place before its report is awaited

    @Test func aNewQuestionWhileTheWaitingPhaseIsBeingReportedGetsOneEndedReportAndNeverReachesTheProvider() async throws {
        let harness = try await startedHarness(questions: ["first question", "second question"])
        let phaseGate = TestGate()
        harness.output.holdNextPhaseChange(to: .waitingForAnswer(provider: .claude), at: phaseGate)
        let first = Task { await harness.askQuestion() }
        await phaseGate.waitUntilReached()
        let oldNumber = try #require(harness.output.askedAnswerNumbers.first)

        let outcome = await tapNewQuestion(harness)
        phaseGate.open()
        _ = await first.value
        try await settle()

        #expect(outcome == .accepted)
        #expect(harness.output.cutAnswerNumbers == [oldNumber])
        #expect(harness.output.cutReasons == [.newerQuestion])
        #expect(harness.output.cutShorts.map(\.visibleText) == [""])
        #expect(harness.claude.askedTurns.isEmpty)
        #expect(harness.output.finalAnswerNumbers.isEmpty)
    }

    @Test func stopWhileTheWaitingPhaseIsBeingReportedSendsNothingAndNeverReachesTheProvider() async throws {
        let harness = try await startedHarness(questions: ["first question"])
        let phaseGate = TestGate()
        harness.output.holdNextPhaseChange(to: .waitingForAnswer(provider: .claude), at: phaseGate)
        let first = Task { await harness.askQuestion() }
        await phaseGate.waitUntilReached()
        let stopping = Task { await harness.flow.finish(summaryEnabled: false) }
        try await settle()
        phaseGate.open()
        _ = await first.value
        _ = await stopping.value

        #expect(harness.output.cutAnswerNumbers.isEmpty)
        #expect(harness.output.finalAnswerNumbers.isEmpty)
        #expect(harness.claude.askedTurns.isEmpty)
    }

    // MARK: Finding 4: the old answer's stop starts before the first await of the new tap

    @Test func aSendDuringTheNewTapsListeningReportWaitsForTheOldAnswersStop() async throws {
        let harness = try await startedHarness(questions: ["first question", "second question"])
        harness.claude.scriptStreams([
            Stream(progress: [.textSoFar("Partial answer")], pausesAfterProgress: true),
            Stream(progress: [.textSoFar("Second.")], finalText: "Second."),
        ])
        let first = Task { await harness.askQuestion() }
        try await waitUntil { !harness.output.textChanges.isEmpty }
        let stopGate = TestGate()
        harness.claude.holdNextStop(at: stopGate)
        let listeningGate = TestGate()
        harness.output.holdNextPhaseChange(to: .listening, at: listeningGate)

        let tap = Task { await tapNewQuestion(harness) }
        await listeningGate.waitUntilReached()
        let send = Task { await sendQuestion(harness) }
        try await settle()

        // The old answer's interrupt is still pending, so the new question must not be transcribed yet.
        #expect(harness.output.timeline.filter { $0 == "transcribe" }.count == 1)
        stopGate.open()
        listeningGate.open()
        _ = await tap.value
        _ = await send.value
        _ = await first.value
        #expect(harness.output.timeline.filter { $0 == "transcribe" }.count == 2)
        #expect(harness.output.answers.map(\.spokenText) == ["Second."])
    }

    // MARK: Finding 5: dig deeper keeps the real earlier question

    @Test func aSecondDigDeeperSearchesWithTheRealEarlierQuestion() async throws {
        let harness = try await startedHarness(
            questions: ["what is the lease term", "dig deeper", "dig deeper on the deposit"], isBrainOn: true,
            digDeeperRequest: { _ in AnswerRequest(model: "opus", effort: .high) }
        )
        await harness.askQuestion()
        await harness.askQuestion()
        await harness.askQuestion()
        #expect(harness.passageSearches.map(\.query) == [
            "what is the lease term", "what is the lease term", "what is the lease term the deposit",
        ])
    }

    // MARK: Finding 6 is covered with the completed-after-stop tests in the overlap suite.

    // MARK: Every interleaving

    private enum Step: CaseIterable, Equatable, CustomStringConvertible {
        case tapNew, sendNew, oldReturns, stop
        var description: String {
            switch self {
            case .tapNew: return "tapNew"
            case .sendNew: return "sendNew"
            case .oldReturns: return "oldReturns"
            case .stop: return "stop"
            }
        }
    }

    private enum Variant: CaseIterable { case plain, completesDespiteStop, answerLogHeld }

    /// Every ordered selection of the four steps, with the send only after a new tap.
    private static func allSequences() -> [[Step]] {
        var found: [[Step]] = [[]]
        var frontier: [[Step]] = [[]]
        while !frontier.isEmpty {
            var next: [[Step]] = []
            for sequence in frontier {
                for step in Step.allCases where !sequence.contains(step) {
                    if step == .sendNew && !sequence.contains(.tapNew) { continue }
                    next.append(sequence + [step])
                }
            }
            found += next
            frontier = next
        }
        return found
    }

    private struct OutputCounts: Equatable {
        var finals: Int, cuts: Int, notices: Int, pointers: Int, offers: Int, texts: Int
    }

    private func counts(_ output: RecordingFlowOutput) -> OutputCounts {
        OutputCounts(
            finals: output.finalAnswerNumbers.count, cuts: output.cutAnswerNumbers.count,
            notices: output.notices.count, pointers: output.pointers.count, offers: output.offers.count,
            texts: output.textChanges.count
        )
    }

    private func runInterleaving(_ sequence: [Step], variant: Variant) async throws -> [String] {
        var problems: [String] = []
        let label = "\(variant) \(sequence)"
        let harness = try await startedHarness(questions: ["one", "two"])
        harness.claude.scriptStreams([
            Stream(
                progress: [.textSoFar("Old answer.")], pausesAfterProgress: true, finalText: "Old answer.",
                completesDespiteStop: variant == .completesDespiteStop
            ),
            Stream(progress: [.textSoFar("Second.")], finalText: "Second."),
        ])
        let stopGate = TestGate()
        harness.claude.holdNextStop(at: stopGate)
        let logGate = TestGate()
        if variant == .answerLogHeld {
            harness.logHold.holdNextWrite(where: { if case .answerTiming = $0 { return true } else { return false } }, at: logGate)
        }
        let first = Task { await harness.askQuestion() }
        try await waitUntil { !harness.output.textChanges.isEmpty }
        let oldNumber = harness.output.askedAnswerNumbers.first ?? -1

        var tasks: [Task<Void, Never>] = []
        var stopSnapshot: OutputCounts?
        var hasTapped = false
        var hasStopped = false
        for step in sequence {
            switch step {
            case .tapNew:
                hasTapped = true
                tasks.append(Task { _ = await self.tapNewQuestion(harness) })
            case .sendNew:
                tasks.append(Task { _ = await self.sendQuestion(harness) })
            case .oldReturns:
                harness.claude.releasePausedStream()
            case .stop:
                hasStopped = true
                tasks.append(Task { _ = await harness.flow.finish(summaryEnabled: false) })
            }
            try await settle()
            if step == .stop { stopSnapshot = counts(harness.output) }
        }
        // Whatever was left waiting is let go, in the order a real session would let it.
        stopGate.open()
        logGate.open()
        harness.claude.releasePausedStream()
        _ = await first.value
        for task in tasks { await task.value }
        try await settle()

        let output = harness.output
        let reportNumbers = output.finalAnswerNumbers + output.cutAnswerNumbers
        for number in Set(reportNumbers) where reportNumbers.filter({ $0 == number }).count > 1 {
            problems.append("\(label): answer \(number) reported more than once")
        }
        let askedNumbers = output.askedAnswerNumbers
        if Set(askedNumbers).count != askedNumbers.count { problems.append("\(label): answer numbers repeat \(askedNumbers)") }
        for number in output.cutAnswerNumbers + output.finalAnswerNumbers where !askedNumbers.contains(number) {
            problems.append("\(label): report for answer \(number) that was never asked")
        }
        // An answer a newer question ended never shows as a received answer.
        if hasTapped && output.finalAnswerNumbers.contains(oldNumber) {
            let oldReturnedFirst = sequence.firstIndex(of: .oldReturns).map { returned in
                returned < (sequence.firstIndex(of: .tapNew) ?? Int.max)
            } ?? false
            if variant == .answerLogHeld || !oldReturnedFirst {
                problems.append("\(label): old answer shown as received after a newer question")
            }
        }
        // A newer question ended the old answer and Stop did not: it reported exactly once.
        if hasTapped && !hasStopped && reportNumbers.filter({ $0 == oldNumber }).count != 1 {
            problems.append("\(label): old answer reported \(reportNumbers.filter { $0 == oldNumber }.count) times")
        }
        if !hasStopped && sequence.contains(.sendNew) {
            if askedNumbers.count != 2 || !output.finalAnswerNumbers.contains(askedNumbers[1]) {
                problems.append("\(label): the new question never answered (asked \(askedNumbers))")
            }
        }
        if output.cutReasons.contains(.stopped) { problems.append("\(label): a stopped report went to the app") }
        if let stopSnapshot, stopSnapshot != counts(output) {
            problems.append("\(label): output after Stop \(stopSnapshot) then \(counts(output))")
        }
        if hasStopped {
            let afterStopNotices = output.notices
            if !afterStopNotices.isEmpty { problems.append("\(label): notice after Stop \(afterStopNotices)") }
        }
        return problems
    }

    @Test func everyInterleavingOfANewTapASendTheOldAnswerReturningAndStopKeepsTheContract() async throws {
        var problems: [String] = []
        var runs = 0
        for variant in Variant.allCases {
            for sequence in Self.allSequences() {
                runs += 1
                problems += try await runInterleaving(sequence, variant: variant)
            }
        }
        #expect(runs > 100)
        #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }
}
