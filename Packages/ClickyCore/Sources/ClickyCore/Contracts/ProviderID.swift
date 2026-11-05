/// The two AI services the app can ask. Stored in settings and in the session log, so the raw values must not change.
public enum ProviderID: String, Codable, CaseIterable, Sendable {
    case claude
    case chatgpt
}
