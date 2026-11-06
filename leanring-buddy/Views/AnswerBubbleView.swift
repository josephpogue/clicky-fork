//
//  AnswerBubbleView.swift
//  leanring-buddy
//
//  The answer (or notice) text beside the cursor: a dark rounded bubble with no tail. The corner nearest
//  the cursor is tight (5 pt), the others 14 pt. A long answer is cut at a fixed height with its bottom
//  fading out, and a footer says the rest is in Open chat. Nothing in it scrolls or takes a click.
//

import AppKit
import ClickyCore
import SwiftUI

/// Everything the bubble needs, measured once so the panel and the view agree on the size.
struct AnswerBubbleContent: Equatable {
    let fullText: String
    let paragraphs: [String]
    let isNotice: Bool
    let layout: CursorBubbleLayout.TextLayout

    init(text: String, isNotice: Bool) {
        fullText = text
        paragraphs = AnswerBubbleMetrics.paragraphs(of: text)
        self.isNotice = isNotice
        layout = AnswerBubbleMetrics.textLayout(forParagraphs: paragraphs)
    }

    var size: CGSize {
        CGSize(width: layout.width, height: AnswerBubbleView.totalHeight(forBodyHeight: layout.bodyHeight, showsFooter: layout.isBodyCut))
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

    static func lineCount(of paragraph: String, textWidth: CGFloat) -> Int {
        let textStorage = NSTextStorage(string: paragraph, attributes: [.font: font])
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: CGSize(width: textWidth, height: .greatestFiniteMagnitude))
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

    /// The body's height as SwiftUI draws it: lines of the font's own height, `extraLineSpacing` between them,
    /// and 7 pt between paragraphs.
    static func bodyHeight(lineCounts: [Int]) -> CGFloat {
        let naturalLineHeight = lineHeight - extraLineSpacing
        var height: CGFloat = 0
        for lineCount in lineCounts {
            height += CGFloat(lineCount) * naturalLineHeight + CGFloat(lineCount - 1) * extraLineSpacing
        }
        return height + CGFloat(max(lineCounts.count - 1, 0)) * paragraphSpacing
    }

    static func textLayout(forParagraphs paragraphs: [String]) -> CursorBubbleLayout.TextLayout {
        let shortTextWidth = CursorBubbleLayout.shortWidth - 2 * horizontalPadding
        let longTextWidth = CursorBubbleLayout.longWidth - 2 * horizontalPadding
        let shortLineCounts = paragraphs.map { lineCount(of: $0, textWidth: shortTextWidth) }
        let longLineCounts = paragraphs.map { lineCount(of: $0, textWidth: longTextWidth) }
        return CursorBubbleLayout.textLayout(
            lineCountAtShortWidth: shortLineCounts.reduce(0, +),
            naturalBodyHeightAtShortWidth: bodyHeight(lineCounts: shortLineCounts),
            naturalBodyHeightAtLongWidth: bodyHeight(lineCounts: longLineCounts))
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

    static func totalHeight(forBodyHeight bodyHeight: CGFloat, showsFooter: Bool) -> CGFloat {
        topPadding + bodyHeight + bottomPadding + (showsFooter ? footerExtra + footerHeight : 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            bodyText
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
        return VStack(alignment: .leading, spacing: AnswerBubbleMetrics.paragraphSpacing) {
            ForEach(0..<content.paragraphs.count, id: \.self) { paragraphIndex in
                Text(content.paragraphs[paragraphIndex])
                    .font(.system(size: 13.5))
                    .lineSpacing(AnswerBubbleMetrics.extraLineSpacing)
                    .foregroundColor(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(
            width: content.layout.width - 2 * AnswerBubbleMetrics.horizontalPadding,
            height: bodyHeight,
            alignment: .topLeading)
        .clipped()
        .mask(fadeMask(bodyHeight: bodyHeight))
        // One element for the test Mac driver: the whole answer is its value, even where the bubble cuts it.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(content.isNotice ? "Notice" : "Answer")
        .accessibilityValue(content.fullText)
        .accessibilityIdentifier(content.isNotice ? "cursor.notice" : "cursor.answer")
    }

    /// Opaque except the bottom 22 pt of a cut body, which fades to 25%.
    private func fadeMask(bodyHeight: CGFloat) -> some View {
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
                Text("The rest is in Open chat, in the menu bar")
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundColor(DS.Colors.textMuted)
            .frame(height: Self.footerHeight)
            .padding(.top, 8)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("The rest is in Open chat, in the menu bar")
            .accessibilityIdentifier("cursor.answer.more")
        }
    }
}
