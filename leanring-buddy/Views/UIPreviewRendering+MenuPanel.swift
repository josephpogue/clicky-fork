//
//  UIPreviewRendering+MenuPanel.swift
//  leanring-buddy
//
//  Preview PNGs for the menu-bar panel (menu-panel slice).
//

import AppKit
import ClickyCore
import SwiftUI

extension UIPreviewRendering {
    @MainActor
    static func renderMenuPanelPreviews(into directory: URL) throws {
        let lastAnswer = "Click Code, copy the HTTPS link,\n then run git clone with it in Terminal."
        let rows: [(String, PanelOpenChatRowContent)] = [
            ("menu-panel-open-chat-no-answers.png", PanelOpenChatRowContent(answerCount: 0, lastAnswerText: nil)),
            ("menu-panel-open-chat-1-answer.png", PanelOpenChatRowContent(answerCount: 1, lastAnswerText: "Open Settings and turn on Screen Recording.")),
            ("menu-panel-open-chat-3-answers.png", PanelOpenChatRowContent(answerCount: 3, lastAnswerText: lastAnswer)),
        ]
        for (fileName, content) in rows {
            try render(PanelRowsPreview { PanelOpenChatRow(content: content, action: {}) },
                       size: nil, fileName: fileName, into: directory)
        }

        let offer = UsageLimitOffer(
            message: "You've reached Claude's usage limit for now.",
            switchToProviderName: "ChatGPT"
        )
        try render(PanelRowsPreview { PanelUsageLimitOffer(offer: offer, onSwitch: {}) },
                   size: nil, fileName: "menu-panel-usage-limit-offer.png", into: directory)
        try render(PanelRowsPreview { PanelUsageLimitOffer(offer: offer, isSwitchEnabled: false, onSwitch: {}) },
                   size: nil, fileName: "menu-panel-usage-limit-offer-switch-waiting.png", into: directory)
    }
}

/// A slice of the panel at its real content width (320 wide, 16 padding each side).
private struct PanelRowsPreview<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(width: 320, alignment: .leading)
            .background(DS.Colors.background)
    }
}
