import Foundation

/// User-given workspace names ("Docs", "Website", …), kept in UserDefaults across restarts.
enum WorkspaceNames {
    private static let key = "workspaceNames"

    static func all() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    /// An empty name removes it, so the card falls back to "Workspace N".
    static func set(_ name: String, for workspace: String) {
        var names = all()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        names[workspace] = trimmed.isEmpty ? nil : trimmed
        UserDefaults.standard.set(names, forKey: key)
    }
}
