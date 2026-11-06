import Foundation

/// How the line under the search folders in Settings looks; the app maps it to the designer's status kinds.
public enum BrainServiceStatusKind: Sendable, Equatable {
    case ready
    case working
    case problem
}

/// The text of that line: "Indexing...", "1,284 notes indexed" or "Could not read ~/notes".
public struct BrainServiceStatus: Sendable, Equatable {
    public var text: String
    public var kind: BrainServiceStatusKind

    public init(text: String, kind: BrainServiceStatusKind) {
        self.text = text
        self.kind = kind
    }

    /// Nil shows no line: no folders, or nothing has finished yet and nothing is running.
    public static func make(
        hasFolders: Bool,
        isRefreshing: Bool,
        lastSummary: BrainIndexUpdateSummary?,
        firstUnreadableFolderPath: String?,
        homeDirectory: URL,
        locale: Locale = .current
    ) -> BrainServiceStatus? {
        guard hasFolders else { return nil }
        if isRefreshing { return BrainServiceStatus(text: "Indexing...", kind: .working) }
        if let unreadablePath = firstUnreadableFolderPath {
            let shownPath = BrainServiceFolders.abbreviated(path: unreadablePath, homeDirectory: homeDirectory)
            return BrainServiceStatus(text: "Could not read \(shownPath)", kind: .problem)
        }
        guard let lastSummary else { return nil }
        let noteCount = lastSummary.filesIndexed + lastSummary.filesUnchanged
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = locale
        let countText = formatter.string(from: NSNumber(value: noteCount)) ?? String(noteCount)
        let noun = noteCount == 1 ? "note" : "notes"
        return BrainServiceStatus(text: "\(countText) \(noun) indexed", kind: .ready)
    }
}
