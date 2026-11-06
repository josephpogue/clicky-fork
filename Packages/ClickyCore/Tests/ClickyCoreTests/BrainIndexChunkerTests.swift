import Testing

@testable import ClickyCore

@Suite("MarkdownChunker and query words")
struct BrainIndexChunkerTests {
    @Test func splitsAtHeadingsWithTitleAndLines() {
        let text = "# Title\n\nIntro text.\n\n## Alpha\n\nalpha body\n\n### Beta\n\nbeta body\n"
        let chunks = MarkdownChunker.chunks(text: text, fileName: "x.md", isMarkdown: true)
        #expect(chunks.map(\.heading) == ["Title", "Alpha", "Beta"])
        #expect(chunks.allSatisfy { $0.title == "Title" })
        #expect(chunks.map(\.startLine) == [1, 5, 9])
        #expect(chunks.map(\.endLine) == [3, 7, 11])
    }

    @Test func fileNameIsTheTitleWithoutAnH1() {
        let chunks = MarkdownChunker.chunks(text: "## Build\n\nrun it\n", fileName: "notes.md", isMarkdown: true)
        #expect(chunks.count == 1)
        #expect(chunks[0].title == "notes")
        #expect(chunks[0].heading == "Build")
    }

    @Test func headingsInsideCodeFencesAreText() {
        let text = "# Doc\n\n```\n# not a heading\n```\n\n## Real\n\nbody\n"
        let chunks = MarkdownChunker.chunks(text: text, fileName: "x.md", isMarkdown: true)
        #expect(chunks.map(\.heading) == ["Doc", "Real"])
        #expect(chunks[0].body.contains("# not a heading"))
    }

    @Test func frontMatterJoinsTheFirstChunkAndHidesItsHashes() {
        let text = "---\ntitle: x\n# comment\n---\n# Heading\n\nbody\n"
        let chunks = MarkdownChunker.chunks(text: text, fileName: "x.md", isMarkdown: true)
        #expect(chunks.count == 1)
        #expect(chunks[0].startLine == 1)
        #expect(chunks[0].body.hasPrefix("---\ntitle: x"))
        #expect(chunks[0].heading == "Heading")
    }

    @Test func textBeforeTheFirstHeadingHasNoHeading() {
        let chunks = MarkdownChunker.chunks(text: "preface line\n\n# Title\n\nbody\n", fileName: "x.md", isMarkdown: true)
        #expect(chunks.map(\.heading) == [nil, "Title"])
    }

    @Test func longSectionsSplitAtBlankLinesAndKeepTheHeading() {
        let paragraph = (0..<25).map { "line \($0)" }.joined(separator: "\n")
        let text = "## Long\n\n" + [paragraph, paragraph, paragraph, paragraph].joined(separator: "\n\n") + "\n"
        let chunks = MarkdownChunker.chunks(text: text, fileName: "x.md", isMarkdown: true)
        #expect(chunks.count >= 2)
        #expect(chunks.allSatisfy { $0.heading == "Long" })
        #expect(chunks.allSatisfy { $0.endLine - $0.startLine + 1 <= MarkdownChunker.maximumLinesPerChunk })
        // Nothing lost: every paragraph is in some chunk
        #expect(chunks.map(\.body).joined().components(separatedBy: "line 24").count - 1 == 4)
    }

    @Test func plainTextSplitsByParagraphWithoutHeading() {
        let paragraph = (0..<40).map { "row \($0)" }.joined(separator: "\n")
        let chunks = MarkdownChunker.chunks(text: paragraph + "\n\n" + paragraph + "\n", fileName: "list.txt", isMarkdown: false)
        #expect(chunks.count == 2)
        #expect(chunks.allSatisfy { $0.heading == nil && $0.title == "list" })
    }

    @Test func emptyChunksAreDropped() {
        #expect(MarkdownChunker.chunks(text: "\n\n  \n", fileName: "x.md", isMarkdown: true).isEmpty)
        #expect(MarkdownChunker.chunks(text: "", fileName: "x.txt", isMarkdown: false).isEmpty)
    }

    @Test func queryWordsDropStopWordsAndShortWords() {
        #expect(BrainSearchQuery.meaningfulWords(in: "What port does the demo-server use?") == ["port", "demo", "server", "use"])
        #expect(BrainSearchQuery.matchExpression(for: "the a I") == nil)
        #expect(BrainSearchQuery.matchExpression(for: "port\" OR *") == "\"port\"")
    }

    @Test func projectNamesMatchWholeWordsWithDashesAsSpaces() {
        #expect(BrainProjectBoost.windowText("clicky fork - SessionCoordinator.swift", mentions: "clicky-fork"))
        #expect(BrainProjectBoost.windowText("clicky-fork - Package.swift", mentions: "Clicky_Fork"))
        #expect(!BrainProjectBoost.windowText("clicky-forklift", mentions: "clicky-fork"))
        #expect(!BrainProjectBoost.windowText("", mentions: "clicky-fork"))
        #expect(BrainProjectBoost.path("/a/Wiki/Projects/clicky-fork.md", belongsTo: "clicky-fork"))
        #expect(BrainProjectBoost.path("/a/projects/clicky-fork/docs/n.md", belongsTo: "clicky-fork"))
        #expect(!BrainProjectBoost.path("/a/Wiki/Other/clicky-fork.md", belongsTo: "clicky-fork"))
    }
}
