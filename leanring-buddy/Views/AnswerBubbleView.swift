//
//  AnswerBubbleView.swift
//  leanring-buddy
//
//  The answer (or notice) text beside the cursor: a dark rounded bubble with no tail. The corner nearest
//  the cursor is tight (5 pt), the others 14 pt. A long answer is cut at a fixed height with its bottom
//  fading out, and a footer says the rest is in Open chat. Nothing in it scrolls or takes a click.
//
//  While an answer is still coming the bubble grows with it. Past the cap it shows the newest lines instead,
//  with the top fading in so it reads as continued, and the footer says the start is in Open chat. A
//  "Checking your notes" line can sit at the end, or show alone in a small bubble before any text comes.
//

import AppKit
import ClickyCore
import SwiftUI

/// Everything the bubble needs, measured once so the panel and the view agree on the size.
///
/// For an answer still coming, build a new content on each text report with `showsNewestLines: true`, so a
/// text past the cap shows its last lines. `showsCheckingLine` adds "Checking your notes" at the end; with an
/// empty `text` it is the whole bubble. A finished answer uses today's `init(text:isNotice:)`.
struct AnswerBubbleContent: Equatable {
    let fullText: String
    let paragraphs: [String]
    let isNotice: Bool
    let showsCheckingLine: Bool
    let layout: CursorBubbleLayout.TextLayout

    @MainActor
    init(text: String, isNotice: Bool, showsNewestLines: Bool = false, showsCheckingLine: Bool = false) {
        fullText = text
        paragraphs = AnswerBubbleMetrics.paragraphs(of: text)
        self.isNotice = isNotice
        self.showsCheckingLine = showsCheckingLine
        layout = AnswerBubbleMetrics.textLayout(
            forParagraphs: paragraphs, showsNewestLines: showsNewestLines, showsCheckingLine: showsCheckingLine)
    }

    var size: CGSize {
        CGSize(width: layout.width, height: AnswerBubbleView.totalHeight(forContentHeight: layout.contentHeight, showsFooter: layout.isBodyCut))
    }
}

/// Measures the text the way the bubble draws it, so the short/long choice and the cut use real line counts.
enum AnswerBubbleMetrics {
    static let font = NSFont.systemFont(ofSize: 13.5)
    static let lineHeight: CGFloat = 13.5 * 1.45
    static let paragraphSpacing: CGFloat = 7
    static let horizontalPadding: CGFloat = 13

    /// SwiftUI adds this between lines so each line takes `lineHeight`.
    static var extraLineSpacing: CGFloat {
        lineHeight - NSLayoutManager().defaultLineHeight(for: font)
    }

    static func paragraphs(of text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The measuring width is this much narrower than the width SwiftUI draws at, so a line that only just
    /// fits is counted as wrapped. At worst that leaves a blank line of room; it can never clip a line.
    static let measuringSlack: CGFloat = 1.5

    static func lineCount(of paragraph: String, textWidth: CGFloat) -> Int {
        let textStorage = NSTextStorage(string: paragraph, attributes: [.font: font])
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: CGSize(width: textWidth - measuringSlack, height: .greatestFiniteMagnitude))
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: textContainer)
        var lines = 0
        var glyphIndex = 0
        let glyphCount = layoutManager.numberOfGlyphs
        while glyphIndex < glyphCount {
            var lineGlyphRange = NSRange()
            layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &lineGlyphRange)
            lines += 1
            glyphIndex = NSMaxRange(lineGlyphRange)
        }
        return max(lines, 1)
    }

    /// The body's height as SwiftUI itself lays it out at `textWidth`: the bubble, its dark ground and its
    /// panel are all sized from this, so a line SwiftUI wraps differently from `lineCount(of:textWidth:)`
    /// can never hang outside the ground or be clipped.
    @MainActor
    static func bodyHeight(ofParagraphs paragraphs: [String], textWidth: CGFloat) -> CGFloat {
        let measuringView = NSHostingView(
            rootView: AnswerBubbleParagraphs(paragraphs: paragraphs).frame(width: textWidth, alignment: .topLeading))
        return measuringView.fittingSize.height
    }

    @MainActor
    static func textLayout(
        forParagraphs paragraphs: [String],
        showsNewestLines: Bool = false,
        showsCheckingLine: Bool = false
    ) -> CursorBubbleLayout.TextLayout {
        let shortTextWidth = CursorBubbleLayout.shortWidth - 2 * horizontalPadding
        let longTextWidth = CursorBubbleLayout.longWidth - 2 * horizontalPadding
        let shortLineCounts = paragraphs.map { lineCount(of: $0, textWidth: shortTextWidth) }
        let longLineCounts = paragraphs.map { lineCount(of: $0, textWidth: longTextWidth) }
        return CursorBubbleLayout.textLayout(
            lineCountAtShortWidth: shortLineCounts.reduce(0, +),
            naturalBodyHeightAtShortWidth: bodyHeight(ofParagraphs: paragraphs, textWidth: shortTextWidth),
            naturalBodyHeightAtLongWidth: bodyHeight(ofParagraphs: paragraphs, textWidth: longTextWidth),
            showsNewestLines: showsNewestLines,
            showsCheckingLine: showsCheckingLine)
    }
}

