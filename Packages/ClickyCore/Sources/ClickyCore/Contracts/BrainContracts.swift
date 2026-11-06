import Foundation

/// One piece of a note found by the brain search: where it is and the lines it holds.
public struct BrainPassage: Sendable, Equatable {
    /// Absolute path of the file, after resolving symlinks
    public var path: String
    /// The markdown heading the chunk sits under, nil for text before the first heading or in a plain text file
    public var heading: String?
    /// 1-based, inclusive
    public var startLine: Int
    public var endLine: Int
    public var text: String
    /// Higher is better. Only comparable between passages from the same search.
    public var score: Double

    public init(path: String, heading: String?, startLine: Int, endLine: Int, text: String, score: Double) {
        self.path = path
        self.heading = heading
        self.startLine = startLine
        self.endLine = endLine
        self.text = text
        self.score = score
    }
}

/// Lines of one file returned by `read_brain_file`.
public struct BrainFileExcerpt: Sendable, Equatable {
    /// Absolute path after resolving symlinks
    public var path: String
    /// 1-based line number of the first returned line
    public var startLine: Int
    public var lines: [String]
    public var totalLineCount: Int
    /// True when the per-call cap cut the excerpt short of what was asked
    public var wasCappedByLimit: Bool

    public init(path: String, startLine: Int, lines: [String], totalLineCount: Int, wasCappedByLimit: Bool) {
        self.path = path
        self.startLine = startLine
        self.lines = lines
        self.totalLineCount = totalLineCount
        self.wasCappedByLimit = wasCappedByLimit
    }
}

/// Why `read_brain_file` refused a path. The text the model sees is built by the helper from this.
public enum BrainFileRefusal: Error, Sendable, Equatable {
    case outsideSearchFolders
    case neverReadable
    case notFound
    case notText
}

/// The two read-only tools, by the names the model sees.
public enum BrainToolName: String, Sendable, Equatable, CaseIterable {
    case searchBrain = "search_brain"
    case readBrainFile = "read_brain_file"

    /// The MCP server name both providers register the helper under.
    public static let serverName = "brain"

    /// The name Claude Code gives an MCP tool: `mcp__<server>__<tool>`.
    public var claudeToolName: String { "mcp__\(Self.serverName)__\(rawValue)" }
}

/// One brain tool call the model made, as the log and the repeat guard see it.
public struct BrainToolCall: Sendable, Equatable {
    public var tool: BrainToolName
    /// The query for `search_brain`, the path for `read_brain_file`
    public var argument: String
    /// Every argument as compact JSON with sorted keys, so two calls compare equal only when all arguments match
    public var argumentsFingerprint: String

    public init(tool: BrainToolName, argument: String, argumentsFingerprint: String) {
        self.tool = tool
        self.argument = argument
        self.argumentsFingerprint = argumentsFingerprint
    }
}

/// How a provider starts the helper program that serves the two brain tools over MCP (stdio).
/// Nil wherever it is passed means the brain is off and the provider runs exactly as before.
public struct BrainToolServer: Sendable, Equatable {
    public var executableURL: URL
    public var arguments: [String]

    public init(executableURL: URL, arguments: [String]) {
        self.executableURL = executableURL
        self.arguments = arguments
    }

    /// The helper's command line: `--index <database> --folder <a> --folder <b> ...`.
    public static func helperArguments(indexDatabaseURL: URL, searchFolders: [URL]) -> [String] {
        var arguments = ["--index", indexDatabaseURL.path]
        for folder in searchFolders {
            arguments += ["--folder", folder.path]
        }
        return arguments
    }
}

/// The text shape of the helper's tool results that the app reads back: every passage or excerpt begins
/// with one line `File: <absolute path>` (optionally followed by ` lines <a>-<b>`), so the provider can tell
/// which notes the model looked at without parsing anything else.
public enum BrainToolText {
    public static let fileLinePrefix = "File: "

    public static func fileLine(path: String, startLine: Int, endLine: Int) -> String {
        "\(fileLinePrefix)\(path) lines \(startLine)-\(endLine)"
    }

    /// Paths named on `File: ` lines, in order, without repeats.
    public static func paths(inToolResult text: String) -> [String] {
        var seen: Set<String> = []
        var paths: [String] = []
        for rawLine in text.components(separatedBy: "\n") {
            guard rawLine.hasPrefix(fileLinePrefix) else { continue }
            var path = String(rawLine.dropFirst(fileLinePrefix.count))
            if let linesRange = path.range(of: " lines ", options: .backwards) {
                path = String(path[..<linesRange.lowerBound])
            }
            path = path.trimmingCharacters(in: .whitespaces)
            if !path.isEmpty, seen.insert(path).inserted {
                paths.append(path)
            }
        }
        return paths
    }
}

/// What the helper's tools are backed by. The helper wires the real index and reader; tests use a fake.
public protocol BrainToolBackend: Sendable {
    func search(query: String, limit: Int) throws -> [BrainPassage]
    func readFile(path: String, startLine: Int, lineCount: Int) throws -> BrainFileExcerpt
}

/// How hard the model thinks for one question. Nil in `AnswerRequest` means the provider's normal setting.
public enum AnswerEffort: String, Sendable, Equatable, CaseIterable {
    case low, medium, high
}

/// The model and effort for one question. Dig deeper sends a stronger pair for that question only.
public struct AnswerRequest: Sendable, Equatable {
    public var model: String
    public var effort: AnswerEffort?

    public init(model: String, effort: AnswerEffort? = nil) {
        self.model = model
        self.effort = effort
    }
}

/// What a provider reports while an answer is still coming.
public enum AnswerProgress: Sendable, Equatable {
    /// The whole raw answer text so far (POINT tag and all). Each report replaces the last one.
    case textSoFar(String)
    /// The model began a brain tool call; its arguments may not be known yet. Sent as early as the stream allows.
    case toolCallStarted(BrainToolName)
    /// A brain tool call with its full arguments.
    case toolCallMade(BrainToolCall)
    /// A brain tool call came back; `paths` are the files its result named (`BrainToolText.paths`).
    case toolCallFinished(BrainToolCall, paths: [String], resultCharacterCount: Int)
}
