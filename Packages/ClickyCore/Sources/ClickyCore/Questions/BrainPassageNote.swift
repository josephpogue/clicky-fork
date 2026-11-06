import Foundation

/// The note that carries found passages with a question. Built here so both providers send the same words.
public enum BrainPassageNote {
    /// Empty for no passages, so a screen-only question carries nothing extra.
    public static func text(for passages: [BrainPassage]) -> String {
        guard !passages.isEmpty else { return "" }
        var blocks: [String] = []
        for index in 0..<passages.count {
            let passage = passages[index]
            var lines = [BrainToolText.fileLine(path: passage.path, startLine: passage.startLine, endLine: passage.endLine)]
            if let heading = passage.heading, !heading.isEmpty { lines.append("Heading: \(heading)") }
            var passageText = passage.text
            while passageText.last == "\n" || passageText.last == "\r" { passageText.removeLast() }
            lines.append(passageText)
            blocks.append(lines.joined(separator: "\n"))
        }
        let intro = "Notes from the user's own files that may help. Use them only where they answer the question:"
        return intro + "\n\n" + blocks.joined(separator: "\n\n")
    }
}
