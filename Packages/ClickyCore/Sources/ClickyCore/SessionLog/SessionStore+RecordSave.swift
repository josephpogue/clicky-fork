import Foundation

extension SessionStore {
    /// Records where Save filed a session. It reads the metadata fresh from disk and changes only the two
    /// save fields, so a window opened before the session finished cannot write back its old `endedAt`,
    /// `summary` or `cleanedUp`. Both steps run inside the store, with nothing able to interleave.
    public func recordSave(sessionID: String, savedVaultNotePath: String, savedProject: String?) throws -> SessionMetadata {
        var metadata = try loadSession(id: sessionID).metadata
        metadata.savedVaultNotePath = savedVaultNotePath
        metadata.savedProject = savedProject
        try updateMetadata(metadata)
        return metadata
    }
}
