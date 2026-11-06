import Foundation
import Testing
@testable import ClickyCore

/// Which folders may be search folders. Every folder is a temp folder standing in for the home folder.
struct BrainServiceFolderBoundaryTests {
    private func makeHome() throws -> (outer: URL, home: URL) {
        let outer = FileManager.default.temporaryDirectory.appendingPathComponent("svc-folders-\(UUID().uuidString)")
        let home = outer.appendingPathComponent("Users/joe")
        for folder in ["brain/wiki", ".claude/routing", "Documents/notes", "Library/Mail"] {
            try FileManager.default.createDirectory(
                at: home.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        return (outer, home)
    }

    @Test("a folder that contains the home folder is refused, with a reason")
    func foldersContainingHomeAreRefused() throws {
        let (outer, home) = try makeHome()
        defer { try? FileManager.default.removeItem(at: outer) }
        for containing in [home.deletingLastPathComponent(), outer] {
            #expect(BrainServiceFolders.refusalReason(for: containing, homeDirectory: home) != nil, "\(containing.path)")
        }
        let reason = BrainServiceFolders.refusalReason(for: home.deletingLastPathComponent(), homeDirectory: home)
        #expect(reason?.isEmpty == false)
    }

    @Test("the Library folder and anything inside it is refused, even when it does not exist")
    func libraryIsRefused() throws {
        let (outer, home) = try makeHome()
        defer { try? FileManager.default.removeItem(at: outer) }
        for relativePath in ["Library", "Library/Mail", "Library/Mail/V10", "Library/Missing/Deep"] {
            let folder = home.appendingPathComponent(relativePath)
            #expect(BrainServiceFolders.refusalReason(for: folder, homeDirectory: home) != nil, "\(relativePath)")
        }
        let alias = outer.appendingPathComponent("lib-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: home.appendingPathComponent("Library"))
        #expect(BrainServiceFolders.refusalReason(for: alias, homeDirectory: home) != nil)
    }

    @Test("brain, wiki, routing and a notes folder stay allowed, and so does a sibling named like Library")
    func ordinaryFoldersStayAllowed() throws {
        let (outer, home) = try makeHome()
        defer { try? FileManager.default.removeItem(at: outer) }
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("LibraryNotes"), withIntermediateDirectories: true)
        for relativePath in ["brain", "brain/wiki", ".claude/routing", "Documents/notes", "LibraryNotes"] {
            let folder = home.appendingPathComponent(relativePath)
            #expect(BrainServiceFolders.refusalReason(for: folder, homeDirectory: home) == nil, "\(relativePath)")
        }
    }
}
