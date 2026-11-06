import Foundation

/// Which files the brain index holds and which no tool may ever read. Owned by the brain-files slice.
/// Foundation stub: the bodies below are placeholders that refuse everything.
public enum BrainFileRules {
    /// Files larger than this are never indexed (they stay readable by path).
    public static let maximumIndexedFileBytes = 512 * 1024

    /// True for a file no tool may read and the index never holds: secrets, git internals, node_modules, binaries
    /// by name. Checked on every component of both the path as given and the path after resolving symlinks.
    public static func isNeverReadable(path: String) -> Bool {
        true
    }

    /// True for a directory the index walker skips without descending (worktree copies, `-prod` copies, build output).
    public static func isSkippedDirectoryForIndex(name: String) -> Bool {
        true
    }

    /// True for a file the index holds: markdown or plain text, not never-readable, at most the size cap.
    public static func isIndexableFile(path: String, byteCount: Int) -> Bool {
        false
    }
}
