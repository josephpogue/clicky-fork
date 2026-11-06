//
//  PanelChatRows.swift
//  leanring-buddy
//
//  The menu-bar panel's Open chat row and its usage-limit offer, as small
//  views that take plain values so previews can render them.
//

import ClickyCore
import SwiftUI

struct PanelOpenChatRowContent: Equatable {
    var answerCount: Int
    var lastAnswerText: String?

    var countText: String? { PanelChatSummary.countText(answerCount: answerCount) }
    var lastLine: String? { PanelChatSummary.lastLine(lastAnswerText: lastAnswerText) }
    var accessibilityValue: String {
        PanelChatSummary.accessibilityValue(answerCount: answerCount, lastAnswerText: lastAnswerText)
    }
}

/// "Open chat" with the answer count on the right and the start of the last
/// answer under the title. With no answers it is the single line it always was.
struct PanelOpenChatRow: View {
    let content: PanelOpenChatRowContent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text("Open chat")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(DS.Colors.textSecondary)
                        Spacer(minLength: 0)
                        if let countText = content.countText {
                            Text(countText)
                                .font(.system(size: 12))
                                .foregroundColor(DS.Colors.textTertiary)
                        }
                    }
                    if let lastLine = content.lastLine {
                        Text(lastLine)
                            .font(.system(size: 12))
                            .foregroundColor(DS.Colors.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Open chat")
        .accessibilityValue(content.accessibilityValue)
        .accessibilityIdentifier("panel.openChat")
        .accessibilityAddTraits(.isButton)
    }
}

/// The usage-limit message and its "Switch to <provider>" button, shown in
/// the panel because the chat window may never be open.
struct PanelUsageLimitOffer: View {
    let offer: UsageLimitOffer
    /// Disabled while a question is under way or a switch is running; the caption says which.
    var switchState: UsageLimitSwitchButtonState = .enabled
    let onSwitch: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(offer.message)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.warning)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("panel.usageLimit")

            Button(action: onSwitch) {
                Text("Switch to \(offer.switchToProviderName)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textOnAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                            .fill(DS.Colors.accent)
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .disabled(!switchState.isEnabled)
            .opacity(switchState.isEnabled ? 1 : 0.45)
            .accessibilityIdentifier("panel.switchProvider")

            if let caption = switchState.caption {
                Text(caption)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textMuted)
                    .accessibilityIdentifier("panel.switchProviderCaption")
            }
        }
    }
}
