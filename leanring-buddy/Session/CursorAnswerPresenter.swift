//
//  CursorAnswerPresenter.swift
//  leanring-buddy
//
//  Everything a session shows beside the cursor after a question: the answer
//  bubble, notices (a failed start, a provider error, the usage limit) and the
//  small speaker capsule while an answer is read aloud. It never opens a window
//  that takes clicks, keys or scroll from the user's app.
//
//  The bubble shows only whole sentences that fit (`CursorLineState` decides which); it is never cut.
//
//  The bubble stays until a click or keypress anywhere (or a new question, Start, Stop or Quit) and
//  follows the cursor meanwhile. While a pointing answer's blue triangle is away from the cursor, the
//  bubble rides under the triangle's label. No panel and no event monitor exists between answers.
//
//  SessionCoordinator calls it.
//

import AppKit
import ClickyCore
import SwiftUI

@MainActor
final class CursorAnswerPresenter {
    private let pointerFlight: PointerFlightController

    private var bubblePanel: CursorAttachedPanel?
    private var bubbleContent: AnswerBubbleContent?
    private var bubbleNearCorner: CursorBubbleLayout.NearCorner = .topLeading
    /// A bubble that is fading out after a click or keypress; `hideAll` removes it at once.
    private var fadingBubblePanel: CursorAttachedPanel?

    private var speakingPanel: CursorAttachedPanel?
    private var isSpeaking = false
    /// Decides show, update in place or leave alone as an answer grows (and after a click or key dismissed it).
    private var growingBubbleState = GrowingAnswerBubbleState()

    private var followTimer: Timer?
    private var globalDismissMonitor: Any?
    private var localDismissMonitor: Any?

    private static let dismissingEvents: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
    private static let speakingCapsuleSize = CGSize(width: 78, height: QuestionMarkerView.markerHeight + 8)

    init(pointerFlight: PointerFlightController) {
        self.pointerFlight = pointerFlight
    }

    /// Shows a short notice beside the cursor the same way as an answer: whole sentences that fit, then the footer
    /// when some were left out.
    func showNotice(text: String) {
        growingBubbleState.reset()
        let line = CursorLine.notice(text: text, fits: { AnswerBubbleMetrics.fitsInBubble(text: $0) })
        showBubble(content: content(for: line, isNotice: true, showsCheckingLine: false))
    }

    /// "Checking your notes" under the line so far, or alone before any text.
    func showCheckingLine() {
        apply(growingBubbleState.checkingLineReported())
    }

    /// The chat key's name for the footer ("Right ⌘ ,") while a session runs; nil outside a session, when the
    /// footer points to the menu-bar panel's Open chat instead. Set by SessionCoordinator.
    var chatKeyName: String?

    /// The answer's cursor line (whole sentences that fit, and whether more is in the chat) each time it changes,
    /// streaming and final alike: the first one shows the bubble, later ones change it in place.
    func showCursorLine(_ line: CursorLine) {
        apply(growingBubbleState.lineReported(line))
    }

    /// The footer for a line: "More in chat: <key>" under text, "Answer in chat: <key>" when it is the footer
    /// alone, and a pointer to the menu bar's Open chat outside a session. Nil when the line holds everything.
    private func footerText(for line: CursorLine) -> String? {
        guard line.hasMoreInChat else { return nil }
        guard let chatKeyName else { return "More in Open chat, in the menu bar" }
        return line.text.isEmpty ? "Answer in chat: \(chatKeyName)" : "More in chat: \(chatKeyName)"
    }

    private func content(for line: CursorLine, isNotice: Bool, showsCheckingLine: Bool) -> AnswerBubbleContent {
        AnswerBubbleContent(
            text: line.text, isNotice: isNotice, footerText: footerText(for: line), showsCheckingLine: showsCheckingLine)
    }

    /// The model began a tool call: after a click dismissed the bubble, the next text is a new finding.
    func noteToolCallStarted() {
        growingBubbleState.toolCallStartedReported()
    }

