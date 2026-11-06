//
//  SpokenAnswerPlayer.swift
//  leanring-buddy
//
//  Reads an answer aloud with a voice built into macOS, the one picked in
//  Settings. No paid or network voice service.
//
//  SessionCoordinator calls it; the spoken-answers slice fills in the bodies.
//

import AVFoundation

@MainActor
final class SpokenAnswerPlayer {
    /// Called with true when reading starts and false when it ends, is stopped or fails.
    var onSpeakingChanged: ((Bool) -> Void)?

    /// Reads `text` aloud, stopping anything still being read first.
    func speak(text: String) {}

    /// Stops reading at once: a new question, Start, Stop and Quit.
    func stopSpeaking() {}
}
