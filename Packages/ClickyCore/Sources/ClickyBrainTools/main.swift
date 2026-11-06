import ClickyCore
import Foundation

// The helper the Claude CLI starts over MCP (stdio). It serves two read-only tools, search_brain and read_brain_file,
// and nothing else: no commands, no writes, no network.
// Usage: ClickyBrainTools --index <database> [--folders-file <folders.json>] --folder <a> [--folder <b> ...]
// Only JSON-RPC lines go to stdout; every diagnostic goes to stderr.

func printUsageAndExit() -> Never {
    FileHandle.standardError.write(Data("usage: ClickyBrainTools --index <database> [--folders-file <folders.json>] --folder <folder> [--folder <folder> ...]\n".utf8))
    exit(2)
}

var indexDatabasePath: String?
var foldersFilePath: String?
var searchFolderPaths: [String] = []
var remainingArguments = CommandLine.arguments.dropFirst()
while let argument = remainingArguments.popFirst() {
    switch argument {
    case "--index":
        guard let value = remainingArguments.popFirst() else { printUsageAndExit() }
        indexDatabasePath = value
    case "--folders-file":
        guard let value = remainingArguments.popFirst() else { printUsageAndExit() }
        foldersFilePath = value
    case "--folder":
        guard let value = remainingArguments.popFirst() else { printUsageAndExit() }
        searchFolderPaths.append(value)
    default:
        printUsageAndExit()
    }
}
guard let indexDatabasePath, !searchFolderPaths.isEmpty else { printUsageAndExit() }

let searchFolderURLs = searchFolderPaths.map { URL(fileURLWithPath: $0) }
let indexDatabaseURL = URL(fileURLWithPath: indexDatabasePath)
// Without --folders-file the list is the one beside the index database.
let folderListFileURL = foldersFilePath.map { URL(fileURLWithPath: $0) }
    ?? BrainServiceFolderListFile.url(besideIndexDatabase: indexDatabaseURL)
let server = BrainToolServerCore(backend: BrainServiceHelperBackend(
    indexDatabaseURL: indexDatabaseURL, launchFolders: searchFolderURLs, folderListFileURL: folderListFileURL))

while let requestLine = readLine(strippingNewline: true) {
    if requestLine.trimmingCharacters(in: .whitespaces).isEmpty { continue }
    if let replyLine = server.response(toLine: requestLine) {
        FileHandle.standardOutput.write(Data((replyLine + "\n").utf8))
    }
}
