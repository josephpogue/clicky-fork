import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ShotFileNaming {
    /// "0007-screen1.jpg" for group 7, screen 1.
    public static func fileName(groupID: Int, screenNumber: Int) -> String {
        String(format: "%04d-screen%d.jpg", groupID, screenNumber)
    }
}

public struct EncodedScreenshot {
    public let jpegData: Data
    public let pixelWidth: Int
    public let pixelHeight: Int
}

public enum ScreenshotJPEGEncoderError: Error {
    case couldNotResize
    case couldNotEncode
}

/// Resizes a screenshot to the size sent to the AI and compresses it near a target byte size.
public enum ScreenshotJPEGEncoder {
    public static let longSidePixels = 1280
    public static let targetByteCount = 150_000

    public static func encode(_ image: CGImage) throws -> EncodedScreenshot {
        let longSide = max(image.width, image.height)
        let scale = longSide > longSidePixels ? Double(longSidePixels) / Double(longSide) : 1.0
        let outputWidth = max(1, Int((Double(image.width) * scale).rounded()))
        let outputHeight = max(1, Int((Double(image.height) * scale).rounded()))

        guard let context = CGContext(
            data: nil, width: outputWidth, height: outputHeight, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw ScreenshotJPEGEncoderError.couldNotResize }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))
        guard let resizedImage = context.makeImage() else { throw ScreenshotJPEGEncoderError.couldNotResize }

        // Step the quality down until the file is near the target; keep the smallest try if none fit.
        var smallestData: Data?
        for quality in [0.85, 0.75, 0.65, 0.55, 0.45, 0.35] {
            let data = try jpegData(from: resizedImage, quality: quality)
            if smallestData == nil || data.count < smallestData!.count { smallestData = data }
            if data.count <= targetByteCount {
                return EncodedScreenshot(jpegData: data, pixelWidth: outputWidth, pixelHeight: outputHeight)
            }
        }
        return EncodedScreenshot(jpegData: smallestData ?? Data(), pixelWidth: outputWidth, pixelHeight: outputHeight)
    }

    private static func jpegData(from image: CGImage, quality: Double) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ScreenshotJPEGEncoderError.couldNotEncode
        }
        CGImageDestinationAddImage(destination, image,
                                   [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ScreenshotJPEGEncoderError.couldNotEncode }
        return output as Data
    }
}
