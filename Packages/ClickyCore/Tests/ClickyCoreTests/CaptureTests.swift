import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import ClickyCore

/// Builds a solid or split gray image so signature expectations can be worked out by hand.
private func makeGrayImage(width: Int, height: Int, grayValueForColumn: (Int) -> UInt8) -> CGImage {
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    for row in 0..<height {
        for column in 0..<width {
            let value = grayValueForColumn(column)
            let offset = (row * width + column) * 4
            pixels[offset] = value
            pixels[offset + 1] = value
            pixels[offset + 2] = value
            pixels[offset + 3] = 255
        }
    }
    let provider = CGDataProvider(data: Data(pixels) as CFData)!
    return CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
    )!
}

private func makeShotGroup(thumbnailBytes: [[UInt8]], screenNumbers: [Int]? = nil) -> ShotGroup {
    let shots = thumbnailBytes.enumerated().map { index, bytes in
        DisplayShot(
            fileName: "x\(index).jpg",
            screenNumber: screenNumbers?[index] ?? index + 1,
            isCursorScreen: index == 0,
            pixelWidth: 1280, pixelHeight: 800,
            displayFrameInPoints: .zero,
            thumbnail: ThumbnailSignature(width: 2, height: 2, grayscaleBytes: bytes)
        )
    }
    return ShotGroup(id: 1, capturedAt: Date(timeIntervalSince1970: 0), reason: .question,
                     appName: "App", windowTitle: nil, shots: shots)
}

@Suite struct ThumbnailSignatureTests {
    @Test func blackVersusWhiteDiffersByOne() {
        let black = ThumbnailSignature.make(from: makeGrayImage(width: 2, height: 2) { _ in 0 }, width: 2, height: 2)
        let white = ThumbnailSignature.make(from: makeGrayImage(width: 2, height: 2) { _ in 255 }, width: 2, height: 2)
        #expect(ThumbnailSignature.difference(black, white) == 1.0)
    }

    @Test func identicalImagesDifferByZero() {
        let first = ThumbnailSignature.make(from: makeGrayImage(width: 2, height: 2) { _ in 90 }, width: 2, height: 2)
        let second = ThumbnailSignature.make(from: makeGrayImage(width: 2, height: 2) { _ in 90 }, width: 2, height: 2)
        #expect(ThumbnailSignature.difference(first, second) == 0.0)
    }

    @Test func halfBlackHalfWhiteVersusBlackIsHalf() {
        // Half the cells differ by 255, the rest by 0: (2 * 255) / (4 * 255) = 0.5
        let split = ThumbnailSignature.make(from: makeGrayImage(width: 2, height: 2) { $0 == 0 ? 0 : 255 }, width: 2, height: 2)
        let black = ThumbnailSignature.make(from: makeGrayImage(width: 2, height: 2) { _ in 0 }, width: 2, height: 2)
        #expect(ThumbnailSignature.difference(split, black) == 0.5)
    }

    @Test func differentSizesCountAsFullyDifferent() {
        let small = ThumbnailSignature(width: 2, height: 2, grayscaleBytes: [0, 0, 0, 0])
        let large = ThumbnailSignature(width: 4, height: 2, grayscaleBytes: [0, 0, 0, 0, 0, 0, 0, 0])
        #expect(ThumbnailSignature.difference(small, large) == 1.0)
    }

    @Test func defaultSignatureIs32By20() {
        let signature = ThumbnailSignature.make(from: makeGrayImage(width: 64, height: 40) { _ in 10 })
        #expect(signature.width == 32)
        #expect(signature.height == 20)
        #expect(signature.grayscaleBytes.count == 640)
    }
}

@Suite struct ShotGroupDifferenceTests {
    @Test func differentDisplayCountIsOne() {
        let two = makeShotGroup(thumbnailBytes: [[0, 0, 0, 0], [0, 0, 0, 0]])
        let one = makeShotGroup(thumbnailBytes: [[0, 0, 0, 0]])
        #expect(two.maximumDifference(from: one) == 1.0)
    }

    @Test func blackVersusWhiteSingleDisplayIsOne() {
        let black = makeShotGroup(thumbnailBytes: [[0, 0, 0, 0]])
        let white = makeShotGroup(thumbnailBytes: [[255, 255, 255, 255]])
        #expect(black.maximumDifference(from: white) == 1.0)
    }

    @Test func takesTheLargestDifferenceAcrossDisplays() {
        // Display 1 unchanged (0.0), display 2 changes by half (0.5): the maximum is 0.5.
        let before = makeShotGroup(thumbnailBytes: [[0, 0, 0, 0], [0, 0, 0, 0]])
        let after = makeShotGroup(thumbnailBytes: [[0, 0, 0, 0], [0, 0, 255, 255]])
        #expect(before.maximumDifference(from: after) == 0.5)
    }
}