    /// True when a bubble is on screen (the listening marker hides once the first text or checking line shows).
    var isBubbleShowing: Bool { bubblePanel != nil }

    /// Shows the speaker capsule beside the cursor while an answer is read aloud, and removes it after.
    func showSpeaking(_ isSpeaking: Bool) {
        self.isSpeaking = isSpeaking
        refreshSpeakingCapsule()
        stopFollowingWhenNothingShows()
    }

    /// Removes the bubble and the speaker capsule at once: a new question, Start, Stop and Quit.
    func hideAll() {
        growingBubbleState.reset()
        isSpeaking = false
        removeBubbleNow()
        fadingBubblePanel?.removeNow()
        fadingBubblePanel = nil
        speakingPanel?.removeNow()
        speakingPanel = nil
        removeDismissMonitors()
        stopFollowing()
    }

    // MARK: - Bubble

    private func apply(_ action: GrowingAnswerBubbleState.Action) {
        switch action {
        case .nothing:
            return
        case .show(let line, let showsCheckingLine):
            showBubble(content: content(for: line, isNotice: false, showsCheckingLine: showsCheckingLine))
        case .update(let line, let showsCheckingLine):
            updateBubbleInPlace(content: content(for: line, isNotice: false, showsCheckingLine: showsCheckingLine))
        }
    }

    /// Changes the text of the bubble on screen with no fade. When the new text needs a different size, a new panel
    /// takes the old one's place at once (shown before the old one goes), because a panel is fixed-size.
    private func updateBubbleInPlace(content: AnswerBubbleContent) {
        guard let panel = bubblePanel, let currentContent = bubbleContent else {
            showBubble(content: content)
            return
        }
        if content.size == currentContent.size {
            bubbleContent = content
            panel.update(rootView: AnswerBubbleView(content: content, nearCorner: bubbleNearCorner))
            return
        }
        let replacement = CursorAttachedPanel(
            rootView: AnswerBubbleView(content: content, nearCorner: bubbleNearCorner), size: content.size,
            shadowMargin: AnswerBubbleView.shadowMargin)
        bubblePanel = replacement
        bubbleContent = content
        moveBubbleToItsSpot()
        replacement.show()
        panel.removeNow()
    }

    private func showBubble(content: AnswerBubbleContent) {
        removeBubbleNow()
        fadingBubblePanel?.removeNow()
        fadingBubblePanel = nil
        // The bubble speaks for the answer; the capsule comes back only if the bubble is dismissed while reading goes on.
        speakingPanel?.removeNow()
        speakingPanel = nil

        let panel = CursorAttachedPanel(
            rootView: AnswerBubbleView(content: content, nearCorner: .topLeading), size: content.size,
            shadowMargin: AnswerBubbleView.shadowMargin)
        bubblePanel = panel
        bubbleContent = content
        bubbleNearCorner = .topLeading
        moveBubbleToItsSpot()
        panel.showFadingIn(duration: 0.15)
        installDismissMonitors()
        startFollowing()
    }

    private func removeBubbleNow() {
        bubblePanel?.removeNow()
        bubblePanel = nil
        bubbleContent = nil
    }

    /// A click or keypress: fade the bubble out, stop watching events, and bring the capsule back if reading continues.
    private func dismissBubbleAfterUserInput() {
        guard let panel = bubblePanel else { return }
        growingBubbleState.userDismissed()
        bubblePanel = nil
        bubbleContent = nil
        removeDismissMonitors()
        fadingBubblePanel?.removeNow()
        fadingBubblePanel = panel
        panel.fadeOutAndRemove(duration: 0.2)
        refreshSpeakingCapsule()
        stopFollowingWhenNothingShows()
    }

