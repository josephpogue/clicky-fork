//
//  QuestionMarkerPanel.swift
//  leanring-buddy
//
//  Shows the small question marker next to the mouse pointer: "listening",
//  "working", "waiting for the answer". It is a click-through panel that never
//  becomes key or main, so it cannot take focus or keystrokes from the app
//  the user is working in. It exists only while a question is under way.
//

import AppKit
import SwiftUI

@MainActor
final class QuestionMarkerPanel {
    private var panel: NSPanel?
    private var hostingView: NSHostingView<QuestionMarkerView>?
    private var followTimer: Timer?

    private let panelSize = CGSize(width: 220, height: QuestionMarkerView.markerHeight + 8)

    /// Shows the marker for `phase`, or removes it for `.idle`.
    func show(phase: QuestionPhase) {
        if phase == .idle {
            hide()
            return
        }
        if panel == nil {
            createPanel(phase: phase)
        } else {
            hostingView?.rootView = QuestionMarkerView(phase: phase)
        }
        moveNextToCursor()
        panel?.orderFrontRegardless()
        if followTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.moveNextToCursor() }
            }
            RunLoop.main.add(timer, forMode: .common)
            followTimer = timer
        }
    }

    func hide() {
        followTimer?.invalidate()
        followTimer = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        hostingView = nil
    }

    private func createPanel(phase: QuestionPhase) {
        let markerPanel = NonActivatingMarkerPanel(
            contentRect: CGRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        markerPanel.isOpaque = false
        markerPanel.backgroundColor = .clear
        markerPanel.hasShadow = false
        markerPanel.level = .screenSaver
        markerPanel.ignoresMouseEvents = true
        markerPanel.isReleasedWhenClosed = false
        markerPanel.hidesOnDeactivate = false
        markerPanel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let hosting = NSHostingView(rootView: QuestionMarkerView(phase: phase))
        hosting.frame = CGRect(origin: .zero, size: panelSize)
        markerPanel.contentView = hosting
        panel = markerPanel
        hostingView = hosting
    }

    /// Puts the marker's top-left corner at the suggested offset from the cursor tip, flipped onto
    /// the cursor's own display, and keeps it fully on that display.
    private func moveNextToCursor() {
        guard let panel else { return }
        let mouseLocation = NSEvent.mouseLocation
        let displayFrame = NSScreen.screens.first { $0.frame.contains(mouseLocation) }?.frame
            ?? NSScreen.main?.frame ?? .zero
        let offset = QuestionMarkerView.suggestedOffsetFromCursor
        var originX = mouseLocation.x + offset.width
        // AppKit's origin is bottom-left; the marker hangs below the cursor tip.
        var originY = mouseLocation.y - offset.height - panelSize.height
        originX = min(max(originX, displayFrame.minX), displayFrame.maxX - panelSize.width)
        originY = min(max(originY, displayFrame.minY), displayFrame.maxY - panelSize.height)
        panel.setFrameOrigin(CGPoint(x: originX, y: originY))
    }
}

/// A panel that can never become the key or main window.
private final class NonActivatingMarkerPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
