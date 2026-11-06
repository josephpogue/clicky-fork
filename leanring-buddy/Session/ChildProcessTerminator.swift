//
//  ChildProcessTerminator.swift
//  leanring-buddy
//
//  Ends the processes this app started (the `claude` or `codex` helper) so quitting
//  never leaves one running. Used when Quit arrives while Stop waits for its summary.
//

import Foundation

enum ChildProcessTerminator {
    /// Sends SIGTERM to every direct child of this app.
    static func terminateDirectChildren() {
        let listing = Process()
        listing.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        listing.arguments = ["-P", String(getpid())]
        let outputPipe = Pipe()
        listing.standardOutput = outputPipe
        listing.standardError = FileHandle.nullDevice
        do {
            try listing.run()
        } catch {
            return
        }
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        listing.waitUntilExit()
        let childIDs = String(decoding: outputData, as: UTF8.self)
            .split(separator: "\n")
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
        for childID in childIDs {
            kill(childID, SIGTERM)
        }
    }
}
