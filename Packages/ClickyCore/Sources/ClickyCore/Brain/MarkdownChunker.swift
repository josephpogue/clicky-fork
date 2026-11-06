import Foundation

/// One searchable piece of a file.
struct BrainChunk: Equatable {
    var title: String
    var heading: String?
    /// 1-based, inclusive
    var startLine: Int
    var endLine: Int
    /// The chunk's lines exactly as in the file (the heading line included), so the line numbers match the text.
    var body: String
}

/// Splits a note into chunks at markdown headings, or a plain text file at blank lines.
enum MarkdownChunker {
    /// Pieces longer than this many lines are cut at a blank line.
    static let maximumLinesPerChunk = 60

    static func chunks(text: String, fileName: String, isMarkdown: Bool) -> [BrainChunk] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            // Windows line endings must not leave a stray carriage return in the text
            line.hasSuffix("\r") ? String(line.dropLast()) : String(line)
        }
        let fileNameWithoutExtension = (fileName as NSString).deletingPathExtension
        guard isMarkdown else {
            return splitRegion(
                lines: lines, firstLineIndex: 0, endLineIndex: lines.count, title: fileNameWithoutExtension, heading: nil)
        }

        let headings = findHeadings(in: lines)
        let title = headings.first(where: { $0.level == 1 })?.text ?? fileNameWithoutExtension
        var chunks: [BrainChunk] = []

        // Text before the first heading (front matter included) is the first chunk, with no heading.
        let firstHeadingLineIndex = headings.first?.lineIndex ?? lines.count
        let frontMatterEndLineIndex = frontMatterEnd(in: lines)
        let preambleIsOnlyFrontMatter =
            !headings.isEmpty && frontMatterEndLineIndex > 0
            && lines[frontMatterEndLineIndex..<firstHeadingLineIndex].allSatisfy(isBlank)
        // Front matter that only precedes a heading joins that heading's chunk (it describes that note).
        let mergedFrontMatter = preambleIsOnlyFrontMatter
        if !mergedFrontMatter {
            chunks += splitRegion(
                lines: lines, firstLineIndex: 0, endLineIndex: firstHeadingLineIndex, title: title, heading: nil)
        }

        for headingNumber in 0..<headings.count {
            let heading = headings[headingNumber]
            let regionEnd = headingNumber + 1 < headings.count ? headings[headingNumber + 1].lineIndex : lines.count
            let regionStart = (headingNumber == 0 && mergedFrontMatter) ? 0 : heading.lineIndex
            let regionChunks = splitRegion(
                lines: lines, firstLineIndex: regionStart, endLineIndex: regionEnd, title: title, heading: heading.text)
            // A heading with nothing under it (only its own line) would match on its title alone and say nothing.
            let hasContentBeyondHeading = regionChunks.contains { chunk in
                chunk.body.split(separator: "\n").contains { line in
                    !isBlank(String(line)) && !isHeadingLine(String(line))
                }
            }
            if hasContentBeyondHeading || (headings.count == 1 && chunks.isEmpty) {
                chunks += regionChunks
            }
        }
        return chunks
    }

    // MARK: Headings

    private struct Heading {
        var lineIndex: Int
        var level: Int
        var text: String
    }

    private static func isBlank(_ line: String) -> Bool {
        line.allSatisfy { $0 == " " || $0 == "\t" }
    }

    private static func isHeadingLine(_ line: String) -> Bool {
        parseHeading(line) != nil
    }

    /// `#` to `######` at line start, followed by a space.
    private static func parseHeading(_ line: String) -> (level: Int, text: String)? {
        var level = 0
        for character in line {
            if character == "#" { level += 1 } else { break }
            if level > 6 { return nil }
        }
        guard level >= 1 else { return nil }
        let afterHashes = line.dropFirst(level)
        guard afterHashes.first == " " || afterHashes.first == "\t" else { return nil }
        var headingText = afterHashes.trimmingCharacters(in: .whitespaces)
        // Closing hashes: `## Ports ##`
        while headingText.hasSuffix("#") { headingText.removeLast() }
        headingText = headingText.trimmingCharacters(in: .whitespaces)
        return headingText.isEmpty ? nil : (level, headingText)
    }

    /// Headings outside fenced code blocks and outside front matter.
    private static func findHeadings(in lines: [String]) -> [Heading] {
        var headings: [Heading] = []
        var openFenceMarker: Character?
        var lineIndex = frontMatterEnd(in: lines)
        while lineIndex < lines.count {
            let line = lines[lineIndex]
            let trimmedLine = line.drop(while: { $0 == " " })
            if let marker = trimmedLine.first, marker == "`" || marker == "~", trimmedLine.prefix(3).allSatisfy({ $0 == marker }), trimmedLine.count >= 3 {
                if openFenceMarker == nil {
                    openFenceMarker = marker
                } else if openFenceMarker == marker {
                    openFenceMarker = nil
                }
            } else if openFenceMarker == nil, let parsed = parseHeading(line) {
                headings.append(Heading(lineIndex: lineIndex, level: parsed.level, text: parsed.text))
            }
            lineIndex += 1
        }
        return headings
    }

    /// The index just after a closing `---` when the file opens with a front matter block, else 0.
    private static func frontMatterEnd(in lines: [String]) -> Int {
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return 0 }
        var lineIndex = 1
        while lineIndex < lines.count {
            let trimmedLine = lines[lineIndex].trimmingCharacters(in: .whitespaces)
            if trimmedLine == "---" || trimmedLine == "..." { return lineIndex + 1 }
            lineIndex += 1
        }
        return 0
    }

    // MARK: Splitting long regions

    /// Cuts lines `firstLineIndex..<endLineIndex` into pieces under the line limit, preferring blank lines as cut
    /// points. Leading and trailing blank lines are trimmed off each piece, and empty pieces are dropped.
    private static func splitRegion(
        lines: [String], firstLineIndex: Int, endLineIndex: Int, title: String, heading: String?
    ) -> [BrainChunk] {
        var chunks: [BrainChunk] = []
        var pieceStart = firstLineIndex
        while pieceStart < endLineIndex {
            var pieceEnd = min(pieceStart + maximumLinesPerChunk, endLineIndex)
            if pieceEnd < endLineIndex {
                // Walk back to the last blank line inside the piece so the cut falls between paragraphs.
                var cutCandidate = pieceEnd - 1
                while cutCandidate > pieceStart && !isBlank(lines[cutCandidate]) { cutCandidate -= 1 }
                if cutCandidate > pieceStart { pieceEnd = cutCandidate + 1 }
            }
            var trimmedStart = pieceStart
            var trimmedEnd = pieceEnd
            while trimmedStart < trimmedEnd && isBlank(lines[trimmedStart]) { trimmedStart += 1 }
            while trimmedEnd > trimmedStart && isBlank(lines[trimmedEnd - 1]) { trimmedEnd -= 1 }
            if trimmedStart < trimmedEnd {
                chunks.append(
                    BrainChunk(
                        title: title, heading: heading, startLine: trimmedStart + 1, endLine: trimmedEnd,
                        body: lines[trimmedStart..<trimmedEnd].joined(separator: "\n")))
            }
            pieceStart = pieceEnd
        }
        return chunks
    }
}
