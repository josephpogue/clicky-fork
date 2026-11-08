//
//  UIPreviewRendering.swift
//  leanring-buddy
//
//  Renders SwiftUI views to PNG files without showing a window, so a screen
//  can be checked by looking at the picture. Run through the app's
//  `--render-ui-previews <folder>` launch flag. Later slices add their views to `renderAll`.
//
//  Views are drawn through an offscreen `NSHostingView` inside a borderless
//  `NSWindow` that is never ordered on screen, then captured with
//  `cacheDisplay`. `ImageRenderer` cannot be used: it draws SwiftUI buttons
//  as yellow placeholder boxes.
//

import AppKit
import ClickyCore
import SwiftUI

enum UIPreviewRendering {
    enum PreviewRenderingError: Error {
        case imageCreationFailed(fileName: String)
    }

    /// Writes one PNG per preview into `directory`, creating it if needed.
    @MainActor
    static func renderAll(into directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try render(SamplePreviewView(), size: nil, fileName: "sample.png", into: directory)

        let chatWindowSize = CGSize(width: 360, height: 520)
        for (fileName, chatState) in UIPreviewSamples.chatStates() {
            try render(ChatWindowView(state: chatState), size: chatWindowSize, fileName: fileName, into: directory)
        }

        for (fileName, markerPhase) in UIPreviewSamples.markerPhases() {
            try render(MarkerInContextPreview(phase: markerPhase), size: nil, fileName: fileName, into: directory)
        }

        let settingsWindowSize = CGSize(width: 520, height: 900)
        for (fileName, settingsState) in UIPreviewSamples.settingsStates() {
            try render(SettingsView(state: settingsState), size: settingsWindowSize, fileName: fileName, into: directory)
        }

        let sessionListWindowSize = CGSize(width: 460, height: 420)
        try render(SessionListView(items: [], onOpen: { _ in }, onStartSession: {}), size: sessionListWindowSize, fileName: "sessions-empty.png", into: directory)
        try render(SessionListView(items: UIPreviewSamples.sessionListItems(), onOpen: { _ in }), size: sessionListWindowSize, fileName: "sessions-four.png", into: directory)

        let sampleShotFileURLs = try UIPreviewSamples.writeSampleShots()
        let detailState = UIPreviewSamples.sessionDetailState(shotFileURLs: sampleShotFileURLs, isSaved: false)
        try render(SessionDetailView(state: detailState, onSave: {}, onRevealInFinder: {}), size: CGSize(width: 620, height: 1040), fileName: "detail-eight-rows.png", into: directory)
        let savedDetailState = UIPreviewSamples.sessionDetailState(shotFileURLs: sampleShotFileURLs, isSaved: true)
        try render(SessionDetailView(state: savedDetailState, onSave: {}, onRevealInFinder: {}), size: CGSize(width: 620, height: 420), fileName: "detail-saved-header.png", into: directory)
        try render(
            SessionDetailView(state: detailState, onSave: {}, onRevealInFinder: {}, initiallyEnlargedShotFileURL: sampleShotFileURLs.first),
            size: CGSize(width: 620, height: 520),
            fileName: "detail-shot-open.png",
            into: directory
        )

        let runningDetailState = UIPreviewSamples.runningSessionDetailState(shotFileURLs: sampleShotFileURLs)
        try render(SessionDetailView(state: runningDetailState, onSave: {}, onRevealInFinder: {}), size: CGSize(width: 620, height: 420), fileName: "detail-running-save-disabled.png", into: directory)

        // Settings on a 1024x768 display: 25 for the menu bar and 70 for the Dock leave 673 high, and the 28
        // title bar leaves 645 for the content. The content scrolls.
        let smallDisplaySettings = SettingsState(
            providers: [UIPreviewSamples.settingsClaudeRow(isSignedIn: true), UIPreviewSamples.settingsChatGPTRow(isSignedIn: false, isBusy: true)],
            selectedProviderName: "Claude", notesFolderPath: "/Users/sample/Notes/vault")
        try render(SettingsView(state: smallDisplaySettings), size: CGSize(width: 520, height: 645), fileName: "settings-1024x768.png", into: directory)

        // CLICKY_VAULT_ROOT sets the notes folder: the folder Save will use, with the note saying why.
        let environmentFolderSettings = SettingsState(
            providers: [UIPreviewSamples.settingsClaudeRow(isSignedIn: true), UIPreviewSamples.settingsChatGPTRow(isSignedIn: true)],
            selectedProviderName: "Claude", notesFolderPath: "/Users/sample/Notes/vault", isNotesFolderSetByEnvironment: true)
        try render(SettingsView(state: environmentFolderSettings), size: settingsWindowSize, fileName: "settings-notes-folder-from-environment.png", into: directory)

        // The label beside the pointer, with the pointer 20 points from the right edge, then near the bottom and top.
        for (fileName, pointerPosition) in [
            ("pointer-label-right-edge.png", CGPoint(x: 460, y: 120)),
            ("pointer-label-bottom-edge.png", CGPoint(x: 150, y: 290)),
            ("pointer-label-top-edge.png", CGPoint(x: 150, y: 6)),
            ("pointer-label-roomy.png", CGPoint(x: 150, y: 120)),
        ] {
            try render(PointerLabelEdgePreview(pointerPosition: pointerPosition), size: CGSize(width: 480, height: 300), fileName: fileName, into: directory)
        }

        for (fileName, saveState) in UIPreviewSamples.saveStates() {
            try render(SaveToVaultSheet(state: saveState, onConfirm: { _ in }, onCancel: {}, onOpenSettings: {}), size: nil, fileName: fileName, into: directory)
        }

        // Each answer-delivery slice renders its own previews from its own file.
        try renderCursorAnswerPreviews(into: directory)
        try renderAnswerDeliverySettingsPreviews(into: directory)
        try renderQuestionKeyPreviews(into: directory)
        try renderMenuPanelPreviews(into: directory)
        try renderBrainSearchPreviews(into: directory)
    }

