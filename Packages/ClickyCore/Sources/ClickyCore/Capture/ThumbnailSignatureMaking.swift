import CoreGraphics
import Foundation

extension ThumbnailSignature {
    /// Shrinks an image to a small grayscale grid by averaging every source pixel inside each cell.
    /// Area averaging (not nearest-neighbor) keeps a single thin line from flipping a cell.
    public static func make(from cgImage: CGImage, width: Int = 32, height: Int = 20) -> ThumbnailSignature {
        let sourceWidth = cgImage.width
        let sourceHeight = cgImage.height
        guard sourceWidth > 0, sourceHeight > 0, width > 0, height > 0 else {
            return ThumbnailSignature(width: width, height: height,
                                      grayscaleBytes: [UInt8](repeating: 0, count: max(0, width * height)))
        }

        // Draw once into an 8-bit gray bitmap at the source size, then average blocks of it.
        var sourceGray = [UInt8](repeating: 0, count: sourceWidth * sourceHeight)
        sourceGray.withUnsafeMutableBytes { rawBuffer in
            guard let context = CGContext(
                data: rawBuffer.baseAddress, width: sourceWidth, height: sourceHeight,
                bitsPerComponent: 8, bytesPerRow: sourceWidth,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight))
        }

        var cellValues = [UInt8](repeating: 0, count: width * height)
        for cellRow in 0..<height {
            // Each cell covers at least one source pixel, even when the source is smaller than the grid.
            let firstRow = cellRow * sourceHeight / height
            let endRow = max(firstRow + 1, (cellRow + 1) * sourceHeight / height)
            for cellColumn in 0..<width {
                let firstColumn = cellColumn * sourceWidth / width
                let endColumn = max(firstColumn + 1, (cellColumn + 1) * sourceWidth / width)
                var sum = 0
                var count = 0
                for row in firstRow..<min(endRow, sourceHeight) {
                    for column in firstColumn..<min(endColumn, sourceWidth) {
                        sum += Int(sourceGray[row * sourceWidth + column])
                        count += 1
                    }
                }
                cellValues[cellRow * width + cellColumn] = count == 0 ? 0 : UInt8((sum + count / 2) / count)
            }
        }
        return ThumbnailSignature(width: width, height: height, grayscaleBytes: cellValues)
    }

    /// Mean absolute difference between two signatures divided by 255, so 0 means identical and 1 means black vs white.
    /// Signatures of different sizes cannot be compared cell by cell, so they count as fully different.
    public static func difference(_ first: ThumbnailSignature, _ second: ThumbnailSignature) -> Double {
        guard first.width == second.width,
              first.height == second.height,
              first.grayscaleBytes.count == second.grayscaleBytes.count,
              !first.grayscaleBytes.isEmpty else { return 1.0 }
        var totalDifference = 0
        for index in first.grayscaleBytes.indices {
            totalDifference += abs(Int(first.grayscaleBytes[index]) - Int(second.grayscaleBytes[index]))
        }
        return Double(totalDifference) / Double(first.grayscaleBytes.count * 255)
    }
}

extension ShotGroup {
    /// The largest change on any display compared with an earlier group. Displays are matched by screen number;
    /// a different number of displays (one plugged or unplugged) counts as a full change.
    public func maximumDifference(from other: ShotGroup) -> Double {
        guard shots.count == other.shots.count else { return 1.0 }
        var largestDifference = 0.0
        for shot in shots {
            guard let matchingShot = other.shots.first(where: { $0.screenNumber == shot.screenNumber }) else { return 1.0 }
            largestDifference = max(largestDifference,
                                    ThumbnailSignature.difference(shot.thumbnail, matchingShot.thumbnail))
        }
        return largestDifference
    }
}
