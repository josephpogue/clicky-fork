import Foundation
import Testing
@testable import ClickyCore

/// A backend that records what the server asked for and answers from fixed values, so no file or index is involved.
private final class FakeBrainToolBackend: BrainToolBackend, @unchecked Sendable {
    var passagesToReturn: [BrainPassage] = []
    var excerptToReturn = BrainFileExcerpt(path: "/n/a.md", startLine: 1, lines: ["one"], totalLineCount: 1, wasCappedByLimit: false)
    var errorToThrow: Error?
    var lastSearch: (query: String, limit: Int)?
    var lastRead: (path: String, startLine: Int, lineCount: Int)?

    func search(query: String, limit: Int) throws -> [BrainPassage] {
        lastSearch = (query, limit)
        if let errorToThrow { throw errorToThrow }
        return passagesToReturn
    }

    func readFile(path: String, startLine: Int, lineCount: Int) throws -> BrainFileExcerpt {
        lastRead = (path, startLine, lineCount)
        if let errorToThrow { throw errorToThrow }
        return excerptToReturn
    }
}

private struct SomeIndexError: Error {}

private func parsedObject(_ line: String?) -> [String: Any] {
    guard let line, let data = line.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
    return object
}

private func toolResult(_ line: String?) -> (text: String, isError: Bool) {
    let result = parsedObject(line)["result"] as? [String: Any] ?? [:]
    let content = result["content"] as? [[String: Any]] ?? []
    return (content.first?["text"] as? String ?? "", result["isError"] as? Bool ?? false)
}

private func callLine(_ name: String, _ arguments: String) -> String {
    #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"\#(name)","arguments":\#(arguments)}}"#
}

struct BrainToolServerCoreTests {
    private func makeServer(_ backend: FakeBrainToolBackend = FakeBrainToolBackend()) -> (BrainToolServerCore, FakeBrainToolBackend) {
        (BrainToolServerCore(backend: backend), backend)
    }

    // MARK: protocol

    @Test(arguments: ["2025-06-18", "2025-03-26", "2024-11-05"])
    func initializeEchoesSupportedVersion(version: String) {
        let (server, _) = makeServer()
        let reply = parsedObject(server.response(toLine:
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"\#(version)","capabilities":{}}}"#))
        let result = reply["result"] as? [String: Any]
        #expect(result?["protocolVersion"] as? String == version)
        #expect((result?["capabilities"] as? [String: Any])?["tools"] as? [String: Any] != nil)
        let info = result?["serverInfo"] as? [String: Any]
        #expect(info?["name"] as? String == "brain")
        #expect(info?["version"] as? String == "1")
        #expect(reply["id"] as? Int == 1)
    }

