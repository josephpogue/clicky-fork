import Foundation

public struct VaultSaveInput {
    public var vaultRoot: URL
    /// "yyyy-MM-dd"
    public var date: String
    public var title: String
    public var slug: String
    public var project: String?
    public var questionShotFiles: [URL]
    public var isDryRun: Bool

    public init(
        vaultRoot: URL, date: String, title: String, slug: String, project: String?,
        questionShotFiles: [URL], isDryRun: Bool
    ) {
        self.vaultRoot = vaultRoot
        self.date = date
        self.title = title
        self.slug = slug
        self.project = project
        self.questionShotFiles = questionShotFiles
        self.isDryRun = isDryRun
    }
}

public struct VaultSaveResult: Equatable {
    public var notePath: URL
    public var shotsFolder: URL
    public var projectPage: URL?
    public var committed: Bool
    public var commitError: String?
}

public enum VaultSaveFailure: Error, Equatable {
    case unknownProject(String)
    case writeFailed(String)
}

/// The only vault write in the app. Files one finished session under `_sources/sessions/`,
/// links it from the chosen project page and commits exactly those paths.
public enum VaultSessionSaver {
    public static let sessionsHeading = "## Sessions"

    public static func save(
        _ input: VaultSaveInput, renderLog: (String) -> String
    ) -> Result<VaultSaveResult, VaultSaveFailure> {
        let fileManager = FileManager.default
        let root = input.vaultRoot
        if let project = input.project, !VaultProjects.list(vaultRoot: root).contains(project) {
            return .failure(.unknownProject(project))
        }
        let sessionsFolder = root.appendingPathComponent("_sources", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        let stem = freeStem(in: sessionsFolder, date: input.date, slug: input.slug)
        let notePath = sessionsFolder.appendingPathComponent("\(stem).md")
        let shotsFolder = sessionsFolder.appendingPathComponent(stem, isDirectory: true)
            .appendingPathComponent("shots", isDirectory: true)
        let pagePath = input.project.map { VaultProjects.pageURL(vaultRoot: root, project: $0) }

        var result = VaultSaveResult(
            notePath: notePath, shotsFolder: shotsFolder, projectPage: pagePath,
            committed: false, commitError: nil)
        if input.isDryRun { return .success(result) }

        // Read the page first: an unreadable page stops the save before any write.
        var pageText: String?
        if let pagePath {
            do { pageText = try String(contentsOf: pagePath, encoding: .utf8) } catch {
                return .failure(.writeFailed("could not read \(pagePath.path): \(error.localizedDescription)"))
            }
        }

        // Every target is checked with its links resolved: nothing may land outside the notes folder.
        let resolvedRootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        for target in [sessionsFolder, notePath, shotsFolder] + (pagePath.map { [$0] } ?? []) {
            if !isInside(target, resolvedRootPath: resolvedRootPath) {
                return .failure(.writeFailed("\(target.path) is outside the notes folder"))
            }
        }
        if let pagePath, isSymbolicLink(pagePath) {
            return .failure(.writeFailed("\(pagePath.path) is a link, so Save will not replace it"))
        }

        // What this Save has written so far, so a failure can take it all back.
        var wroteNote = false
        var wroteShotsFolder = false
        var wrotePage = false
        var pathsToCommit: [URL] = []
        do {
            try fileManager.createDirectory(at: sessionsFolder, withIntermediateDirectories: true)
            let document = frontMatter(input: input) + renderLog(stem)
            try document.write(to: notePath, atomically: true, encoding: .utf8)
            wroteNote = true
            pathsToCommit.append(notePath)
            if let pagePath, let pageText,
               let updated = pageWithSessionLink(pageText, date: input.date, title: input.title, stem: stem) {
                try updated.write(to: pagePath, atomically: true, encoding: .utf8)
                wrotePage = true
                pathsToCommit.append(pagePath)
            }
            if !input.questionShotFiles.isEmpty {
                try fileManager.createDirectory(at: shotsFolder, withIntermediateDirectories: true)
                wroteShotsFolder = true
                for shot in input.questionShotFiles {
                    let destination = shotsFolder.appendingPathComponent(shot.lastPathComponent)
                    if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
                    try fileManager.copyItem(at: shot, to: destination)
                }
                pathsToCommit.append(shotsFolder)
            }
        } catch {
            if wrotePage, let pagePath, let pageText { try? pageText.write(to: pagePath, atomically: true, encoding: .utf8) }
            if wroteShotsFolder {
                // The stem was free, so the folder above `shots` is this Save's own.
                try? fileManager.removeItem(at: shotsFolder.deletingLastPathComponent())
            }
            if wroteNote { try? fileManager.removeItem(at: notePath) }
            return .failure(.writeFailed(error.localizedDescription))
        }

        if let reason = commit(paths: pathsToCommit, in: root, message: "Clicky session: \(input.title)") {
            result.commitError = reason
        } else {
            result.committed = true
        }
        return .success(result)
    }

    // MARK: Pieces (internal for tests of the callers' view only through save)

    static func freeStem(in folder: URL, date: String, slug: String) -> String {
        let base = "\(date)-\(slug)"
        func taken(_ stem: String) -> Bool {
            // A link counts as taken even when it points nowhere: Save never replaces a user's link.
            exists(folder.appendingPathComponent("\(stem).md")) || exists(folder.appendingPathComponent(stem))
        }
        if !taken(base) { return base }
        var number = 2
        while taken("\(base)-\(number)") { number += 1 }
        return "\(base)-\(number)"
    }

    private static func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.type] as? FileAttributeType == .typeSymbolicLink
    }

    /// The path with every link in its existing part resolved; the parts that do not exist yet are appended as written.
    private static func resolvedPath(of url: URL) -> String {
        var existing = url.standardizedFileURL
        var missingParts: [String] = []
        while !exists(existing), existing.path != "/" {
            missingParts.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        var resolved = existing.resolvingSymlinksInPath().standardizedFileURL
        for part in missingParts { resolved.appendPathComponent(part) }
        return resolved.path
    }

    /// True when `url`, with every link in its existing part resolved, sits under the resolved notes folder.
    private static func isInside(_ url: URL, resolvedRootPath: String) -> Bool {
        let resolved = resolvedPath(of: url)
        return resolved == resolvedRootPath || resolved.hasPrefix(resolvedRootPath + "/")
    }

    static func frontMatter(input: VaultSaveInput) -> String {
        let escapedTitle = input.title
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
        var lines = [
            "---",
            "title: \"\(escapedTitle)\"",
            "date: \(input.date)",
            "type: session",
            "source: Clicky Fork",
        ]
        if let project = input.project { lines.append("project: \(project)") }
        lines.append("---")
        return lines.joined(separator: "\n") + "\n\n"
    }

    /// Adds `- [[<stem>|<date> <title>]]` as the last line of the page's `## Sessions` section,
    /// creating the section at the end when missing. Nil when the page already links the stem.
    static func pageWithSessionLink(_ page: String, date: String, title: String, stem: String) -> String? {
        if page.contains("[[\(stem)]]") || page.contains("[[\(stem)|") { return nil }
        let label = "\(date) \(title)"
            .replacingOccurrences(of: "|", with: "-")
            .replacingOccurrences(of: "[", with: "(")
            .replacingOccurrences(of: "]", with: ")")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let line = "- [[\(stem)|\(label)]]"
        var lines = page.components(separatedBy: "\n")
        guard let heading = lines.firstIndex(where: {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r")) == sessionsHeading
        }) else {
            let trimmed = page.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            return "\(trimmed)\n\n\(sessionsHeading)\n\n\(line)\n"
        }
        let end = lines[(heading + 1)...].firstIndex(where: { $0.hasPrefix("# ") || $0.hasPrefix("## ") })
            ?? lines.count
        let last = (heading..<end).reversed().first(where: {
            !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty
        }) ?? heading
        if last == heading {
            lines.insert(contentsOf: ["", line], at: heading + 1)
        } else {
            lines.insert(line, at: last + 1)
        }
        return lines.joined(separator: "\n")
    }

    /// Commits exactly `paths`; nil on success, else the reason it failed.
    static func commit(paths: [URL], in root: URL, message: String) -> String? {
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let relative = paths.map { url -> String in
            let full = url.standardizedFileURL.resolvingSymlinksInPath().path
            return full.hasPrefix(rootPath) ? String(full.dropFirst(rootPath.count)) : full
        }
        // Commit only in a repo whose top is the notes folder itself, never in one that merely encloses it.
        let top = runGitOutput(["rev-parse", "--show-toplevel"], in: root)
        if let reason = top.failure { return reason }
        let resolvedTop = URL(fileURLWithPath: top.text).resolvingSymlinksInPath().standardizedFileURL.path
        guard resolvedTop == String(rootPath.dropLast()) else {
            return "the notes folder is inside another git repo (\(resolvedTop)), so nothing was committed"
        }
        if let failure = runGit(["add", "--"] + relative, in: root) { return failure }
        return runGit(["commit", "-m", message, "--"] + relative, in: root)
    }

    /// Runs git in `folder`; nil on success, else a plain reason.
    private static func runGit(_ arguments: [String], in folder: URL) -> String? {
        runGitOutput(arguments, in: folder).failure
    }

    /// Runs git in `folder` and returns what it printed, or a plain reason it failed.
    private static func runGitOutput(_ arguments: [String], in folder: URL) -> (text: String, failure: String?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", folder.path] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do { try process.run() } catch {
            return ("", "could not run git \(arguments.first ?? ""): \(error.localizedDescription)")
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else { return (text, "git \(arguments.first ?? "") failed: \(text)") }
        return (text, nil)
    }
}
