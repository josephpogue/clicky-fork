//
//  ChatWindowState+PanelSummary.swift
//  leanring-buddy
//
//  What the menu-bar panel's Open chat row says about the conversation.
//

import ClickyCore
import Foundation

extension ChatWindowState {
    /// How many answers the current conversation holds.
    var answerCount: Int {
        messages.filter { $0.role == .answer }.count
    }

    /// The text of the newest answer, nil with none.
    var lastAnswerText: String? {
        messages.last(where: { $0.role == .answer })?.text
    }

    var panelChatSummary: PanelOpenChatRowContent {
        PanelOpenChatRowContent(answerCount: answerCount, lastAnswerText: lastAnswerText)
    }
}
