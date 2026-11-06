//
//  SessionDetailView.swift
//  leanring-buddy
//
//  One past session: the summary on top, then the timeline of app switches,
//  spoken lines, questions and answers, each with its time. Questions carry
//  the most weight so the eye can run down them; screenshots sit as small
//  thumbnails and open larger inside the window on click.
//

import AppKit
import SwiftUI

struct SessionDetailView: View {
    let state: SessionDetailState
    let onSave: () -> Void
    let onRevealInFinder: () -> Void

    @State private var enlargedShotFileURL: URL?

    init(
        state: SessionDetailState,
        onSave: @escaping () -> Void,
        onRevealInFinder: @escaping () -> Void,
        initiallyEnlargedShotFileURL: URL? = nil
    ) {
        self.state = state
        self.onSave = onSave
        self.onRevealInFinder = onRevealInFinder
        self._enlargedShotFileURL = State(initialValue: initiallyEnlargedShotFileURL)
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header
                if let savedNotePath = state.savedNotePath {
                    savedStrip(savedNotePath)
                }
                Rectangle().fill(DS.Colors.borderSubtle.opacity(0.6)).frame(height: 1)
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 20) {
                        if let summary = state.summary {
                            summaryBlock(summary)
                        }
                        timeline
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollBounceBehavior(.basedOnSize)
            }

