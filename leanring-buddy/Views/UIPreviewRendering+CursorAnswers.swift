//
//  UIPreviewRendering+CursorAnswers.swift
//  leanring-buddy
//
//  Preview PNGs for the answer bubble, notices and speaker capsule beside the cursor (cursor-text slice).
//  Each is drawn over a light page tile next to a real arrow cursor, placed by the same
//  `CursorBubbleLayout` the app uses, so the flips can be checked here.
//

import AppKit
import ClickyCore
import SwiftUI

extension UIPreviewRendering {
    @MainActor
    static func renderCursorAnswerPreviews(into directory: URL) throws {
        let tileSize = CGSize(width: 480, height: 330)
        let topLeftCursor = CGPoint(x: 34, y: 304)
        let shortAnswer = "Click the Save button at the top right."
        let twoSentenceAnswer = "It's the open-source code behind HeyClicky, an AI helper that sits beside your cursor on a Mac. The app itself is in the leanring-buddy folder."
        let longAnswer = """
        This is the original Clicky, the open-source project the HeyClicky app grew out of. It's a Mac menu-bar app that hears a spoken question, looks at your screen and answers.
        leanring-buddy holds the Swift app itself. The odd spelling is an old typo the project kept.
        worker is a small Cloudflare Worker. It holds the API keys, so they never ship inside the app.
        scripts has the build and release helpers, and the two test folders hold the unit and UI tests that run in Xcode.
        """
        let bubblePreviews: [(fileName: String, text: String, isNotice: Bool, cursor: CGPoint)] = [
            ("cursor-answer-short.png", shortAnswer, false, topLeftCursor),
            ("cursor-answer-two-sentences.png", twoSentenceAnswer, false, topLeftCursor),
            ("cursor-answer-long-cut.png", longAnswer, false, topLeftCursor),
            ("cursor-answer-flipped-left.png", twoSentenceAnswer, false, CGPoint(x: 440, y: 304)),
            ("cursor-answer-flipped-up.png", twoSentenceAnswer, false, CGPoint(x: 34, y: 50)),
            ("cursor-answer-flipped-both.png", twoSentenceAnswer, false, CGPoint(x: 440, y: 50)),
            ("cursor-notice.png", "The usage limit for Claude is used up. Switch to ChatGPT to keep going.", true, topLeftCursor),
        ]
        for preview in bubblePreviews {
            try render(
                CursorAnswerTile(tileSize: tileSize, cursor: preview.cursor, content: .bubble(AnswerBubbleContent(text: preview.text, isNotice: preview.isNotice))),
                size: tileSize, fileName: preview.fileName, into: directory)
        }
        try render(
            CursorAnswerTile(tileSize: tileSize, cursor: topLeftCursor, content: .speaking),
            size: tileSize, fileName: "cursor-speaking.png", into: directory)

        try renderGrowingAnswerPreviews(into: directory, tileSize: tileSize, cursor: topLeftCursor)
    }

    /// The bubble while an answer is still coming (brain-context designer slice): growing text, the
    /// "Checking your notes" line alone and under text, and a text past the cap showing its newest lines.
    @MainActor
    private static func renderGrowingAnswerPreviews(into directory: URL, tileSize: CGSize, cursor: CGPoint) throws {
        let firstWords = "The demo server runs on port 4100."
        let pastTheCap = """
        The demo server runs on port 4100. Your notes say it starts from the demo-server folder with npm run dev, and the setup page lists three things it needs first.
        It reads its settings from a file named demo.env in that folder. The checklist says to copy demo.env.example to demo.env before the first start.
        Your deploy note adds that the port is fixed on purpose, because the browser extension posts to it. If 4100 is busy, the server stops instead of picking another port.
        The last step in the checklist is to open the status page and confirm the green line reads Ready, then run the smoke test from the same folder.
        """
        let growingPreviews: [(fileName: String, text: String, showsCheckingLine: Bool)] = [
            ("cursor-growing-short.png", firstWords, false),
            ("cursor-growing-checking-alone.png", "", true),
            ("cursor-growing-with-checking.png", firstWords + " Checking where it reads its settings from.", true),
            ("cursor-growing-past-cap.png", pastTheCap, false),
            ("cursor-growing-past-cap-checking.png", pastTheCap, true),
        ]
        for preview in growingPreviews {
            let content = AnswerBubbleContent(
                text: preview.text, isNotice: false, showsNewestLines: true, showsCheckingLine: preview.showsCheckingLine)
            try render(
                CursorAnswerTile(tileSize: tileSize, cursor: cursor, content: .bubble(content)),
                size: tileSize, fileName: preview.fileName, into: directory)
        }
    }
}

/// A made-up page with the arrow cursor and whatever the app shows beside it.
private struct CursorAnswerTile: View {
    enum Content {
        case bubble(AnswerBubbleContent)
        case speaking
    }

    let tileSize: CGSize
    /// The cursor tip in AppKit coordinates inside the tile (origin bottom-left).
    let cursor: CGPoint
    let content: Content

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(hex: "#F5F5F3")
            VStack(alignment: .leading, spacing: 9) {
                ForEach(0..<14, id: \.self) { lineIndex in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.black.opacity(0.12))
                        .frame(width: [300, 240, 330, 180, 280, 310, 220][lineIndex % 7], height: 6)
                }
            }
            .padding(.leading, 24)
            .padding(.top, 24)

            let hotSpot = NSCursor.arrow.hotSpot
            Image(nsImage: NSCursor.arrow.image)
                .offset(x: cursor.x - hotSpot.x, y: tileSize.height - cursor.y - hotSpot.y)
            beside
        }
        .frame(width: tileSize.width, height: tileSize.height, alignment: .topLeading)
        .clipped()
    }

    @ViewBuilder private var beside: some View {
        let visibleFrame = CGRect(origin: .zero, size: tileSize)
        switch content {
        case .bubble(let bubbleContent):
            let placement = CursorBubbleLayout.placement(
                anchor: .cursor(at: cursor), bubbleSize: bubbleContent.size, visibleFrame: visibleFrame)
            // The checking line's light is frozen mid-sweep so every render shows it the same way.
            AnswerBubbleView(content: bubbleContent, nearCorner: placement.nearCorner, fixedCheckingSweepPhase: 0.55)
                .offset(
                    x: placement.origin.x - AnswerBubbleView.shadowMargin,
                    y: tileSize.height - placement.origin.y - bubbleContent.size.height - AnswerBubbleView.shadowMargin)
        case .speaking:
            let capsuleSize = CGSize(width: 78, height: QuestionMarkerView.markerHeight + 8)
            let placement = CursorBubbleLayout.placement(anchor: .cursor(at: cursor), bubbleSize: capsuleSize, visibleFrame: visibleFrame)
            SpeakingMarkerPanelContent(size: capsuleSize)
                .offset(x: placement.origin.x, y: tileSize.height - placement.origin.y - capsuleSize.height)
        }
    }
}
