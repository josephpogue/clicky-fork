//
//  BrainIndexService.swift
//  leanring-buddy
//
//  Keeps the brain index for the search folders in Settings and answers the question flow's passage lookups.
//  Owned by the app-settings-index slice. Foundation stub: the brain is always off.
//

import ClickyCore
import Foundation

final class BrainIndexService: @unchecked Sendable {
    static let shared = BrainIndexService()

    /// True when Settings lists at least one search folder.
    var isBrainOn: Bool { false }

    /// Builds or refreshes the index off the main thread: at launch, at session Start and when the folder list changes.
    func refreshInBackground() {}

    /// The passages for one question; empty while the brain is off or nothing clears the floor.
    func passages(forQuestion question: String, frontAppName: String?, frontWindowTitle: String?) async -> [BrainPassage] {
        []
    }

    /// How a provider starts the helper; nil while the brain is off or the helper is missing from the bundle.
    func toolServer() -> BrainToolServer? { nil }

    /// The maps the instructions name: the knowledge base index under the notes folder and any indexed `registry.md`.
    func mapPaths() async -> [String] { [] }
}
