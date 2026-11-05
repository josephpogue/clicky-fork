//
//  UIPreviewRendering.swift
//  leanring-buddy
//
//  Renders SwiftUI views to PNG files without showing a window, so a screen
//  can be checked by looking at the picture. Run through the app's
//  `--render-ui-previews <folder>` launch flag. Later slices add their views to `renderAll`.
//

import AppKit
import SwiftUI

enum UIPreviewRendering {
    enum PreviewRenderingError: Error {
        case imageCreationFailed(fileName: String)
    }

    /// Writes one PNG per preview into `directory`, creating it if needed.
    @MainActor
    static func renderAll(into directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try render(SamplePreviewView(), fileName: "sample.png", into: directory)
    }

    @MainActor
    private static func render<Content: View>(_ view: Content, fileName: String, into directory: URL) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let cgImage = renderer.cgImage else {
            throw PreviewRenderingError.imageCreationFailed(fileName: fileName)
        }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw PreviewRenderingError.imageCreationFailed(fileName: fileName)
        }
        try pngData.write(to: directory.appendingPathComponent(fileName))
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
