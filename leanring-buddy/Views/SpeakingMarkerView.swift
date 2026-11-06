//
//  SpeakingMarkerView.swift
//  leanring-buddy
//
//  The speaker capsule beside the cursor while an answer is read aloud and no text is shown:
//  a speaker and five soft white bars that move gently. The bars do not follow real audio levels.
//

import SwiftUI

struct SpeakingMarkerView: View {
    /// The bars' resting heights, from mockup 07.
    private static let restingBarHeights: [CGFloat] = [5, 10, 7, 11, 4]

    /// Draws the bars at a fixed moment in their movement. Previews pass a time; the app uses the clock.
    var fixedTime: TimeInterval? = nil

    var body: some View {
        MarkerCapsule {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
            if let fixedTime {
                bars(at: fixedTime)
            } else {
                TimelineView(.animation) { timeline in
                    bars(at: timeline.date.timeIntervalSinceReferenceDate)
                }
            }
        }
        .accessibilityLabel("Reading the answer aloud")
        .accessibilityIdentifier("cursor.speaking")
    }

    private func bars(at time: TimeInterval) -> some View {
        HStack(spacing: 2) {
            ForEach(0..<Self.restingBarHeights.count, id: \.self) { barIndex in
                let swing = 0.78 + 0.22 * sin(time * 5.0 + Double(barIndex) * 1.3)
                RoundedRectangle(cornerRadius: 1.25)
                    .fill(DS.Colors.textPrimary.opacity(0.78))
                    .frame(width: 2.5, height: min(12, Self.restingBarHeights[barIndex] * CGFloat(swing)))
            }
        }
        .frame(height: 12)
    }
}

/// The capsule pinned to the top-left of its panel, so it sits where the question marker sat.
struct SpeakingMarkerPanelContent: View {
    let size: CGSize

    var body: some View {
        SpeakingMarkerView()
            .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}
