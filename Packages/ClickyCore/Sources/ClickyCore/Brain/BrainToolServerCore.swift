import Foundation

/// The JSON-RPC (MCP) side of the brain helper, over a `BrainToolBackend`. It maps one input line to one output line,
/// so tests drive it without a process. It serves exactly two read-only tools and nothing else.
public struct BrainToolServerCore: Sendable {
    private let backend: BrainToolBackend

    public static let defaultProtocolVersion = "2025-06-18"
    private static let supportedProtocolVersions: Set<String> = ["2025-06-18", "2025-03-26", "2024-11-05"]
    private static let searchLimitRange = 1...20
    private static let defaultSearchLimit = 8
    private static let startLineRange = 1...1_000_000_000
    private static let lineCountRange = 1...BrainFileReader.maximumLinesPerCall
    private static let indexNotReadyText =
        "The notes index is not ready yet. Answer from the screen and say the notes could not be searched."

    public init(backend: BrainToolBackend) {
        self.backend = backend
    }

    /// The reply line for one request line, or nil for a notification (a request without an `id`).
    public func response(toLine line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) else {
            return Self.encode(errorReply(id: NSNull(), code: -32700, message: "Parse error"))
        }
        guard let request = parsed as? [String: Any] else {
            return Self.encode(errorReply(id: NSNull(), code: -32600, message: "Invalid request"))
        }
        // A notification carries no id and never gets a reply, whatever its method.
        guard let requestId = request["id"] else { return nil }
        let method = request["method"] as? String ?? ""
        let params = request["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            let askedVersion = params["protocolVersion"] as? String ?? ""
            let version = Self.supportedProtocolVersions.contains(askedVersion) ? askedVersion : Self.defaultProtocolVersion
            return Self.encode(resultReply(id: requestId, result: [
                "protocolVersion": version,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": BrainToolName.serverName, "version": "1"],
            ]))
        case "ping":
            return Self.encode(resultReply(id: requestId, result: [String: Any]()))
        case "tools/list":
            return Self.encode(resultReply(id: requestId, result: ["tools": Self.toolDescriptions()]))
        case "tools/call":
            let toolName = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let outcome = callTool(named: toolName, arguments: arguments)
            return Self.encode(resultReply(id: requestId, result: [
                "content": [["type": "text", "text": outcome.text]],
                "isError": outcome.isError,
            ]))
        default:
            return Self.encode(errorReply(id: requestId, code: -32601, message: "Method not found"))
        }
    }

    // MARK: tools

    private func callTool(named toolName: String, arguments: [String: Any]) -> (text: String, isError: Bool) {
        switch BrainToolName(rawValue: toolName) {
        case .searchBrain:
            return searchBrain(arguments: arguments)
        case .readBrainFile:
            return readBrainFile(arguments: arguments)
        case nil:
            return ("Unknown tool \(toolName). The tools are search_brain and read_brain_file.", true)
        }
    }

    private func searchBrain(arguments: [String: Any]) -> (text: String, isError: Bool) {
        guard let query = arguments["query"] as? String, !query.isEmpty else {
            return ("search_brain needs a query.", true)
        }
        let parsedLimit: Int?
        do { parsedLimit = try Self.optionalInteger(named: "limit", in: arguments) } catch let problem as NumberArgumentProblem {
            return (problem.message, true)
        } catch { return (Self.indexNotReadyText, true) }
        let limit = Self.clamped(parsedLimit ?? Self.defaultSearchLimit, to: Self.searchLimitRange)
        do {
            let passages = try backend.search(query: query, limit: limit)
            if passages.isEmpty {
                return ("No notes matched \"\(query)\". Try other words, or read a map file.", false)
            }
            var blocks: [String] = []
            for passage in passages {
                // A passage with no path is the backend's own note (notes still being indexed), not a file: no File line.
                var blockLines = passage.path.isEmpty
                    ? [] : [BrainToolText.fileLine(path: passage.path, startLine: passage.startLine, endLine: passage.endLine)]
                if let heading = passage.heading, !heading.isEmpty {
                    blockLines.append("Heading: \(heading)")
                }
                blockLines.append(passage.text)
                blocks.append(blockLines.joined(separator: "\n"))
            }
            return (blocks.joined(separator: "\n\n"), false)
        } catch {
            return (Self.indexNotReadyText, true)
        }
    }

    private func readBrainFile(arguments: [String: Any]) -> (text: String, isError: Bool) {
        guard let path = arguments["path"] as? String, !path.isEmpty else {
            return ("read_brain_file needs a path.", true)
        }
        let parsedStartLine: Int?
        let parsedLineCount: Int?
        do {
            parsedStartLine = try Self.optionalInteger(named: "start_line", in: arguments)
            parsedLineCount = try Self.optionalInteger(named: "line_count", in: arguments)
        } catch let problem as NumberArgumentProblem {
            return (problem.message, true)
        } catch { return (Self.indexNotReadyText, true) }
        let startLine = Self.clamped(parsedStartLine ?? 1, to: Self.startLineRange)
        let lineCount = Self.clamped(parsedLineCount ?? BrainFileReader.maximumLinesPerCall, to: Self.lineCountRange)
        do {
            let excerpt = try backend.readFile(path: path, startLine: startLine, lineCount: lineCount)
            if excerpt.lines.isEmpty {
                return ("(The file has \(excerpt.totalLineCount) lines.)", false)
            }
            let lastReturnedLine = excerpt.startLine + excerpt.lines.count - 1
            var outputLines = [BrainToolText.fileLine(path: excerpt.path, startLine: excerpt.startLine, endLine: lastReturnedLine)]
            outputLines += excerpt.lines
            if excerpt.wasCappedByLimit {
                outputLines.append(
                    "(Lines \(excerpt.startLine)-\(lastReturnedLine) of \(excerpt.totalLineCount). Ask again with start_line \(lastReturnedLine + 1) for more.)")
            }
            return (outputLines.joined(separator: "\n"), false)
        } catch let refusal as BrainFileRefusal {
            return (Self.refusalText(refusal), true)
        } catch {
            return (Self.indexNotReadyText, true)
        }
    }

    private static func refusalText(_ refusal: BrainFileRefusal) -> String {
        switch refusal {
        case .neverReadable: return "That file is never readable: it may hold secrets."
        case .outsideSearchFolders: return "That path is outside the folders Clicky can search."
        case .notFound: return "No such file in the folders Clicky can search."
        case .notText: return "That file is not text, or it is larger than 8 MB."
        }
    }

    /// A number argument that is present but is not a usable number (text, a boolean, an object, NaN, infinity).
    private struct NumberArgumentProblem: Error {
        let message: String
    }

    /// Nil when the argument is absent or null (the caller uses its default); a number clamped into the Int range
    /// otherwise; throws `NumberArgumentProblem` for anything that is not a number. Numbers arrive as JSON numbers or
    /// as strings holding numbers. Never traps: `1e300` becomes a huge Int that the caller then clamps to its range.
    private static func optionalInteger(named name: String, in arguments: [String: Any]) throws -> Int? {
        guard let value = arguments[name], !(value is NSNull) else { return nil }
        let problem = NumberArgumentProblem(message: "\(name) must be a whole number.")
        let numericValue: Double
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let whole = Int(trimmed) { return whole }
            guard let parsed = Double(trimmed) else { throw problem }
            numericValue = parsed
        } else if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            numericValue = number.doubleValue
        } else {
            throw problem
        }
        guard !numericValue.isNaN, numericValue.isFinite else { throw problem }
        // Int(Double) traps outside the Int range, so limit the value first. 1e15 is far above every range used here.
        let limitedValue = min(max(numericValue.rounded(.towardZero), -1e15), 1e15)
        return Int(limitedValue)
    }

    private static func clamped(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }

    // MARK: descriptions

    private static func toolDescriptions() -> [[String: Any]] {
        [
            [
                "name": BrainToolName.searchBrain.rawValue,
                "description": "Search the user's notes and project files (markdown and text) by keywords. Returns the best passages, each with its file path and line numbers. Use a few distinctive keywords; search again with other words when the first try misses.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "A few distinctive keywords."],
                        "limit": [
                            "type": "integer", "default": defaultSearchLimit, "minimum": 1, "maximum": searchLimitRange.upperBound,
                            "description": "How many passages to return.",
                        ],
                    ],
                    "required": ["query"],
                ] as [String: Any],
            ],
            [
                "name": BrainToolName.readBrainFile.rawValue,
                "description": "Read lines of one text file in the user's notes folders, by a path a search result or a map file gave. Returns at most 200 lines per call; ask again with a later start_line for more.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "The absolute path of the file."],
                        "start_line": ["type": "integer", "default": 1, "minimum": 1, "description": "The first line to read, counting from 1."],
                        "line_count": [
                            "type": "integer", "default": BrainFileReader.maximumLinesPerCall, "minimum": 1,
                            "maximum": BrainFileReader.maximumLinesPerCall, "description": "How many lines to read.",
                        ],
                    ],
                    "required": ["path"],
                ] as [String: Any],
            ],
        ]
    }

    // MARK: replies

    private func resultReply(id: Any, result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private func errorReply(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    /// One line of JSON: serialization without pretty printing escapes every newline inside strings.
    private static func encode(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
