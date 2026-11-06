import ClickyCore
import Foundation

// The helper the Claude CLI starts over MCP (stdio). It serves two read-only tools, search_brain and read_brain_file,
// and nothing else: no commands, no writes, no network.
// Usage: ClickyBrainTools --index <database> --folder <a> [--folder <b> ...]
// Only JSON-RPC lines go to stdout; every diagnostic goes to stderr.

func printUsageAndExit() -> Never {
    FileHandle.standardError.write(Data("usage: ClickyBrainTools --index <database> --folder <folder> [--folder <folder> ...]\n".utf8))
    exit(2)
}

var indexDatabasePath: String?
var searchFolderPaths: [String] = []
var remainingArguments = CommandLine.arguments.dropFirst()
while let argument = remainingArguments.popFirst() {
    switch argument {
    case "--index":
        guard let value = remainingArguments.popFirst() else { printUsageAndExit() }
        indexDatabasePath = value
    case "--folder":
        guard let value = remainingArguments.popFirst() else { printUsageAndExit() }
        searchFolderPaths.append(value)
    default:
        printUsageAndExit()
    }
}
guard let indexDatabasePath, !searchFolderPaths.isEmpty else { printUsageAndExit() }

/// The real tools. The index is opened on each search so an index the app builds after the helper starts still works.
struct RealBrainToolBackend: BrainToolBackend {
    let indexDatabaseURL: URL
    let fileReader: BrainFileReader

    func search(query: String, limit: Int) throws -> [BrainPassage] {
        let index = try BrainIndex(databaseURL: indexDatabaseURL, readOnly: true)
        let passages = try index.search(query: query, limit: limit)
        // Defence in depth: a folder removed in Settings may still have rows in the index until the next update.
        return passages.filter { (try? fileReader.resolveReadableFile($0.path)) != nil }
    }

    func readFile(path: String, startLine: Int, lineCount: Int) throws -> BrainFileExcerpt {
        try fileReader.read(path: path, startLine: startLine, lineCount: lineCount)
    }
}

let searchFolderURLs = searchFolderPaths.map { URL(fileURLWithPath: $0) }
let server = BrainToolServerCore(backend: RealBrainToolBackend(
    indexDatabaseURL: URL(fileURLWithPath: indexDatabasePath),
    fileReader: BrainFileReader(searchFolders: searchFolderURLs)))

while let requestLine = readLine(strippingNewline: true) {
    if requestLine.trimmingCharacters(in: .whitespaces).isEmpty { continue }
    if let replyLine = server.response(toLine: requestLine) {
        FileHandle.standardOutput.write(Data((replyLine + "\n").utf8))
    }
}