/// The answer's paragraphs, drawn once for the bubble and measured once for its size.
struct AnswerBubbleParagraphs: View {
    let paragraphs: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: AnswerBubbleMetrics.paragraphSpacing) {
            ForEach(0..<paragraphs.count, id: \.self) { paragraphIndex in
                Text(paragraphs[paragraphIndex])
                    .font(.system(size: 13.5))
                    .lineSpacing(AnswerBubbleMetrics.extraLineSpacing)
                    .foregroundColor(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct AnswerBubbleView: View {
    let content: AnswerBubbleContent
    let nearCorner: CursorBubbleLayout.NearCorner

    /// Room around the bubble inside its panel for the shadow.
    static let shadowMargin: CGFloat = 24

    private static let topPadding: CGFloat = 10
    private static let bottomPadding: CGFloat = 11
    private static let footerHeight: CGFloat = 16
    /// 6 pt above the hairline, 1 pt hairline, 8 pt below it.
    private static let footerExtra: CGFloat = 6 + 1 + 8

    /// `contentHeight` is the body plus the checking line (`TextLayout.contentHeight`).
    static func totalHeight(forContentHeight contentHeight: CGFloat, showsFooter: Bool) -> CGFloat {
        topPadding + contentHeight + bottomPadding + (showsFooter ? footerExtra + footerHeight : 0)
    }

    /// Preview renderer only: freezes the checking line's passing light (see `CheckingNotesLine`).
    var fixedCheckingSweepPhase: Double? = nil

    private var isCutAtTop: Bool { content.layout.cutEdge == .top }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !content.paragraphs.isEmpty {
                bodyText
            }
            if content.showsCheckingLine {
                CheckingNotesLine(placement: .cursorBubble, fixedSweepPhase: fixedCheckingSweepPhase)
                    .frame(height: CursorBubbleLayout.checkingLineHeight, alignment: .leading)
                    .padding(.top, content.paragraphs.isEmpty ? 0 : CursorBubbleLayout.checkingLineGap)
            }
            if content.layout.isBodyCut {
                footer
            }
        }
        .padding(.horizontal, AnswerBubbleMetrics.horizontalPadding)
        .padding(.top, Self.topPadding)
        .padding(.bottom, Self.bottomPadding)
        .frame(width: content.size.width, height: content.size.height, alignment: .topLeading)
        .background(
            bubbleShape
                .fill(Color(hex: "#101211").opacity(0.985))
                .shadow(color: Color.black.opacity(0.26), radius: 9, x: 0, y: 6)
                .shadow(color: Color.black.opacity(0.22), radius: 1.5, x: 0, y: 1)
        )
        .overlay(bubbleShape.strokeBorder(DS.Colors.markerOutline, lineWidth: 1))
        .padding(Self.shadowMargin)
    }

    private var bubbleShape: UnevenRoundedRectangle {
        let tight: CGFloat = 5
        let round: CGFloat = 14
        return UnevenRoundedRectangle(
            topLeadingRadius: nearCorner == .topLeading ? tight : round,
            bottomLeadingRadius: nearCorner == .bottomLeading ? tight : round,
            bottomTrailingRadius: nearCorner == .bottomTrailing ? tight : round,
            topTrailingRadius: nearCorner == .topTrailing ? tight : round,
            style: .continuous)
    }

    private var bodyText: some View {
        let bodyHeight = content.layout.bodyHeight
        return AnswerBubbleParagraphs(paragraphs: content.paragraphs)
        .frame(
            width: content.layout.width - 2 * AnswerBubbleMetrics.horizontalPadding,
            height: content.layout.isBodyCut ? bodyHeight : nil,
            // Cut at the top, the text's bottom sits on the frame's bottom, so the newest line is always the
            // last one showing, even when SwiftUI wraps a line differently from the measurement.
            alignment: isCutAtTop ? .bottomLeading : .topLeading)
        // Only a cut body is held to a height; an uncut one sizes itself, so a line SwiftUI wraps differently
        // from the measurement is never clipped.
        .clipped()
        .mask(fadeMask(bodyHeight: bodyHeight))
        // One element for the test Mac driver: the whole answer is its value, even where the bubble cuts it.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(content.isNotice ? "Notice" : "Answer")
        .accessibilityValue(content.fullText)
        .accessibilityIdentifier(content.isNotice ? "cursor.notice" : "cursor.answer")
    }

    /// Opaque except the cut end: the bottom 22 pt of a finished answer fade to 25%, and the top 30 pt of a
    /// growing answer fade in from almost nothing, so its first visible line reads as the middle of something
    /// even when the cut falls exactly between two lines.
    @ViewBuilder
    private func fadeMask(bodyHeight: CGFloat) -> some View {
        let fadeLength = min(30 / max(bodyHeight, 1), 1)
        if isCutAtTop {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.08), location: 0),
                    .init(color: .black, location: fadeLength),
                    .init(color: .black, location: 1),
                ],
                startPoint: .top, endPoint: .bottom)
        } else {
            bottomFadeMask(bodyHeight: bodyHeight)
        }
    }

    private func bottomFadeMask(bodyHeight: CGFloat) -> some View {
        let fadeStart = content.layout.isBodyCut ? max(0, (bodyHeight - 22) / bodyHeight) : 1
        return LinearGradient(
            stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: fadeStart),
                .init(color: .black.opacity(content.layout.isBodyCut ? 0.25 : 1), location: 1),
            ],
            startPoint: .top, endPoint: .bottom)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
                .padding(.top, 6)
            HStack(spacing: 6) {
                Image(systemName: "bubble.left.fill")
                    .font(.system(size: 11))
                Text(footerText)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundColor(DS.Colors.textMuted)
            .frame(height: Self.footerHeight)
            .padding(.top, 8)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(footerText)
            .accessibilityIdentifier("cursor.answer.more")
        }
    }

    /// A finished answer hides its end; a growing one past the cap hides its start.
    private var footerText: String {
        isCutAtTop ? "The start is in Open chat, in the menu bar" : "The rest is in Open chat, in the menu bar"
    }
}
