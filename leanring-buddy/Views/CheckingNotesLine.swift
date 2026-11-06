//
//  CheckingNotesLine.swift
//  leanring-buddy
//
//  "Checking your notes": the one line that says Clicky is searching the user's folders for this answer.
//  It sits at the end of the answer bubble and of the chat's latest card. Its only motion is a soft light
//  passing across the words, left to right, so it reads as alive without a spinner pulling the eye off the
//  work. With Reduce Motion on, the words stay still.
//

import SwiftUI

struct CheckingNotesLine: View {
    enum Placement {
        /// Beside the cursor, on the bubble's own dark ground: 13 pt, like the bubble's text.
        case cursorBubble
        /// In the chat window's latest card: the chat's supporting text size.
        case chatCard
    }

    let placement: Placement
    /// Only for the preview renderer: freezes the passing light at this point of its sweep (0...1), so a PNG
    /// always shows it in the same place. The app leaves it nil and the light moves.
    var fixedSweepPhase: Double? = nil

    @Environment(\.accessibilityReduceMotion) private var isReduceMotionOn

    static let text = "Checking your notes"
    /// One pass of the light, then a short rest before the next one.
    private static let sweepSeconds: Double = 1.5
    private static let restSeconds: Double = 0.5

    var body: some View {
        Group {
            if let fixedSweepPhase {
                sweptLine(phase: fixedSweepPhase)
            } else if isReduceMotionOn {
                restingLine
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                    sweptLine(phase: Self.sweepPhase(at: timeline.date))
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.text)
        .accessibilityIdentifier(placement == .cursorBubble ? "cursor.checkingNotes" : "chat.checkingNotes")
    }

    /// Where the light is in its sweep: 0...1 while it passes, above 1 while it rests off the right end.
    private static func sweepPhase(at date: Date) -> Double {
        let cycleSeconds = sweepSeconds + restSeconds
        let secondsIntoCycle = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycleSeconds)
        return secondsIntoCycle / sweepSeconds
    }

    private var restingLine: some View {
        lineContent.foregroundColor(baseColor)
    }

    /// The words in the resting colour, with a brighter copy shown only through a narrow moving band.
    private func sweptLine(phase: Double) -> some View {
        lineContent
            .foregroundColor(baseColor)
            .overlay(
                lineContent
                    .foregroundColor(highlightColor)
                    .mask(
                        GeometryReader { lineGeometry in
                            let bandWidth = max(lineGeometry.size.width * 0.45, 40)
                            // The band starts fully off the left end and finishes fully off the right end.
                            let bandCenterX = -bandWidth / 2 + (lineGeometry.size.width + bandWidth) * phase
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0),
                                    .init(color: .black, location: 0.5),
                                    .init(color: .clear, location: 1),
                                ],
                                startPoint: .leading, endPoint: .trailing)
                                .frame(width: bandWidth)
                                .offset(x: bandCenterX - bandWidth / 2)
                        }
                    )
            )
    }

    private var lineContent: some View {
        HStack(spacing: 6) {
            Image(systemName: "text.magnifyingglass")
                .font(.system(size: iconSize, weight: .medium))
            Text(Self.text)
                .font(.system(size: textSize, weight: .medium))
                .lineLimit(1)
                .fixedSize()
        }
    }

    private var textSize: CGFloat { placement == .cursorBubble ? 13 : 12.5 }
    private var iconSize: CGFloat { placement == .cursorBubble ? 11.5 : 11 }

    /// `textMuted` passes 4.5:1 on both grounds, so the line is readable even where the light is not.
    private var baseColor: Color { DS.Colors.textMuted }
    private var highlightColor: Color { DS.Colors.textPrimary }
}
