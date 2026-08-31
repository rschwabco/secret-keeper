import Foundation

public enum EnvParser: Sendable {
    /// Parse dotenv-style content into secret items.
    /// Supports `KEY=VALUE`, optional `export `, single/double quotes, comments, blank lines.
    public static func parse(_ content: String) -> [SecretItem] {
        var items: [SecretItem] = []
        var seen = Set<String>()

        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            // Strip UTF-8 BOM on first line if present
            if items.isEmpty && seen.isEmpty, line.hasPrefix("\u{FEFF}") {
                line.removeFirst()
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            var working = trimmed
            if working.hasPrefix("export ") {
                working = String(working.dropFirst("export ".count))
                    .trimmingCharacters(in: .whitespaces)
            }

            guard let eq = working.firstIndex(of: "=") else { continue }
            let key = String(working[..<eq]).trimmingCharacters(in: .whitespaces)
            guard isValidKey(key) else { continue }

            var valuePart = String(working[working.index(after: eq)...])
            valuePart = parseValue(valuePart)

            // Later duplicates win (common dotenv behavior)
            if seen.contains(key), let index = items.firstIndex(where: { $0.key == key }) {
                items[index].value = valuePart
            } else {
                seen.insert(key)
                items.append(SecretItem(key: key, value: valuePart))
            }
        }

        return items
    }

    /// Merge parsed secrets into existing ones. Matching keys are updated; new keys are appended.
    public static func merge(existing: [SecretItem], parsed: [SecretItem]) -> [SecretItem] {
        var result = existing
        for item in parsed {
            if let index = result.firstIndex(where: { $0.key == item.key }) {
                result[index].value = item.value
            } else {
                result.append(SecretItem(key: item.key, value: item.value))
            }
        }
        return result
    }

    private static func isValidKey(_ key: String) -> Bool {
        guard !key.isEmpty else { return false }
        // Typical env key: letters, digits, underscore; must not start with digit
        let pattern = #"^[A-Za-z_][A-Za-z0-9_]*$"#
        return key.range(of: pattern, options: .regularExpression) != nil
    }

    private static func parseValue(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return "" }

        if value.hasPrefix("\"") {
            return unquote(value, quote: "\"")
        }
        if value.hasPrefix("'") {
            return unquote(value, quote: "'")
        }

        // Unquoted: strip inline comment (space/tab then #)
        if let commentRange = value.range(of: #"\s+#"#, options: .regularExpression) {
            return String(value[..<commentRange.lowerBound])
                .trimmingCharacters(in: .whitespaces)
        }
        return value
    }

    private static func unquote(_ value: String, quote: Character) -> String {
        var chars = Array(value)
        guard chars.first == quote else { return value }
        chars.removeFirst()

        var result = ""
        var escaped = false
        var closed = false

        for ch in chars {
            if escaped {
                switch ch {
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "t": result.append("\t")
                case "\\": result.append("\\")
                default: result.append(ch)
                }
                escaped = false
                continue
            }
            if ch == "\\" && quote == "\"" {
                escaped = true
                continue
            }
            if ch == quote {
                closed = true
                break
            }
            result.append(ch)
        }

        // If quotes weren't closed, return original trimmed content without leading quote heuristic
        if !closed && quote == "'" {
            // single-quoted without close — treat rest as literal after leading quote
            return String(value.dropFirst())
        }
        return result
    }
}
