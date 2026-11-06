import Foundation

/// Text that seeds a fresh conversation with what was said before.
public enum RecapBuilder {
    static let header = "Recap of this session so far (screenshots not included):\n"

    public static func recap(
        exchanges: [(question: String, answer: String)],
        maximumCharacters: Int = 2000
    ) -> String? {
        guard !exchanges.isEmpty else { return nil }

        var blocks = exchanges.map { exchange in
            "Q: \(exchange.question)\nA: \(PointTagParser.parse(exchange.answer).spokenText)"
        }
        func total() -> Int { header.count + blocks.joined(separator: "\n").count }

        while blocks.count > 1 && total() > maximumCharacters {
            blocks.removeFirst()
        }
        if total() > maximumCharacters, let only = blocks.first {
            let room = max(0, maximumCharacters - header.count - 3)
            blocks = [String(only.prefix(room)) + "..."]
        }
        return header + blocks.joined(separator: "\n")
    }
}
