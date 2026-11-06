import Foundation

/// Decides whether the window the user is looking at names a project, and whether a note belongs to that project.
enum BrainProjectBoost {
    /// `-` and `_` count as spaces, so the project `clicky-fork` matches the title "clicky fork - SessionCoordinator.swift".
    static func normalized(_ text: String) -> String {
        let spaced = text.lowercased().map { $0 == "-" || $0 == "_" ? " " : $0 }
        return String(spaced)
    }

    /// True when `name` appears in the text as a whole word (or run of words), case-insensitive.
    static func windowText(_ text: String, mentions name: String) -> Bool {
        let normalizedName = normalized(name).trimmingCharacters(in: .whitespaces)
        guard !normalizedName.isEmpty else { return false }
        // Pad with spaces after turning every non-alphanumeric character into one, so " name " finds whole words only.
        let paddedText = " " + collapseSeparators(normalized(text)) + " "
        let paddedName = " " + collapseSeparators(normalizedName) + " "
        return paddedText.contains(paddedName)
    }

    private static func collapseSeparators(_ text: String) -> String {
        var result = ""
        var lastWasSeparator = true
        for character in text {
            if character.isLetter || character.isNumber {
                result.append(character)
                lastWasSeparator = false
            } else if !lastWasSeparator {
                result.append(" ")
                lastWasSeparator = true
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// True when a path component equals the project name, or the file is `<name>.md` under a `Projects` folder.
    static func path(_ path: String, belongsTo projectName: String) -> Bool {
        let lowercasedName = projectName.lowercased()
        let components = path.split(separator: "/").map { String($0).lowercased() }
        guard let fileName = components.last else { return false }
        let folderComponents = components.dropLast()
        if folderComponents.contains(lowercasedName) { return true }
        return fileName == lowercasedName + ".md" && folderComponents.contains("projects")
    }
}
