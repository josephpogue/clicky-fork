//
//  QuestionMarkerView.swift
//  leanring-buddy
//
//  The small marker that sits beside the cursor while a question is in
//  flight. It is drawn small and meant to be placed down and to the right of
//  the pointer tip (see `suggestedOffsetFromCursor`), so it never covers what
//  the user is pointing at. It carries its own dark ground and light outline
//  so it reads on a white page and on a dark editor alike.
//
//  Listening: live level bars that follow the microphone.
//  Transcribing: three dots.
//  Waiting: a turning arc and the provider's name.
//  Idle: nothing.
//

import SwiftUI

struct QuestionMarkerView: View {
    let phase: QuestionPhase

    /// Where the overlay should put the marker's top-left corner relative to
    /// the cursor's hot spot: clear of the arrow, which reaches about 12 x 19
    /// points down and to the right of the tip.
    static let suggestedOffsetFromCursor = CGSize(width: 18, height: 20)

    /// The marker's height, the same in every phase so it does not jump.
    static let markerHeight: CGFloat = 24

    var body: some View {
        switch phase {
        case .idle:
            EmptyView()
        case .listening(let audioLevel):
            markerCapsule {
                Image(systemName: "mic.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                ListeningLevelBars(audioLevel: audioLevel, maximumBarHeight: 12, barWidth: 2.5)
            }
            .accessibilityLabel("Listening")
            .accessibilityIdentifier("marker.listening")
        case .transcribing:
            markerCapsule {
                Image(systemName: "waveform")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                HStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { dotIndex in
                        Circle()
                            .fill(DS.Colors.textPrimary.opacity(0.45 + Double(dotIndex) * 0.2))
                            .frame(width: 4, height: 4)
                    }
                }
            }
            .accessibilityLabel("Transcribing your question")
            .accessibilityIdentifier("marker.transcribing")
        case .waitingForAnswer(let providerName):
            markerCapsule {
                WindowSpinner(diameter: 10, tint: DS.Colors.listeningWave, lineWidth: 1.6)
                Text(providerName)
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
            }
            .accessibilityLabel("Waiting for \(providerName)")
            .accessibilityIdentifier("marker.waiting")
        }
    }

    private func markerCapsule<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 6) {
            content()
        }
        .padding(.horizontal, 9)
        .frame(height: Self.markerHeight)
        .background(
            Capsule()
                .fill(DS.Colors.markerGround)
                .shadow(color: Color.black.opacity(0.35), radius: 5, x: 0, y: 2)
        )
        .overlay(PillOutline(height: Self.markerHeight, color: DS.Colors.markerOutline))
        .fixedSize()
        .accessibilityElement(children: .ignore)
    }
}
