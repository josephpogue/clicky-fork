import Foundation
import Testing
@testable import ClickyCore

@Suite("Question turn builder")
struct QuestionsTurnBuilderTests {
    private typealias Fixtures = QuestionsFixtures
    private let directory = URL(fileURLWithPath: "/tmp/clicky-test-shots", isDirectory: true)

    @Test func singleDisplayLabel() {
        let current = Fixtures.group(id: 1, capturedAt: Fixtures.time(14, 0), appName: "Xcode", windowTitle: "Clicky")
        let turn = QuestionTurnBuilder.turn(
            questionText: "where is it", currentGroup: current, earlierGroup: nil,
            shotsDirectory: directory, contextNote: "", timeZone: Fixtures.utc
        )
        #expect(turn.questionText == "where is it")
        #expect(turn.contextNote == "")
        #expect(turn.images.count == 1)
        #expect(turn.images[0].label == "screen1, the user's screen (cursor is here), image 1280x800 pixels")
        #expect(turn.images[0].fileURL == directory.appendingPathComponent("1-screen1.jpg"))
        #expect(turn.images[0].pixelWidth == 1280)
        #expect(turn.images[0].pixelHeight == 800)
    }

    @Test func severalDisplaysInScreenOrder() {
        let second = Fixtures.shot(
            fileName: "5-screen2.jpg", screenNumber: 2, isCursorScreen: false, pixelWidth: 1920, pixelHeight: 1080
        )
        let first = Fixtures.shot(fileName: "5-screen1.jpg", screenNumber: 1, isCursorScreen: true)
        // given out of order on purpose
        let current = Fixtures.group(
            id: 5, capturedAt: Fixtures.time(14, 0), appName: "Xcode", windowTitle: nil, shots: [second, first]
        )
        let turn = QuestionTurnBuilder.turn(
            questionText: "q", currentGroup: current, earlierGroup: nil,
            shotsDirectory: directory, contextNote: "note", timeZone: Fixtures.utc
        )
        #expect(turn.contextNote == "note")
        #expect(turn.images.map(\.label) == [
            "screen1 of 2, cursor is on this screen (primary focus), image 1280x800 pixels",
            "screen2 of 2, secondary screen, image 1920x1080 pixels",
        ])
    }

    @Test func earlierViewComesAfterCurrentAndIsLabelled() {
        let current = Fixtures.group(id: 5, capturedAt: Fixtures.time(14, 8), appName: "Xcode", windowTitle: "Clicky")
        let earlier = Fixtures.group(id: 2, capturedAt: Fixtures.time(14, 3), appName: "Terminal", windowTitle: "zsh")
        let turn = QuestionTurnBuilder.turn(
            questionText: "q", currentGroup: current, earlierGroup: earlier,
            shotsDirectory: directory, contextNote: "", timeZone: Fixtures.utc
        )
        #expect(turn.images.count == 2)
        #expect(turn.images[1].label
            == "earlier view from 14:03 in Terminal (zsh), screen1, image 1280x800 pixels, for context only, do not point at it")
        #expect(turn.images[1].fileURL == directory.appendingPathComponent("2-screen1.jpg"))
    }

    @Test func earlierLabelDropsMissingWindowTitle() {
        let current = Fixtures.group(id: 5, capturedAt: Fixtures.time(14, 8), appName: "Xcode", windowTitle: "Clicky")
        let earlier = Fixtures.group(id: 2, capturedAt: Fixtures.time(14, 3), appName: "Finder", windowTitle: nil)
        let turn = QuestionTurnBuilder.turn(
            questionText: "q", currentGroup: current, earlierGroup: earlier,
            shotsDirectory: directory, contextNote: "", timeZone: Fixtures.utc
        )
        #expect(turn.images[1].label.hasPrefix("earlier view from 14:03 in Finder, screen1,"))
    }
}

@Suite("Conversation budget")
struct QuestionsConversationBudgetTests {
    @Test func startsFreshAtFifteenTurns() {
        var budget = ConversationBudget()
        for _ in 0..<14 { budget.recordTurn(imageCount: 1) }
        #expect(budget.shouldStartFresh == false)
        budget.recordTurn(imageCount: 1)
        #expect(budget.shouldStartFresh == true)
    }

    @Test func startsFreshAtFortyImages() {
        var budget = ConversationBudget()
        budget.recordTurn(imageCount: 39)
        #expect(budget.shouldStartFresh == false)
        budget.recordTurn(imageCount: 1)
        #expect(budget.shouldStartFresh == true)
    }

    @Test func resetClearsBoth() {
        var budget = ConversationBudget()
        budget.recordTurn(imageCount: 40)
        budget.reset()
        #expect(budget.shouldStartFresh == false)
        budget.recordTurn(imageCount: 2)
        #expect(budget.shouldStartFresh == false)
    }
}

@Suite("Recap builder")
struct QuestionsRecapBuilderTests {
    private let header = "Recap of this session so far (screenshots not included):\n"

    @Test func emptyGivesNil() {
        #expect(RecapBuilder.recap(exchanges: []) == nil)
    }

    @Test func listsExchangesAndStripsPointTags() {
        let text = RecapBuilder.recap(exchanges: [
            (question: "where is save", answer: "Top right. [POINT:1180,40:save button]"),
            (question: "and open", answer: "In the menu. [POINT:none]"),
        ])
        #expect(text == header + "Q: where is save\nA: Top right.\nQ: and open\nA: In the menu.")
    }

    @Test func dropsOldestExchangesFirst() throws {
        // each block is "Q: q1\nA: aaaa" = 13 chars; with header, two blocks and a joining newline
        let limit = header.count + 13 + 1 + 13
        let text = try #require(RecapBuilder.recap(
            exchanges: [
                (question: "q1", answer: "aaaa"),
                (question: "q2", answer: "bbbb"),
                (question: "q3", answer: "cccc"),
            ],
            maximumCharacters: limit
        ))
        #expect(text == header + "Q: q2\nA: bbbb\nQ: q3\nA: cccc")
    }

    @Test func cutsASingleOversizedExchange() throws {
        let text = try #require(RecapBuilder.recap(
            exchanges: [(question: "q", answer: String(repeating: "x", count: 500))],
            maximumCharacters: 100
        ))
        #expect(text.count == 100)
        #expect(text.hasSuffix("..."))
        #expect(text.hasPrefix(header + "Q: q\nA: xxx"))
    }
}

@Suite("Answer instructions")
struct QuestionsAnswerInstructionsTests {
    @Test func questionInstructionsCarryTheRules() {
        let text = AnswerInstructions.questionInstructions
        #expect(text.contains("[POINT:x,y:label:screenN]"))
        #expect(text.contains("[POINT:none]"))
        #expect(text.contains("one short sentence, two at most"))
        #expect(!text.contains("\u{2014}"))
        #expect(!text.contains("\u{2013}"))
        #expect(!text.lowercased().contains("spoken"))
        #expect(!text.lowercased().contains("text-to-speech"))
    }
}