            if let enlargedShotFileURL {
                enlargedShotViewer(enlargedShotFileURL)
                    .transition(.opacity)
            }
        }
        .background(DS.Colors.background)
        .animation(.easeOut(duration: DS.Animation.normal), value: enlargedShotFileURL)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sessionDetail.window")
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(state.title)
                    .font(DS.WindowText.windowTitle)
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityIdentifier("sessionDetail.title")
                Text(headerMetaLine)
                    .font(DS.WindowText.metaNumbers)
                    .foregroundColor(DS.Colors.textMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)

            if state.savedNotePath != nil {
                Button(action: onSave) {
                    Text("Save again")
                }
                .clickyWindowButton(.secondary, isCompact: true)
                .accessibilityIdentifier("sessionDetail.save")
            } else {
                Button(action: onSave) {
                    HStack(spacing: 6) {
                        Image(systemName: "tray.and.arrow.down")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Save to vault")
                    }
                }
                .clickyWindowButton(.primary)
                .accessibilityIdentifier("sessionDetail.save")
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    /// Where the note went, with the one action that matters after a save.
    private func savedStrip(_ savedNotePath: String) -> some View {
        HStack(spacing: 10) {
            WindowStatusChip(text: "Saved", tint: DS.Colors.success, systemImageName: "checkmark")
                .accessibilityIdentifier("sessionDetail.savedChip")
            Text((savedNotePath as NSString).abbreviatingWithTildeInPath)
                .font(DS.WindowText.meta)
                .foregroundColor(DS.Colors.textMuted)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityIdentifier("sessionDetail.savedNotePath")
            Spacer(minLength: 8)
            Button(action: onRevealInFinder) {
                HStack(spacing: 5) {
                    Image(systemName: "folder")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Show in Finder")
                }
            }
            .clickyWindowButton(.quiet, isCompact: true)
            .accessibilityIdentifier("sessionDetail.revealInFinder")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .background(DS.Colors.surface1)
    }

    private var headerMetaLine: String {
        let questionCount = state.rows.filter { $0.kind == .question }.count
        let shotCount = state.rows.filter { $0.shotFileURL != nil }.count
        var metaParts = [WindowTimeFormatting.dayAndTime(state.startedAt)]
        metaParts.append(questionCount == 1 ? "1 question" : "\(questionCount) questions")
        if shotCount > 0 {
            metaParts.append(shotCount == 1 ? "1 screen" : "\(shotCount) screens")
        }
        return metaParts.joined(separator: "  ·  ")
    }

    // MARK: - Summary

    private func summaryBlock(_ summary: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Summary")
                .font(DS.WindowText.sectionTitle)
                .foregroundColor(DS.Colors.textPrimary)
            Text(summary)
                .font(.system(size: 13.5))
                .lineSpacing(4.5)
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityIdentifier("sessionDetail.summary")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.WindowRadius.card, style: .continuous)
                .fill(DS.Colors.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.WindowRadius.card, style: .continuous)
                .strokeBorder(DS.Colors.borderSubtle.opacity(0.7), lineWidth: 1)
        )
    }

    // MARK: - Timeline

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(state.rows.enumerated()), id: \.element.id) { rowPosition, timelineRow in
                timelineRowView(timelineRow, isLastRow: rowPosition == state.rows.count - 1)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("sessionDetail.row.\(rowPosition)")
            }
        }
    }

    private func timelineRowView(_ timelineRow: SessionTimelineRow, isLastRow: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(WindowTimeFormatting.clockTime(timelineRow.time))
                .font(DS.WindowText.metaNumbers)
                .foregroundColor(DS.Colors.textMuted)
                .frame(width: 54, alignment: .trailing)
                .padding(.top, 3)

            // The rail: one icon per row, joined by a faint line so the rows read as one timeline.
            VStack(spacing: 0) {
                kindIcon(timelineRow.kind)
                if !isLastRow {
                    Rectangle()
                        .fill(DS.Colors.borderSubtle.opacity(0.6))
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 22)

            VStack(alignment: .leading, spacing: 6) {
                rowText(timelineRow)
                if let detail = timelineRow.detail {
                    Text(detail)
                        .font(DS.WindowText.metaNumbers)
                        .foregroundColor(DS.Colors.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let shotFileURL = timelineRow.shotFileURL {
                    shotThumbnail(shotFileURL)
                        .padding(.top, 2)
                }
            }
            .padding(.top, 2)
            .padding(.bottom, isLastRow ? 0 : 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func rowText(_ timelineRow: SessionTimelineRow) -> some View {
        switch timelineRow.kind {
        case .question:
            Text(timelineRow.text)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case .answer:
            Text(timelineRow.text)
                .font(DS.WindowText.body)
                .lineSpacing(DS.WindowText.bodyLineSpacing)
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case .speech:
            Text("\u{201C}\(timelineRow.text)\u{201D}")
                .font(DS.WindowText.body)
                .lineSpacing(DS.WindowText.bodyLineSpacing)
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case .focus, .notice:
            Text(timelineRow.text)
                .font(DS.WindowText.meta)
                .foregroundColor(DS.Colors.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func kindIcon(_ kind: SessionTimelineRowKind) -> some View {
        let iconStyle = timelineIconStyle(kind)
        return Image(systemName: iconStyle.systemImageName)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(iconStyle.tint)
            .frame(width: 22, height: 22)
            .background(Circle().fill(iconStyle.tint.opacity(0.13)))
            .accessibilityHidden(true)
    }

    private func timelineIconStyle(_ kind: SessionTimelineRowKind) -> (systemImageName: String, tint: Color) {
        switch kind {
        case .focus: return ("macwindow", DS.Colors.textMuted)
        case .speech: return ("waveform", DS.Colors.listeningWave)
        case .question: return ("questionmark", DS.Colors.accentText)
        case .answer: return ("text.bubble", DS.Colors.textSecondary)
        case .notice: return ("info", DS.Colors.warning)
        }
    }

    // MARK: - Screenshots

    private func shotThumbnail(_ shotFileURL: URL) -> some View {
        Button(action: { enlargedShotFileURL = shotFileURL }) {
            ShotImage(shotFileURL: shotFileURL)
                .frame(width: 168, height: 105)
                .clipShape(RoundedRectangle(cornerRadius: DS.WindowRadius.thumbnail, style: .continuous))
        }
        .buttonStyle(ShotThumbnailButtonStyle())
        .accessibilityLabel("Screenshot, opens larger")
        .accessibilityIdentifier("sessionDetail.shot.\(shotFileURL.lastPathComponent)")
    }

    private func enlargedShotViewer(_ shotFileURL: URL) -> some View {
        ZStack(alignment: .topTrailing) {
            Color.black.opacity(0.86)
                .contentShape(Rectangle())
                .onTapGesture { enlargedShotFileURL = nil }

            ShotImage(shotFileURL: shotFileURL)
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: DS.WindowRadius.card, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.WindowRadius.card, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.5), radius: 24, x: 0, y: 10)
                .padding(.horizontal, 28)
                .padding(.top, 56)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("sessionDetail.shotViewer")

            Button(action: { enlargedShotFileURL = nil }) {
                HStack(spacing: 5) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                    Text("Close")
                }
            }
            .clickyWindowButton(.secondary, isCompact: true)
            .keyboardShortcut(.cancelAction)
            .padding(16)
            .accessibilityIdentifier("sessionDetail.closeShot")
        }
    }
}

/// Reads a screenshot from disk once and keeps it, so scrolling the timeline
/// does not decode the same file again.
private struct ShotImage: View {
    let shotFileURL: URL

    private static let decodedShots = NSCache<NSURL, NSImage>()

    var body: some View {
        if let shotImage = Self.loadShot(shotFileURL) {
            Image(nsImage: shotImage)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                DS.Colors.surface2
                Image(systemName: "photo")
                    .font(.system(size: 16))
                    .foregroundColor(DS.Colors.textTertiary)
            }
        }
    }

    private static func loadShot(_ shotFileURL: URL) -> NSImage? {
        if let cachedShot = decodedShots.object(forKey: shotFileURL as NSURL) { return cachedShot }
        guard let loadedShot = NSImage(contentsOf: shotFileURL) else { return nil }
        decodedShots.setObject(loadedShot, forKey: shotFileURL as NSURL)
        return loadedShot
    }
}

/// Thumbnail hover: a light outline and a small lift say "click to open".
private struct ShotThumbnailButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ShotThumbnailButtonBody(configuration: configuration)
    }
}

private struct ShotThumbnailButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .overlay(
                RoundedRectangle(cornerRadius: DS.WindowRadius.thumbnail, style: .continuous)
                    .strokeBorder(isHovered ? DS.Colors.accentText.opacity(0.8) : Color.white.opacity(0.10), lineWidth: isHovered ? 1.5 : 1)
            )
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(DS.Colors.textPrimary)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.black.opacity(0.6)))
                    .padding(6)
                    .opacity(isHovered ? 1 : 0)
            }
            .shadow(color: Color.black.opacity(isHovered ? 0.35 : 0), radius: 6, x: 0, y: 3)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .onHover { isHoveringNow in isHovered = isHoveringNow }
            .pointerCursor()
    }
}
