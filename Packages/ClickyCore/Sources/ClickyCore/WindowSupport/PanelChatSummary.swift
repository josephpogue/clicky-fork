import Foundation

/// The words on the menu-bar panel's Open chat row: how many answers the
/// conversation holds and the start of the last one. Cutting a long line to
/// the row's width is the view's job (one line, tail ellipsis).
public enum PanelChatSummary {
    /// "1 answer" or "3 answers"; nil with no answers.
    public static func countText(answerCount: Int) -> String? {
        guard answerCount > 0 else { return nil }
        return answerCount == 1 ? "1 answer" : "\(answerCount) answers"
    }

    /// "Last: <text>" with newlines and whitespace runs collapsed to single
    /// spaces; nil when there is no text.
    public static func lastLine(lastAnswerText: String?) -> String? {
        guard let collapsed = collapsed(lastAnswerText), !collapsed.isEmpty else { return nil }
        return "Last: " + collapsed
    }

    /// The row's accessibility value: "3 answers. Last: <full text>", empty with no answers.
    public static func accessibilityValue(answerCount: Int, lastAnswerText: String?) -> String {
        guard let count = countText(answerCount: answerCount) else { return "" }
        guard let last = lastLine(lastAnswerText: lastAnswerText) else { return count }
        return count + ". " + last
    }

    private static func collapsed(_ text: String?) -> String? {
        guard let text else { return nil }
        return text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
