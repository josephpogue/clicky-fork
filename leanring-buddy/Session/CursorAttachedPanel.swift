//
//  CursorAttachedPanel.swift
//  leanring-buddy
//
//  A small panel that hangs beside the mouse pointer and never takes anything from the user's app:
//  borderless, non-activating, never key or main, deaf to the mouse. It is shown with
//  `orderFrontRegardless`, never `makeKey`, so the frontmost app and key window stay as they were.
//

import AppKit
import SwiftUI

// Not generic on purpose: Swift 6.2.4's Release optimizer crashed specializing the
// deallocator of a generic @MainActor class here. Only init and update are generic.
@MainActor
final class CursorAttachedPanel {
    private var panel: NSPanel?
    private var hostingView: NSView?
    private let panelSize: CGSize
    /// Empty room around the content for its shadow, which a window would otherwise cut off.
    /// `size` and `setFrameOrigin` speak of the content; the panel is larger by this on every side.
    private let shadowMargin: CGFloat

    init<Content: View>(rootView: Content, size: CGSize, shadowMargin: CGFloat = 0) {
        panelSize = size
        self.shadowMargin = shadowMargin
        let windowSize = CGSize(width: size.width + 2 * shadowMargin, height: size.height + 2 * shadowMargin)
        let attachedPanel = NonActivatingCursorPanel(
            contentRect: CGRect(origin: .zero, size: windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        attachedPanel.isOpaque = false
        attachedPanel.backgroundColor = .clear
        attachedPanel.hasShadow = false
        attachedPanel.level = .screenSaver
        attachedPanel.ignoresMouseEvents = true
        attachedPanel.isReleasedWhenClosed = false
        attachedPanel.hidesOnDeactivate = false
        attachedPanel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        // Fixed-size hosting views need sizingOptions = [] or they can render blank (fork rule).
        let hosting = NSHostingView(rootView: rootView)
        hosting.sizingOptions = []
        hosting.frame = CGRect(origin: .zero, size: windowSize)
        attachedPanel.contentView = hosting
        panel = attachedPanel
        hostingView = hosting
    }

    var size: CGSize { panelSize }
    
    /// `Content` must be the view type the panel was made with.
    func update<Content: View>(rootView: Content) {
        (hostingView as? NSHostingView<Content>)?.rootView = rootView
    }

    func setFrameOrigin(_ origin: CGPoint) {
        panel?.setFrameOrigin(CGPoint(x: origin.x - shadowMargin, y: origin.y - shadowMargin))
    }

    func showFadingIn(duration: TimeInterval) {
        panel?.alphaValue = 0
        panel?.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            panel?.animator().alphaValue = 1
        }
    }

    func show() {
        panel?.orderFrontRegardless()
    }

    /// Fades out over `duration`, then removes the panel. Safe to call `removeNow` meanwhile.
    func fadeOutAndRemove(duration: TimeInterval) {
        guard let fadingPanel = panel else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            fadingPanel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.removeNow() }
        })
    }

    func removeNow() {
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        hostingView = nil
    }
}

/// A panel that can never become the key or main window.
private final class NonActivatingCursorPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