    private func installDismissMonitors() {
        removeDismissMonitors()
        // Global: input going to other apps. Local: input going to this app's own windows.
        globalDismissMonitor = NSEvent.addGlobalMonitorForEvents(matching: Self.dismissingEvents) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismissBubbleAfterUserInput() }
        }
        localDismissMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.dismissingEvents) { [weak self] event in
            MainActor.assumeIsolated { self?.dismissBubbleAfterUserInput() }
            return event
        }
    }

    private func removeDismissMonitors() {
        if let globalDismissMonitor { NSEvent.removeMonitor(globalDismissMonitor) }
        if let localDismissMonitor { NSEvent.removeMonitor(localDismissMonitor) }
        globalDismissMonitor = nil
        localDismissMonitor = nil
    }

    // MARK: - Speaker capsule

    private func refreshSpeakingCapsule() {
        let shouldShowCapsule = isSpeaking && bubblePanel == nil
        if shouldShowCapsule && speakingPanel == nil {
            let panel = CursorAttachedPanel(rootView: SpeakingMarkerPanelContent(size: Self.speakingCapsuleSize), size: Self.speakingCapsuleSize)
            speakingPanel = panel
            moveSpeakingCapsuleNextToCursor()
            panel.show()
            startFollowing()
        } else if !shouldShowCapsule, let panel = speakingPanel {
            panel.removeNow()
            speakingPanel = nil
        }
    }

    // MARK: - Following the cursor

    private func startFollowing() {
        guard followTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.moveEverythingToItsSpot() }
        }
        RunLoop.main.add(timer, forMode: .common)
        followTimer = timer
    }

    private func stopFollowing() {
        followTimer?.invalidate()
        followTimer = nil
    }

    private func stopFollowingWhenNothingShows() {
        if bubblePanel == nil && speakingPanel == nil { stopFollowing() }
    }

    private func moveEverythingToItsSpot() {
        moveBubbleToItsSpot()
        moveSpeakingCapsuleNextToCursor()
    }

    /// Beside the cursor, or under the pointer's label while the blue triangle is away from the cursor.
    private func moveBubbleToItsSpot() {
        guard let panel = bubblePanel, let content = bubbleContent else { return }
        let mouseLocation = NSEvent.mouseLocation
        let anchor: CursorBubbleLayout.Anchor
        let anchorPoint: CGPoint
        if let labelFrame = pointerFlight.pointerLabelGlobalFrame {
            anchor = .belowLabel(labelFrame, clearing: pointerFlight.pointerClearanceGlobalFrame)
            anchorPoint = CGPoint(x: labelFrame.midX, y: labelFrame.midY)
        } else {
            anchor = .cursor(at: mouseLocation)
            anchorPoint = mouseLocation
        }
        let placement = CursorBubbleLayout.placement(
            anchor: anchor, bubbleSize: content.size, visibleFrame: visibleFrame(containing: anchorPoint))
        panel.setFrameOrigin(placement.origin)
        if placement.nearCorner != bubbleNearCorner {
            bubbleNearCorner = placement.nearCorner
            panel.update(rootView: AnswerBubbleView(content: content, nearCorner: placement.nearCorner))
        }
    }

    private func moveSpeakingCapsuleNextToCursor() {
        guard let panel = speakingPanel else { return }
        let mouseLocation = NSEvent.mouseLocation
        let placement = CursorBubbleLayout.placement(
            anchor: .cursor(at: mouseLocation),
            bubbleSize: panel.size,
            visibleFrame: visibleFrame(containing: mouseLocation))
        panel.setFrameOrigin(placement.origin)
    }

    /// The usable area of the display holding `point` (below the menu bar, clear of the Dock).
    private func visibleFrame(containing point: CGPoint) -> CGRect {
        let screens = NSScreen.screens
        guard let index = CursorBubbleLayout.displayIndex(containing: point, in: screens.map(\.frame)) else {
            return NSScreen.main?.visibleFrame ?? .zero
        }
        return screens[index].visibleFrame
    }
}
