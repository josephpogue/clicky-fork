import Foundation
import Testing
@testable import ClickyCore

/// Fix wave 2, items 1, 2 and 4: the checking line goes when it stops being true, and the footer follows the chat key.
@Suite("Fix wave 2: checking line and footer")
struct Fix2AnswerEndTests {
    private func line(_ text: String, hasMore: Bool = false) -> CursorLine { CursorLine(text: text, hasMoreInChat: hasMore) }

    // MARK: 1. Two searches in a row, both parts chat-only (or the same line)

    /// Item 1, the reported case: footer-only, a search, footer-only again. The second part's line equals the first,
    /// and it must still reach the bubble so "Checking your notes" goes.
    @Test func footerOnlyThenSearchThenFooterOnlyClearsTheCheckingLine() {
        var replay = AnswerReplay()
        replay.delta("[CHAT] First details.")
        #expect(replay.shownLine == line("", hasMore: true))
        replay.toolCall()
        #expect(replay.showsCheckingLine)
        replay.startBlock()
        replay.delta("[CHAT] Second details.")
        #expect(replay.shownLine == line("", hasMore: true))
        #expect(!replay.showsCheckingLine)
    }

    @Test func aTextLineThenSearchThenTheSameTextClearsTheCheckingLine() {
        var replay = AnswerReplay()
        replay.delta("Your port is 80.")
        replay.toolCall()
        #expect(replay.shownLine == line("Your port is 80."))
        #expect(replay.showsCheckingLine)
        replay.startBlock()
        replay.delta("Your port is 80. Done")
        #expect(replay.shownLine == line("Your port is 80."))
        #expect(!replay.showsCheckingLine)
    }

    @Test func footerOnlyThenSearchThenATextLineClearsTheCheckingLine() {
        var replay = AnswerReplay()
        replay.delta("[CHAT] First details.")
        replay.toolCall()
        replay.startBlock()
        replay.delta("Your port is 80. Done")
        #expect(replay.shownLine == line("Your port is 80."))
        #expect(!replay.showsCheckingLine)
    }

    @Test func aNewPartsFirstLineIsAChangeEvenWhenItEqualsTheLastOne() {
        var state = CursorLineState()
        let firstPart = AnswerPart(cursorText: "Same.", chatText: "", hasChatMarker: false, isCursorTextComplete: true)
        let first = state.update(parts: [firstPart], fits: { _ in true })
        #expect(first.line == line("Same."))
        #expect(state.update(parts: [firstPart], fits: { _ in true }).line == nil)
        let second = state.update(parts: [firstPart, firstPart], fits: { _ in true })
        #expect(second.line == line("Same."))
        #expect(second.newSentencesToSpeak == ["Same."])
        #expect(state.update(parts: [firstPart, firstPart], fits: { _ in true }).line == nil)
    }

    /// The dismissed rules stay as they are: a bubble the user clicked away stays away for a line it already showed.
    @Test func aClickedAwayBubbleStaysAwayWhenTheNextPartRepeatsItsLine() {
        var replay = AnswerReplay()
        replay.delta("[CHAT] First details.")
        replay.toolCall()
        replay.userDismisses()
        replay.startBlock()
        replay.delta("[CHAT] Second details.")
        #expect(replay.shownLine == nil)
    }

    // MARK: 2. The checking line goes when the answer ends

    @Test func theFinalAnswerWithNoCursorTextHidesABubbleThatShowedOnlyTheCheckingLine() {
        var replay = AnswerReplay()
        replay.toolCall()
        #expect(replay.shownLine == line(""))
        #expect(replay.showsCheckingLine)
        replay.final("")
        #expect(replay.shownLine == nil)
        #expect(!replay.showsCheckingLine)
    }

    @Test func theFinalAnswerThatLivesOnlyInTheChatShowsTheFooterAloneInPlaceOfTheCheckingLine() {
        var replay = AnswerReplay()
        replay.toolCall()
        replay.startBlock()
        replay.final("[CHAT] Everything is here. [POINT:none]")
        #expect(replay.shownLine == line("", hasMore: true))
        #expect(!replay.showsCheckingLine)
    }

