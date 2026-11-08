import Foundation
@testable import ClickyCore

/// A bubble that holds about 9 lines of about 45 characters, the way the real one is sized: greedy word wrap.
func modelledBubbleFits(_ text: String) -> Bool {
    let maximumLineCount = 9
    let lineWidth = 45
    var lineCount = 1
    var currentLength = 0
    for word in text.split(separator: " ") {
        if currentLength == 0 {
            currentLength = word.count
        } else if currentLength + 1 + word.count <= lineWidth {
            currentLength += 1 + word.count
        } else {
            lineCount += 1
            currentLength = word.count
        }
    }
    return lineCount <= maximumLineCount
}

/// Feeds one answer through the same pipeline the coordinator uses (the visible-text rule, the parts tracker, the
/// cursor line, the bubble state and the checking-line rule) and records what the bubble shows and what is spoken.
struct AnswerReplay {
    var rawText = ""
    private var separatorPending = false
    var tracker = AnswerPartsTracker()
    var cursorLineState = CursorLineState()
    var bubble = GrowingAnswerBubbleState()
    var checkingRule = CheckingNotesRule()
    var fits: (String) -> Bool = modelledBubbleFits

    /// What the bubble on screen shows now; nil when no bubble is on screen.
    var shownLine: CursorLine?
    var showsCheckingLine = false
    var spoken: [String] = []
    /// Every distinct line the bubble showed, in order.
    var shownLines: [CursorLine] = []

    /// A new text block begins: the next text is joined to the earlier one with a space, as the Claude provider does.
    mutating func startBlock() { separatorPending = true }

    /// One streamed piece of text.
    mutating func delta(_ piece: String) {
        if separatorPending && !rawText.isEmpty && !rawText.hasSuffix("\n") { rawText += " " }
        separatorPending = false
        rawText += piece
        let view = StreamingAnswerText.visible(rawTextSoFar: rawText)
        tracker.textReported(view.visibleText, endsBeforeHiddenText: view.endsBeforeHiddenText)
        checkingRule.textChanged(visibleTextSoFar: view.visibleText)
        refreshCursorLine()
    }

    /// The coordinator's order at a tool call: the parts end, the line is refreshed, the bubble is told, then the
    /// checking line shows when the rule says so.
    mutating func toolCall() {
        tracker.toolCallStarted()
        refreshCursorLine()
        bubble.toolCallStartedReported()
        let visible = StreamingAnswerText.visible(rawTextSoFar: rawText).visibleText
        if checkingRule.toolCallStarted(visibleTextSoFar: visible) {
            apply(bubble.checkingLineReported())
        }
    }

    /// The final answer: every part is complete, and the checking line goes.
    mutating func final(_ rawFinalText: String) {
        tracker.finalReported(PointTagParser.parse(rawFinalText).spokenText)
        refreshCursorLine()
        apply(bubble.answerFinished())
    }

    /// The answer ended early for any reason.
    mutating func cutShort() {
        apply(bubble.answerFinished())
    }

    /// The user clicked or pressed a key.
    mutating func userDismisses() {
        bubble.userDismissed()
        shownLine = nil
        showsCheckingLine = false
    }

    private mutating func refreshCursorLine() {
        let update = cursorLineState.update(parts: tracker.parts, fits: fits)
        spoken += update.newSentencesToSpeak
        if let line = update.line { apply(bubble.lineReported(line)) }
    }

    mutating func apply(_ action: GrowingAnswerBubbleState.Action) {
        switch action {
        case .nothing:
            return
        case .show(let line, let checking), .update(let line, let checking):
            shownLine = line
            showsCheckingLine = checking
            if shownLines.last != line { shownLines.append(line) }
        case .hide:
            shownLine = nil
            showsCheckingLine = false
        }
    }
}
