//
//  SessionListView.swift
//  leanring-buddy
//
//  The list of past sessions, newest first as given. Each row says when it
//  ran, how long, how many questions, and whether it was saved to a project.
//

import SwiftUI

struct SessionListView: View {
    let items: [SessionListItem]
    let onOpen: (_ sessionID: String) -> Void
    /// Added for the design: lets the empty list offer a way forward. The
    /// button only shows when this is set.
    var onStartSession: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Sessions")
                    .font(DS.WindowText.windowTitle)
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer()
                if !items.isEmpty {
                    Text(items.count == 1 ? "1 session" : "\(items.count) sessions")
                        .font(DS.WindowText.metaNumbers)
                        .foregroundColor(DS.Colors.textMuted)
                        .accessibilityIdentifier("sessions.count")
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 14)

            if items.isEmpty {
                emptyList
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical) {
                    VStack(spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { itemPosition, sessionItem in
                            sessionRow(sessionItem)
                                .accessibilityIdentifier("sessions.row.\(itemPosition)")
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 16)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .background(DS.Colors.background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sessions.list")
    }

    private func sessionRow(_ sessionItem: SessionListItem) -> some View {
        Button(action: { onOpen(sessionItem.id) }) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(sessionItem.title)
                        .font(DS.WindowText.rowTitle)
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(metaLine(sessionItem))
                        .font(DS.WindowText.metaNumbers)
                        .foregroundColor(DS.Colors.textMuted)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if let savedProject = sessionItem.savedProject {
                    WindowStatusChip(text: savedProject, tint: DS.Colors.success, systemImageName: "checkmark")
                        .accessibilityLabel("Saved to \(savedProject)")
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(ClickyRowButtonStyle())
    }

    private func metaLine(_ sessionItem: SessionListItem) -> String {
        let questionWord = sessionItem.questionCount == 1 ? "question" : "questions"
        return [
            WindowTimeFormatting.dayAndTime(sessionItem.startedAt),
            WindowTimeFormatting.duration(sessionItem.durationSeconds),
            "\(sessionItem.questionCount) \(questionWord)",
        ].joined(separator: "  ·  ")
    }

    private var emptyList: some View {
        VStack(spacing: 14) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 26, weight: .regular))
                .foregroundColor(DS.Colors.textMuted)
            VStack(spacing: 6) {
                Text("No sessions yet")
                    .font(DS.WindowText.sectionTitle)
                    .foregroundColor(DS.Colors.textPrimary)
                Text("Each session you run is kept here with its questions, answers and screens, so you can look back or save it to a project.")
                    .font(DS.WindowText.body)
                    .lineSpacing(DS.WindowText.bodyLineSpacing)
                    .foregroundColor(DS.Colors.textMuted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 290)
            if let onStartSession {
                Button(action: onStartSession) {
                    Text("Start a session")
                }
                .clickyWindowButton(.primary)
                .accessibilityIdentifier("sessions.startSession")
            }
        }
        .padding(24)
        .padding(.bottom, 30)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sessions.empty")
    }
}