    @Test func initializeAnswersLatestForUnknownVersion() {
        let (server, _) = makeServer()
        let reply = parsedObject(server.response(toLine:
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#))
        #expect((reply["result"] as? [String: Any])?["protocolVersion"] as? String == "2025-06-18")
    }

    @Test func notificationsGetNoReply() {
        let (server, _) = makeServer()
        #expect(server.response(toLine: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
    }

    @Test func badJsonGetsParseError() {
        let (server, _) = makeServer()
        let reply = parsedObject(server.response(toLine: "{not json"))
        #expect((reply["error"] as? [String: Any])?["code"] as? Int == -32700)
        #expect(reply["id"] is NSNull)
    }

    @Test func unknownMethodWithIdGetsMethodNotFound() {
        let (server, _) = makeServer()
        let reply = parsedObject(server.response(toLine: #"{"jsonrpc":"2.0","id":"abc","method":"resources/list"}"#))
        #expect((reply["error"] as? [String: Any])?["code"] as? Int == -32601)
        #expect(reply["id"] as? String == "abc")
    }

    @Test func pingAnswersEmptyObject() {
        let (server, _) = makeServer()
        let reply = parsedObject(server.response(toLine: #"{"jsonrpc":"2.0","id":3,"method":"ping"}"#))
        #expect((reply["result"] as? [String: Any])?.isEmpty == true)
    }

    @Test func replyIsOneLine() {
        let (server, backend) = makeServer()
        backend.passagesToReturn = [BrainPassage(path: "/n/a.md", heading: "H", startLine: 1, endLine: 2, text: "a\nb", score: 1)]
        let line = server.response(toLine: callLine("search_brain", #"{"query":"x"}"#))
        #expect(line?.contains("\n") == false)
    }

    // MARK: tools/list

    @Test func listsExactlyTheTwoTools() throws {
        let (server, _) = makeServer()
        let reply = parsedObject(server.response(toLine: #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#))
        let tools = try #require((reply["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        #expect(tools.compactMap { $0["name"] as? String } == ["search_brain", "read_brain_file"])

        let search = tools[0]
        #expect((search["description"] as? String)?.hasPrefix("Search the user's notes and project files") == true)
        let searchSchema = try #require(search["inputSchema"] as? [String: Any])
        #expect(searchSchema["type"] as? String == "object")
        #expect(searchSchema["required"] as? [String] == ["query"])
        let searchProperties = try #require(searchSchema["properties"] as? [String: Any])
        #expect((searchProperties["query"] as? [String: Any])?["type"] as? String == "string")
        let limit = try #require(searchProperties["limit"] as? [String: Any])
        #expect(limit["type"] as? String == "integer")
        #expect(limit["default"] as? Int == 8)
        #expect(limit["maximum"] as? Int == 20)

        let read = tools[1]
        #expect((read["description"] as? String)?.hasPrefix("Read lines of one text file") == true)
        let readSchema = try #require(read["inputSchema"] as? [String: Any])
        #expect(readSchema["type"] as? String == "object")
        #expect(readSchema["required"] as? [String] == ["path"])
        let readProperties = try #require(readSchema["properties"] as? [String: Any])
        #expect((readProperties["path"] as? [String: Any])?["type"] as? String == "string")
        #expect((readProperties["start_line"] as? [String: Any])?["default"] as? Int == 1)
        let lineCount = try #require(readProperties["line_count"] as? [String: Any])
        #expect(lineCount["default"] as? Int == 200)
        #expect(lineCount["maximum"] as? Int == 200)
    }

    // MARK: search

    @Test func searchTextHasFileLineHeadingAndPassageSeparatedByBlankLine() {
        let (server, backend) = makeServer()
        backend.passagesToReturn = [
            BrainPassage(path: "/n/a.md", heading: "Plan", startLine: 3, endLine: 9, text: "alpha\nbeta", score: 2),
            BrainPassage(path: "/n/b.txt", heading: nil, startLine: 1, endLine: 1, text: "gamma", score: 1),
        ]
        let result = toolResult(server.response(toLine: callLine("search_brain", #"{"query":"alpha"}"#)))
        #expect(result.isError == false)
        #expect(result.text == "File: /n/a.md lines 3-9\nHeading: Plan\nalpha\nbeta\n\nFile: /n/b.txt lines 1-1\ngamma")
        #expect(BrainToolText.paths(inToolResult: result.text) == ["/n/a.md", "/n/b.txt"])
        #expect(backend.lastSearch?.query == "alpha")
        #expect(backend.lastSearch?.limit == 8)
    }

    @Test func pathsListsEachPassagePathOnceInOrder() {
        let (server, backend) = makeServer()
        backend.passagesToReturn = [
            BrainPassage(path: "/n/a.md", heading: nil, startLine: 1, endLine: 2, text: "x", score: 3),
            BrainPassage(path: "/n/b.md", heading: nil, startLine: 1, endLine: 2, text: "y", score: 2),
            BrainPassage(path: "/n/a.md", heading: "Later", startLine: 8, endLine: 9, text: "z", score: 1),
        ]
        let result = toolResult(server.response(toLine: callLine("search_brain", #"{"query":"q"}"#)))
        #expect(BrainToolText.paths(inToolResult: result.text) == ["/n/a.md", "/n/b.md"])
    }

    @Test func noHitsSaysSo() {
        let (server, _) = makeServer()
        let result = toolResult(server.response(toLine: callLine("search_brain", #"{"query":"zebra"}"#)))
        #expect(result.isError == false)
        #expect(result.text == #"No notes matched "zebra". Try other words, or read a map file."#)
    }

    @Test(arguments: [("50", 20), ("0", 1), ("-3", 1), ("5", 5), (#""12""#, 12)])
    func searchLimitIsClamped(rawLimit: String, expected: Int) {
        let (server, backend) = makeServer()
        _ = server.response(toLine: callLine("search_brain", #"{"query":"q","limit":\#(rawLimit)}"#))
        #expect(backend.lastSearch?.limit == expected)
    }

    @Test(arguments: [
        (#""1e300""#, 20), (#""-1e300""#, 1), ("1e300", 20), ("-1e300", 1), ("1e19", 20), (#""9223372036854775807""#, 20),
        (#""99999999999999999999""#, 20), (#"" 7 ""#, 7), (#""2.9""#, 2),
    ])
    func searchLimitHugeNumbersClampWithoutCrashing(rawLimit: String, expected: Int) {
        let (server, backend) = makeServer()
        let result = toolResult(server.response(toLine: callLine("search_brain", #"{"query":"q","limit":\#(rawLimit)}"#)))
        #expect(result.isError == false)
        #expect(backend.lastSearch?.limit == expected)
    }

    @Test(arguments: [#""NaN""#, #""inf""#, #""-inf""#, #""Infinity""#, #""""#, #""abc""#, "true", "false", #"{"a":1}"#, "[1,2]"])
    func badNumbersAreToolErrors(rawValue: String) {
        for argumentName in ["limit"] {
            let (server, backend) = makeServer()
            let result = toolResult(server.response(toLine: callLine("search_brain", #"{"query":"q","\#(argumentName)":\#(rawValue)}"#)))
            #expect(result.isError == true)
            #expect(backend.lastSearch == nil)
        }
        for argumentName in ["start_line", "line_count"] {
            let (server, backend) = makeServer()
            let result = toolResult(server.response(toLine: callLine("read_brain_file", #"{"path":"/n/a.md","\#(argumentName)":\#(rawValue)}"#)))
            #expect(result.isError == true)
            #expect(backend.lastRead == nil)
        }
    }

    @Test(arguments: [#""1e300""#, #""-1e300""#, "1e300", "-1e300", #""9223372036854775807""#])
    func readNumbersHugeValuesClampWithoutCrashing(rawValue: String) {
        for argumentName in ["start_line", "line_count"] {
            let (server, backend) = makeServer()
            let result = toolResult(server.response(toLine: callLine("read_brain_file", #"{"path":"/n/a.md","\#(argumentName)":\#(rawValue)}"#)))
            #expect(result.isError == false)
            let read = backend.lastRead
            #expect(read != nil)
            #expect((read?.startLine ?? 0) >= 1)
            #expect((1...200).contains(read?.lineCount ?? 0))
        }
    }

    @Test func nullNumberUsesTheDefault() {
        let (server, backend) = makeServer()
        _ = server.response(toLine: callLine("search_brain", #"{"query":"q","limit":null}"#))
        #expect(backend.lastSearch?.limit == 8)
    }

    @Test func missingQueryIsAnError() {
        let (server, backend) = makeServer()
        let result = toolResult(server.response(toLine: callLine("search_brain", "{}")))
        #expect(result.isError == true)
        #expect(result.text == "search_brain needs a query.")
        #expect(backend.lastSearch == nil)
    }

    // MARK: read

    @Test func readTextHasFileLineThenLines() {
        let (server, backend) = makeServer()
        backend.excerptToReturn = BrainFileExcerpt(path: "/n/a.md", startLine: 5, lines: ["five", "six"], totalLineCount: 6, wasCappedByLimit: false)
        let result = toolResult(server.response(toLine: callLine("read_brain_file", #"{"path":"/n/a.md","start_line":5,"line_count":2}"#)))
        #expect(result.isError == false)
        #expect(result.text == "File: /n/a.md lines 5-6\nfive\nsix")
        #expect(backend.lastRead?.path == "/n/a.md")
        #expect(backend.lastRead?.startLine == 5)
        #expect(backend.lastRead?.lineCount == 2)
    }

    @Test func cappedReadAddsAskAgainLine() {
        let (server, backend) = makeServer()
        backend.excerptToReturn = BrainFileExcerpt(path: "/n/a.md", startLine: 1, lines: ["a", "b"], totalLineCount: 500, wasCappedByLimit: true)
        let result = toolResult(server.response(toLine: callLine("read_brain_file", #"{"path":"/n/a.md"}"#)))
        #expect(result.text == "File: /n/a.md lines 1-2\na\nb\n(Lines 1-2 of 500. Ask again with start_line 3 for more.)")
        #expect(backend.lastRead?.startLine == 1)
        #expect(backend.lastRead?.lineCount == 200)
    }

    @Test func readPastTheEndSaysHowManyLines() {
        let (server, backend) = makeServer()
        backend.excerptToReturn = BrainFileExcerpt(path: "/n/a.md", startLine: 50, lines: [], totalLineCount: 12, wasCappedByLimit: false)
        let result = toolResult(server.response(toLine: callLine("read_brain_file", #"{"path":"/n/a.md","start_line":50}"#)))
        #expect(result.isError == false)
        #expect(result.text == "(The file has 12 lines.)")
    }

    @Test(arguments: [("0", 1), ("-5", 1), ("500", 200), ("30", 30), (#""40""#, 40)])
    func lineCountIsClamped(rawLineCount: String, expected: Int) {
        let (server, backend) = makeServer()
        _ = server.response(toLine: callLine("read_brain_file", #"{"path":"/n/a.md","line_count":\#(rawLineCount)}"#))
        #expect(backend.lastRead?.lineCount == expected)
    }

    @Test func startLineBelowOneBecomesOne() {
        let (server, backend) = makeServer()
        _ = server.response(toLine: callLine("read_brain_file", #"{"path":"/n/a.md","start_line":-4}"#))
        #expect(backend.lastRead?.startLine == 1)
    }

    @Test(arguments: [
        (BrainFileRefusal.neverReadable, "That file is never readable: it may hold secrets."),
        (BrainFileRefusal.outsideSearchFolders, "That path is outside the folders Clicky can search."),
        (BrainFileRefusal.notFound, "No such file in the folders Clicky can search."),
        (BrainFileRefusal.notText, "That file is not text, or it is larger than 8 MB."),
    ])
    func refusalsExplainThemselves(refusal: BrainFileRefusal, expectedText: String) {
        let (server, backend) = makeServer()
        backend.errorToThrow = refusal
        let result = toolResult(server.response(toLine: callLine("read_brain_file", #"{"path":"/x"}"#)))
        #expect(result.isError == true)
        #expect(result.text == expectedText)
    }

    @Test func missingPathIsAnError() {
        let (server, backend) = makeServer()
        let result = toolResult(server.response(toLine: callLine("read_brain_file", "{}")))
        #expect(result.isError == true)
        #expect(result.text == "read_brain_file needs a path.")
        #expect(backend.lastRead == nil)
    }

    // MARK: errors

    @Test func unknownToolIsAnError() {
        let (server, _) = makeServer()
        let result = toolResult(server.response(toLine: callLine("run_shell", "{}")))
        #expect(result.isError == true)
        #expect(result.text == "Unknown tool run_shell. The tools are search_brain and read_brain_file.")
    }

    @Test func otherBackendErrorSaysIndexNotReady() {
        let (server, backend) = makeServer()
        backend.errorToThrow = SomeIndexError()
        let expected = "The notes index is not ready yet. Answer from the screen and say the notes could not be searched."
        let searchResult = toolResult(server.response(toLine: callLine("search_brain", #"{"query":"q"}"#)))
        #expect(searchResult.isError == true)
        #expect(searchResult.text == expected)
        let readResult = toolResult(server.response(toLine: callLine("read_brain_file", #"{"path":"/x"}"#)))
        #expect(readResult.text == expected)
    }
}
