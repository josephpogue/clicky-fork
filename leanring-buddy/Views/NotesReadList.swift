//
//  NotesReadList.swift
//  leanring-buddy
//
//  "Notes read" under a finished answer in the chat: the notes the answer looked at, by file name only, with
//  the whole path on hover. Quiet on purpose (it backs the answer up, it is not the answer): small muted text,
//  no fills, no icons. The label and the names flow as one wrapping line, so two names usually fit on one row.
//  Past three names the rest fold into an "and 4 more" link that shows them all.
//

import SwiftUI

struct NotesReadList: View {
    /// Full paths (or paths inside a search folder), in the order read; see `ChatMessage.notesRead`.
    let notePaths: [String]
    let isExpanded: Bool
    let onToggleExpanded: () -> Void
    /// The chat message index, for the `chat.notesRead.<n>` identifiers.
    let messageIndex: Int

    static let collapsedNameCount = 3

    private var shownPaths: [String] {
        isExpanded ? notePaths : Array(notePaths.prefix(Self.collapsedNameCount))
    }

    private var hiddenCount: Int {
        max(notePaths.count - Self.collapsedNameCount, 0)
    }

    var body: some View {
        WrappingRowLayout(horizontalSpacing: 6, verticalSpacing: 3) {
                Text("Notes read")
                    .font(DS.WindowText.meta)
                    .foregroundColor(DS.Colors.textMuted)
                    .frame(height: Self.itemHeight)
                    .padding(.trailing, 4)
                ForEach(0..<shownPaths.count, id: \.self) { pathIndex in
                    // Commas between names, none after the last, so the line reads as a plain list:
                    // "demo-server.md, deploy-checklist.md, ports.md and 4 more".
                    noteName(path: shownPaths[pathIndex], isFollowedByComma: pathIndex < shownPaths.count - 1)
                }
                if hiddenCount > 0 {
                    Button(action: onToggleExpanded) {
                        Text(isExpanded ? "Show fewer" : "and \(hiddenCount) more")
                    }
                    .buttonStyle(WindowInlineLinkButtonStyle())
                    .frame(height: Self.itemHeight)
                    .accessibilityIdentifier("chat.notesRead.\(messageIndex).more")
                }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.notesRead.\(messageIndex)")
    }

    private static let itemHeight: CGFloat = 18

    private func noteName(path: String, isFollowedByComma: Bool) -> some View {
        let fileName = (path as NSString).lastPathComponent
        return HStack(spacing: 0) {
            Text(fileName)
                .font(DS.WindowText.meta)
                .foregroundColor(DS.Colors.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if isFollowedByComma {
                Text(",")
                    .font(DS.WindowText.meta)
                    .foregroundColor(DS.Colors.textMuted)
            }
        }
        // A very long name truncates in its middle instead of pushing past the card.
        .frame(maxWidth: 210, alignment: .leading)
        .frame(height: Self.itemHeight)
        .help((path as NSString).abbreviatingWithTildeInPath)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(fileName)
        .accessibilityValue(path)
    }
}