    @Test func anAnswerCutShortAfterASearchLosesTheCheckingLineWhateverTheReason() {
        var replay = AnswerReplay()
        replay.delta("Your port is 80.")
        replay.toolCall()
        #expect(replay.showsCheckingLine)
        replay.cutShort()
        #expect(replay.shownLine == line("Your port is 80."))
        #expect(!replay.showsCheckingLine)
    }

    @Test func anAnswerCutShortWithOnlyTheCheckingLineHidesTheBubble() {
        var replay = AnswerReplay()
        replay.toolCall()
        replay.cutShort()
        #expect(replay.shownLine == nil)
    }

    @Test func aBubbleBroughtBackAfterTheCheckingOnlyBubbleWentShowsNormally() {
        var bubble = GrowingAnswerBubbleState()
        _ = bubble.checkingLineReported()
        #expect(bubble.answerFinished() == .hide)
        #expect(bubble.answerFinished() == .nothing)
        #expect(bubble.lineReported(line("Late text.")) == .show(line: line("Late text."), showsCheckingLine: false))
    }

    @Test func aDismissedCheckingBubbleNeedsNoHide() {
        var bubble = GrowingAnswerBubbleState()
        _ = bubble.checkingLineReported()
        bubble.userDismissed()
        #expect(bubble.answerFinished() == .nothing)
    }

    // MARK: 4. The footer follows the chat key

    @Test func theFooterNamesTheWorkingChatKeyAndOtherwisePointsAtTheMenuBar() {
        let withMore = line("Short answer.", hasMore: true)
        #expect(CursorFooter.text(for: withMore, chatKeyName: "Right ⌘ ,") == "More in chat: Right ⌘ ,")
        #expect(CursorFooter.text(for: withMore, chatKeyName: nil) == "More in Open chat, in the menu bar")
        #expect(CursorFooter.text(for: line("", hasMore: true), chatKeyName: "Right ⌘ ,") == "Answer in chat: Right ⌘ ,")
        #expect(CursorFooter.text(for: line("", hasMore: true), chatKeyName: nil) == "More in Open chat, in the menu bar")
        #expect(CursorFooter.text(for: line("All of it."), chatKeyName: "Right ⌘ ,") == nil)
    }

    @Test func aFooterAloneDropsItsFooterWhileTheCheckingLineShows() {
        #expect(CursorFooter.text(for: line("", hasMore: true), chatKeyName: "Right ⌘ ,", showsCheckingLine: true) == nil)
        #expect(CursorFooter.text(for: line("Text.", hasMore: true), chatKeyName: "Right ⌘ ,", showsCheckingLine: true)
            == "More in chat: Right ⌘ ,")
    }

    @Test func aBubbleOnScreenIsRedrawnWhenTheKeyItNamesStopsWorkingOrChanges() {
        let withMore = line("Short answer.", hasMore: true)
        #expect(CursorFooter.needsRedraw(line: withMore, showsCheckingLine: false, oldChatKeyName: "Right ⌘ ,", newChatKeyName: nil))
        #expect(CursorFooter.needsRedraw(line: withMore, showsCheckingLine: false, oldChatKeyName: "Right ⌘ ,", newChatKeyName: "Right ⌥ J"))
        #expect(CursorFooter.needsRedraw(line: withMore, showsCheckingLine: false, oldChatKeyName: nil, newChatKeyName: "Right ⌘ ,"))
        #expect(!CursorFooter.needsRedraw(line: withMore, showsCheckingLine: false, oldChatKeyName: "Right ⌘ ,", newChatKeyName: "Right ⌘ ,"))
        #expect(!CursorFooter.needsRedraw(line: line("All."), showsCheckingLine: false, oldChatKeyName: "Right ⌘ ,", newChatKeyName: nil))
        #expect(!CursorFooter.needsRedraw(
            line: line("", hasMore: true), showsCheckingLine: true, oldChatKeyName: "Right ⌘ ,", newChatKeyName: nil))
    }
}
