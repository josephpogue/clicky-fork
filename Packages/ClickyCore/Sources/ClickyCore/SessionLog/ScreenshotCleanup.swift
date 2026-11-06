import Foundation

/// Decides which screenshot groups to keep when a session stops.
public enum ScreenshotCleanup {
    /// Walks the groups in time order and, for each one, keeps it when:
    /// (a) it is a question's screenshot or a question sent it as an earlier-moment shot,
    /// (b) it is the first group of a visit (a run of groups with the same app and window title),
    /// (c) it differs from the last kept group by at least `nearDuplicateThreshold`,
    /// (d) it was taken `longStretchSeconds` or more after the last kept group, which keeps one
    ///     shot per long stretch on one screen. A kept question shot restarts that clock like any other kept shot.
    /// Everything else looks almost the same as a kept screenshot and is deleted.
    /// Both lists come back in time order.
    public static func select(
        shotGroups: [ShotGroup],
        questionLinkedGroupIDs: Set<Int>,
        nearDuplicateThreshold: Double = 0.10,
        longStretchSeconds: Double = 300
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
                group.maximumDifference(from: $0) >= nearDuplicateThreshold
            } ?? true
            let isLongStretchLater = lastKeptGroup.map {
                group.capturedAt.timeIntervalSince($0.capturedAt) >= longStretchSeconds
            } ?? true

            if mustKeep || differsEnough || isLongStretchLater {
                keptIDs.append(group.id)
                lastKeptGroup = group
            } else {
                deletedIDs.append(group.id)
            }
        }
        return (keptIDs, deletedIDs)
    }
}
