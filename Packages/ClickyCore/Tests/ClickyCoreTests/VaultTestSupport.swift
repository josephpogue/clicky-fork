import Foundation

/// Helpers shared by the Vault suites. Every vault lives in a fresh temp folder; nothing here
/// touches a real notes folder.
enum VaultTestSupport {
    static func makeTempFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("clicky-vault-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @discardableResult
    static func git(_ arguments: [String], in folder: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", folder.path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// A vault with three project pages and a README, optionally a git repo with one commit.
    static func makeVault(withGit: Bool) throws -> URL {
        let root = try makeTempFolder()
        let projects = root.appendingPathComponent("Wiki/Projects", isDirectory: true)
        try write("# Clicky Fork\n\nA menu-bar helper.\n", to: projects.appendingPathComponent("clicky-fork.md"))
        try write("# Meetily Fork\n\nMeetings.\n", to: projects.appendingPathComponent("meetily-fork.md"))
        try write("# Homelab\n\nThe lab.\n", to: projects.appendingPathComponent("homelab.md"))
        try write("not a project", to: projects.appendingPathComponent("README.txt"))
        if withGit {
            try git(["init", "-q"], in: root)
            try git(["config", "user.name", "Test User"], in: root)
            try git(["config", "user.email", "test@example.com"], in: root)
            try git(["config", "commit.gpgsign", "false"], in: root)
            try git(["add", "-A"], in: root)
            try git(["commit", "-q", "-m", "Seed"], in: root)
        }
        return root
    }

    static func makeShots(count: Int) throws -> [URL] {
        let folder = try makeTempFolder()
        var urls: [URL] = []
        for index in 0..<count {
            let name = String(format: "%04d-screen%d.jpg", 3 + index * 2, index + 1)
            let url = folder.appendingPathComponent(name)
            try Data([0xFF, 0xD8, UInt8(index)]).write(to: url)
            urls.append(url)
        }
        return urls
    }
}
