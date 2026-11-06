import Foundation
import Testing
@testable import ClickyCore

struct VaultNamingTests {
    private let utc = TimeZone(identifier: "UTC")!

    @Test func resolverPrefersEnvironmentOverSetting() {
        let url = VaultRootResolver.resolve(
            notesFolderSetting: "/from/setting", environment: ["CLICKY_VAULT_ROOT": "/from/env"])
        #expect(url?.path == "/from/env")
    }

    @Test func resolverUsesSettingAndExpandsTilde() {
        let url = VaultRootResolver.resolve(notesFolderSetting: "~/Notes", environment: [:])
        #expect(url?.path == NSString(string: "~/Notes").expandingTildeInPath)
    }

    @Test func resolverGivesNilWhenNothingIsSet() {
        #expect(VaultRootResolver.resolve(notesFolderSetting: nil, environment: [:]) == nil)
        #expect(VaultRootResolver.resolve(notesFolderSetting: "  ", environment: [:]) == nil)
    }

    @Test func dryRunFlagReadsEnvironment() {
        #expect(VaultRootResolver.isDryRun(environment: ["CLICKY_VAULT_DRY_RUN": "1"]))
        #expect(!VaultRootResolver.isDryRun(environment: ["CLICKY_VAULT_DRY_RUN": "0"]))
        #expect(!VaultRootResolver.isDryRun(environment: [:]))
    }

    @Test func titleIsFirstSentenceOfSummary() {
        let made = SessionNoteTitle.make(
            summary: "Fixed the Xcode signing error. Then rebuilt.", firstQuestion: "ignored",
            startedAt: Date(timeIntervalSince1970: 0), timeZone: utc)
        #expect(made.title == "Fixed the Xcode signing error")
        #expect(made.slug == "fixed-the-xcode-signing-error")
    }

    @Test func titleFallsBackToQuestionCutAtWordBoundary() {
        // The question is 72 characters; characters 1 to 60 are
        // "how do I make the sidebar in this app stay open when I resiz" (cut mid-word "resize"),
        // so the cut backs up to the last space: "how do I make the sidebar in this app stay open when I".
        let question = "how do I make the sidebar in this app stay open when I resize the window"
        let made = SessionNoteTitle.make(
            summary: nil, firstQuestion: question, startedAt: Date(timeIntervalSince1970: 0), timeZone: utc)
        #expect(made.title == "how do I make the sidebar in this app stay open when I")
        #expect(made.title.count <= 60)
    }

    @Test func titleFallsBackToClockTime() {
        // 14:05 UTC on 1970-01-01 is 14 * 3600 + 5 * 60 = 50700 seconds.
        let made = SessionNoteTitle.make(
            summary: nil, firstQuestion: nil, startedAt: Date(timeIntervalSince1970: 50700), timeZone: utc)
        #expect(made.title == "Session 14:05")
        #expect(made.slug == "session-14-05")
    }

    @Test func slugIsCappedAtFiftyCharactersWithoutTrailingHyphen() {
        let made = SessionNoteTitle.make(
            summary: "alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo",
            firstQuestion: nil, startedAt: Date(timeIntervalSince1970: 0), timeZone: utc)
        #expect(made.slug.count <= 50)
        #expect(!made.slug.hasSuffix("-"))
        #expect(made.slug.hasPrefix("alpha-bravo-charlie-delta-echo-foxtrot-golf"))
    }
}
