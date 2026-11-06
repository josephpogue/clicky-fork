//
//  CursorAnswerPresenter.swift
//  leanring-buddy
//
//  Everything a session shows beside the cursor after a question: the answer
//  bubble, notices (a failed start, a provider error, the usage limit) and the
//  small speaker capsule while an answer is read aloud. It never opens a window
//  that takes clicks, keys or scroll from the user's app.
//
//  SessionCoordinator calls it; the cursor-text slice fills in the bodies.
//

import AppKit

@MainActor
final class CursorAnswerPresenter {
    private let pointerFlight: PointerFlightController

    init(pointerFlight: PointerFlightController) {
        self.pointerFlight = pointerFlight
    }

    /// Shows an answer's text in the bubble beside the cursor, replacing any bubble already there.
    func showAnswer(text: String) {}

    /// Shows a short notice beside the cursor the same way as an answer.
    func showNotice(text: String) {}

    /// Shows the speaker capsule beside the cursor while an answer is read aloud, and removes it after.
    func showSpeaking(_ isSpeaking: Bool) {}

    /// Removes the bubble and the speaker capsule at once: a new question, Start, Stop and Quit.
    func hideAll() {}
}
