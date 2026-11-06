import Foundation

/// Project pages in the notes folder (`Wiki/Projects/*.md`) and the suggestion of which one a
/// finished session belongs to. The rule is meetily-fork's word-overlap scoring.
public enum VaultProjects {
    static func projectsFolder(vaultRoot: URL) -> URL {
        vaultRoot.appendingPathComponent("Wiki", isDirectory: true).appendingPathComponent("Projects", isDirectory: true)
    }

    static func pageURL(vaultRoot: URL, project: String) -> URL {
        projectsFolder(vaultRoot: vaultRoot).appendingPathComponent("\(project).md")
    }

    private static func isProjectSlug(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first else { return false }
        func lowerOrDigit(_ s: Unicode.Scalar) -> Bool { ("a"..."z").contains(s) || ("0"..."9").contains(s) }
        return lowerOrDigit(first) && name.unicodeScalars.allSatisfy { lowerOrDigit($0) || $0 == "-" }
    }

    /// Slugs of the project pages, sorted, kebab-case names only. A missing folder gives [].
    public static func list(vaultRoot: URL) -> [String] {
        let folder = projectsFolder(vaultRoot: vaultRoot)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        return names
            .filter { name in
                // A linked page is never listed: Save would write through the link, or replace it.
                let attributes = try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name).path)
                if attributes?[.type] as? FileAttributeType == .typeSymbolicLink { return false }
                var isDirectory: ObjCBool = false
                let exists = FileManager.default.fileExists(
                    atPath: folder.appendingPathComponent(name).path, isDirectory: &isDirectory)
                return exists && !isDirectory.boolValue
            }
            .compactMap { name -> String? in
                guard name.hasSuffix(".md") else { return nil }
                return String(name.dropLast(3))
            }
            .filter(isProjectSlug)
            .sorted()
    }

    private static func words(_ text: String) -> Set<String> {
        Set(text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { $0.lowercased() })
    }

    private static func headingWords(vaultRoot: URL, slug: String) -> Set<String> {
        guard let text = try? String(contentsOf: pageURL(vaultRoot: vaultRoot, project: slug), encoding: .utf8)
        else { return [] }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) where line.hasPrefix("# ") {
            return words(String(line.dropFirst(2)))
        }
        return []
    }

    /// The project the session is about. A slug's tokens are its `-` parts (3+ characters, or a
    /// word of the page's H1) plus the H1's 3+ character words. A token found in 3+ slugs is
    /// common and scores 1, any other 3. The title and summary weigh 2; the questions and app
    /// names weigh 1; a token scores once per place it appears. Best total wins, ties go to the
    /// slug with fewer `-` parts then the alphabet, and a best total under 3 gives nil.
    public static func suggest(
        vaultRoot: URL, title: String, summary: String?, questions: [String], appNames: [String]
    ) -> String? {
        let head = words("\(title) \(summary ?? "")")
        let body = words((questions + appNames).joined(separator: " "))
        struct Candidate { let slug: String; let partCount: Int; let tokens: Set<String> }
        let candidates: [Candidate] = list(vaultRoot: vaultRoot).map { slug in
            let h1 = headingWords(vaultRoot: vaultRoot, slug: slug)
            let parts = slug.split(separator: "-").map(String.init)
            var tokens = Set(parts.filter { $0.count >= 3 || h1.contains($0) })
            tokens.formUnion(h1.filter { $0.count >= 3 })
            return Candidate(slug: slug, partCount: parts.count, tokens: tokens)
        }
        func ownerCount(_ token: String) -> Int { candidates.filter { $0.tokens.contains(token) }.count }
        var best: (score: Int, partCount: Int, slug: String)?
        for candidate in candidates {
            let score = candidate.tokens.reduce(0) { total, token in
                let value = ownerCount(token) >= 3 ? 1 : 3
                return total + value * ((head.contains(token) ? 2 : 0) + (body.contains(token) ? 1 : 0))
            }
            if let current = best {
                if score > current.score || (score == current.score && candidate.partCount < current.partCount) {
                    best = (score, candidate.partCount, candidate.slug)
                }
            } else {
                best = (score, candidate.partCount, candidate.slug)
            }
        }
        guard let winner = best, winner.score >= 3 else { return nil }
        return winner.slug
    }
}
