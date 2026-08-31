import Foundation

public enum EnvFormatter: Sendable {
    public static func render(secrets: [SecretItem]) -> String {
        secrets
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { item in
                "\(item.key)=\(escapeValue(item.value))"
            }
            .joined(separator: "\n")
            + (secrets.isEmpty ? "" : "\n")
    }

    /// Escape values that need quotes for dotenv-style files.
    public static func escapeValue(_ value: String) -> String {
        if value.isEmpty { return "\"\"" }
        let needsQuotes =
            value.contains(where: { $0.isWhitespace || $0 == "#" || $0 == "=" || $0 == "\"" || $0 == "'" })
            || value.contains("\n")
        guard needsQuotes else { return value }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }
}
