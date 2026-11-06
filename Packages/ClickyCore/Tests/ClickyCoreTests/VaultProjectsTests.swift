import Foundation
import Testing
@testable import ClickyCore

struct VaultProjectsTests {
    @Test func listsOnlyMarkdownProjectSlugsSorted() throws {
        let vault = try VaultTestSupport.makeVault(withGit: false)
        #expect(VaultProjects.list(vaultRoot: vault) == ["clicky-fork", "homelab", "meetily-fork"])
    }

    @Test func missingProjectsFolderGivesEmptyList() throws {
        let empty = try VaultTestSupport.makeTempFolder()
        #expect(VaultProjects.list(vaultRoot: empty) == [])
    }

    @Test func suggestsProjectByTitleWords() throws {
        let vault = try VaultTestSupport.makeVault(withGit: false)
        let suggestion = VaultProjects.suggest(
            vaultRoot: vault, title: "Fix Clicky signing", summary: nil, questions: [], appNames: [])
        #expect(suggestion == "clicky-fork")
    }

    @Test func suggestsNothingForUnrelatedTitle() throws {
        let vault = try VaultTestSupport.makeVault(withGit: false)
        let suggestion = VaultProjects.suggest(
            vaultRoot: vault, title: "Lunch", summary: nil, questions: [], appNames: [])
        #expect(suggestion == nil)
    }

    @Test func questionAndAppWordsCountLessThanTitleButStillSuggest() throws {
        let vault = try VaultTestSupport.makeVault(withGit: false)
        // "homelab" appears once in a question: weight 1 x score 3 = 3, which meets the minimum of 3.
        let suggestion = VaultProjects.suggest(
            vaultRoot: vault, title: "Lunch", summary: nil,
            questions: ["why is the homelab router slow"], appNames: ["Safari"])
        #expect(suggestion == "homelab")
    }
}
