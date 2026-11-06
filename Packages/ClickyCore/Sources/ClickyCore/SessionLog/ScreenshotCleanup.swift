import Foundation

/// Decides which screenshot groups to keep when a session stops.
public enum ScreenshotCleanup {
    /// Walks the groups in time order and, for each one, keeps it when:
    /// (a) it is a question's screenshot or a question sent it as an earlier-moment shot,
    /// (b) it is the first group of a visit (a run of groups with the same app and window title),
    /// (c) it differs from the last kept group by at least `nearDuplicateThreshold`.
    /// Everything else looks almost the same as a kept screenshot and is deleted.
    /// Both lists come back in time order.
    public static func select(
        shotGroups: [ShotGroup],
        questionLinkedGroupIDs: Set<Int>,
        nearDuplicateThreshold: Double = 0.10
    ) -> (keep: [Int], delete: [Int]) {
        let groupsInTimeOrder = shotGroups.sorted { left, right in
            if left.capturedAt != right.capturedAt { return left.capturedAt < right.capturedAt }
            return left.id < right.id
        }

        var keptIDs: [Int] = []
        var deletedIDs: [Int] = []
        var lastKeptGroup: ShotGroup?
        var previousGroup: ShotGroup?

        for group in groupsInTimeOrder {
            let isFirstOfVisit = previousGroup.map {
                $0.appName != group.appName || $0.windowTitle != group.windowTitle
            } ?? true
            previousGroup = group

            let mustKeep = group.reason == .question
                || questionLinkedGroupIDs.contains(group.id)
                || isFirstOfVisit
            let differsEnough = lastKeptGroup.map {
                maximumThumbnailDifference(from: $0, to: group) >= nearDuplicateThreshold
            } ?? true

            if mustKeep || differsEnough {
                keptIDs.append(group.id)
                lastKeptGroup = group
            } else {
                deletedIDs.append(group.id)
            }
        }
        return (keptIDs, deletedIDs)
    }

    /// Largest mean absolute grayscale difference (0...1) over displays matched by screen number.
    /// A different display count, an unmatched screen or a different thumbnail size counts as 1.0.
    /// Private on purpose: the capture slice has its own copy as `ShotGroup.maximumDifference(from:)`.
    private static func maximumThumbnailDifference(from earlier: ShotGroup, to later: ShotGroup) -> Double {
        guard earlier.shots.count == later.shots.count else { return 1.0 }

        var largestDifference = 0.0
        for laterShot in later.shots {
            guard let earlierShot = earlier.shots.first(where: { $0.screenNumber == laterShot.screenNumber }) else {
                return 1.0
            }
            let earlierBytes = earlierShot.thumbnail.grayscaleBytes
            let laterBytes = laterShot.thumbnail.grayscaleBytes
            guard earlierBytes.count == laterBytes.count,
                  earlierShot.thumbnail.width == laterShot.thumbnail.width,
                  earlierShot.thumbnail.height == laterShot.thumbnail.height else { return 1.0 }
            guard !laterBytes.isEmpty else { continue }

            var totalAbsoluteDifference = 0
            for index in laterBytes.indices {
                totalAbsoluteDifference += abs(Int(earlierBytes[index]) - Int(laterBytes[index]))
            }
            let meanDifference = Double(totalAbsoluteDifference) / Double(laterBytes.count) / 255.0
            largestDifference = max(largestDifference, meanDifference)
        }
        return largestDifference
    }
}