@Suite struct CaptureSavePolicyTests {
    let policy = CaptureSavePolicy()
    let start = Date(timeIntervalSince1970: 1000)

    private func decide(_ reason: ShotReason, at seconds: Double, difference: Double? = nil, hasLastSave: Bool = true) -> CaptureDecision {
        policy.decide(reason: reason, now: start.addingTimeInterval(seconds),
                      lastSaveTime: hasLastSave ? start : nil, differenceFromLastSaved: difference)
    }

    @Test func screenChangeWithinTwoSecondsIsSkipped() {
        #expect(decide(.screenChange, at: 1.0, difference: 0.5) == .skip)
    }

    @Test func screenChangeAtTwoSecondsSavesWhenBigEnough() {
        #expect(decide(.screenChange, at: 2.0, difference: 0.5) == .saveNow)
    }

    @Test func smallScreenChangeIsSkipped() {
        #expect(decide(.screenChange, at: 3.0, difference: 0.03) == .skip)
    }

    @Test func appSwitchWithinTwoSecondsIsDeferred() {
        #expect(decide(.appSwitch, at: 0.5) == .saveAt(start.addingTimeInterval(2.0)))
        #expect(decide(.windowSwitch, at: 0.5) == .saveAt(start.addingTimeInterval(2.0)))
    }

    @Test func questionAlwaysSavesNow() {
        #expect(decide(.question, at: 0.5) == .saveNow)
    }

    @Test func noPreviousSaveSavesForAnyReason() {
        for reason in [ShotReason.sessionStart, .question, .appSwitch, .windowSwitch, .screenChange] {
            #expect(decide(reason, at: 0.1, difference: 0.0, hasLastSave: false) == .saveNow)
        }
    }

    @Test func switchAfterTwoSecondsSavesNow() {
        #expect(decide(.appSwitch, at: 5.0) == .saveNow)
    }
}

@Suite struct ShotFileNamingTests {
    @Test func padsGroupIdToFourDigits() {
        #expect(ShotFileNaming.fileName(groupID: 7, screenNumber: 1) == "0007-screen1.jpg")
    }
}

@Suite struct ScreenshotJPEGEncoderTests {
    /// Gradient plus a few shapes, so the image compresses like a screen rather than a flat color.
    private func makeBusyImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for step in 0..<height {
            let fraction = CGFloat(step) / CGFloat(height)
            context.setFillColor(red: fraction, green: 0.4, blue: 1 - fraction, alpha: 1)
            context.fill(CGRect(x: 0, y: step, width: width, height: 1))
        }
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 200, y: 200, width: 900, height: 500))
        context.setFillColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)
        for line in 0..<20 {
            context.fill(CGRect(x: 240, y: 240 + line * 22, width: 400 + (line * 37) % 300, height: 8))
        }
        context.setFillColor(red: 0.9, green: 0.2, blue: 0.2, alpha: 1)
        context.fillEllipse(in: CGRect(x: 1500, y: 600, width: 400, height: 400))
        return context.makeImage()!
    }

    @Test func resizesLongSideTo1280AndStaysSmall() throws {
        let encoded = try ScreenshotJPEGEncoder.encode(makeBusyImage(width: 2560, height: 1600))
        #expect(encoded.pixelWidth == 1280)
        #expect(encoded.pixelHeight == 800)
        #expect(encoded.jpegData.count < 300_000)
        #expect(encoded.jpegData.count > 1000)
        // A real JPEG starts with the SOI marker.
        #expect(encoded.jpegData.prefix(2) == Data([0xFF, 0xD8]))
    }

    @Test func theSavedFileIsA1280PixelJPEGUnder300KB() throws {
        let encoded = try ScreenshotJPEGEncoder.encode(makeBusyImage(width: 2560, height: 1600))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("clicky-jpeg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let savedFile = folder.appendingPathComponent("0001-screen1.jpg")
        try encoded.jpegData.write(to: savedFile)

        // Read the file back the way any viewer would: its real size, not the encoder's claim.
        let fileSize = try #require(try FileManager.default.attributesOfItem(atPath: savedFile.path)[.size] as? Int)
        let source = try #require(CGImageSourceCreateWithURL(savedFile as CFURL, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(max(decoded.width, decoded.height) == 1280)
        #expect(fileSize < 300_000)
    }

    @Test func portraitImageKeepsLongSideAt1280() throws {
        let encoded = try ScreenshotJPEGEncoder.encode(makeBusyImage(width: 1600, height: 2560))
        #expect(encoded.pixelHeight == 1280)
        #expect(encoded.pixelWidth == 800)
    }
}