    /// Draws `view` at `size` (or at its own fitting size when nil) at 2x and writes a PNG.
    @MainActor
    static func render<Content: View>(_ view: Content, size: CGSize?, fileName: String, into directory: URL) throws {
        let hostingView = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        let offscreenWindow = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 400, height: 400),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        offscreenWindow.isReleasedWhenClosed = false
        offscreenWindow.appearance = NSAppearance(named: .darkAqua)
        offscreenWindow.backgroundColor = .clear
        offscreenWindow.contentView = hostingView

        let targetSize = size ?? hostingView.fittingSize
        if size != nil {
            // A fixed-size render: stop the hosting view from pushing the
            // SwiftUI view's own size limits onto the window, which collapses
            // views whose content is all fixed-size (the empty session list).
            hostingView.sizingOptions = []
        }
        offscreenWindow.setContentSize(targetSize)
        hostingView.frame = NSRect(origin: .zero, size: targetSize)
        hostingView.layoutSubtreeIfNeeded()
        // One short turn of the run loop lets SwiftUI finish its layout passes
        // (ViewThatFits, scroll anchors) before the capture.
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        hostingView.layoutSubtreeIfNeeded()
        hostingView.display()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        let renderScale: CGFloat = 2
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(targetSize.width * renderScale),
            pixelsHigh: Int(targetSize.height * renderScale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw PreviewRenderingError.imageCreationFailed(fileName: fileName)
        }
        bitmap.size = targetSize
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        offscreenWindow.close()

        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw PreviewRenderingError.imageCreationFailed(fileName: fileName)
        }
        try pngData.write(to: directory.appendingPathComponent(fileName))
    }
}

/// Shows the marker where the overlay will put it: beside a real arrow
/// cursor, once over a light page and once over a dark one.
private struct MarkerInContextPreview: View {
    let phase: QuestionPhase

    var body: some View {
        HStack(spacing: 0) {
            backdropTile(isLight: true)
            backdropTile(isLight: false)
        }
    }

    private func backdropTile(isLight: Bool) -> some View {
        let cursorImage = NSCursor.arrow.image
        let cursorHotSpot = NSCursor.arrow.hotSpot
        let pointerTip = CGPoint(x: 34, y: 26)
        return ZStack(alignment: .topLeading) {
            (isLight ? Color(hex: "#F5F5F3") : Color(hex: "#1E2022"))
            VStack(alignment: .leading, spacing: 7) {
                ForEach(0..<5, id: \.self) { lineIndex in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(isLight ? Color.black.opacity(0.13) : Color.white.opacity(0.12))
                        .frame(width: [150, 120, 165, 90, 140][lineIndex], height: 6)
                }
            }
            .padding(.leading, 16)
            .padding(.top, 18)

            Image(nsImage: cursorImage)
                .offset(x: pointerTip.x - cursorHotSpot.x, y: pointerTip.y - cursorHotSpot.y)
            QuestionMarkerView(phase: phase)
                .offset(
                    x: pointerTip.x + QuestionMarkerView.suggestedOffsetFromCursor.width,
                    y: pointerTip.y + QuestionMarkerView.suggestedOffsetFromCursor.height
                )
        }
        .frame(width: 200, height: 86, alignment: .topLeading)
        .clipped()
    }
}

/// A made-up 480 x 300 screen with the pointer and its label laid out by the same function the overlay uses.
/// The label copies the overlay's style; the overlay itself needs a real display, so it is not drawn here.
private struct PointerLabelEdgePreview: View {
    let pointerPosition: CGPoint
    private let screenSize = CGSize(width: 480, height: 300)
    private let labelText = "save button"

    var body: some View {
        let fullLabelWidth = PointerLabelMetrics.fullWidth(ofText: labelText)
        ZStack(alignment: .topLeading) {
            Color(hex: "#1E2022")
            Triangle()
                .fill(DS.Colors.overlayCursorBlue)
                .frame(width: 16, height: 16)
                .rotationEffect(.degrees(-35))
                .position(pointerPosition)
            Text(labelText)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(DS.Colors.overlayCursorBlue))
                .fixedSize()
                .position(PointerLabelLayout.center(
                    pointerPosition: pointerPosition,
                    currentLabelSize: CGSize(width: fullLabelWidth, height: 22),
                    fullLabelWidth: fullLabelWidth,
                    screenSize: screenSize))
        }
        .frame(width: screenSize.width, height: screenSize.height)
        .clipped()
    }
}

/// A small sample in the app's design style, proving the render path works.
private struct SamplePreviewView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(DS.Colors.success)
                    .frame(width: 8, height: 8)
                Text("Clicky Fork")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
            }
            Text("UI preview sample")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
            Text("Start session")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(DS.Colors.textOnAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                        .fill(DS.Colors.accent)
                )
        }
        .padding(16)
        .frame(width: 280)
        .background(DS.Colors.background)
    }
}
