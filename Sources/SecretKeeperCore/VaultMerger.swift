import Foundation

public enum ImportMode: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Keep existing apps; add new ones and fold incoming keys into matching apps.
    case merge
    /// The archive becomes the whole app list; anything not in it is dropped.
    case replace

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .merge: return "Merge"
        case .replace: return "Replace"
        }
    }

    public var detail: String {
        switch self {
        case .merge:
            return "Add apps and keys from the archive. On a key collision the archive wins."
        case .replace:
            return "Replace every app in this vault with the archive's apps."
        }
    }
}

public struct ImportSummary: Sendable, Equatable {
    public var appsAdded: Int = 0
    public var appsUpdated: Int = 0
    public var appsRemoved: Int = 0
    public var secretsAdded: Int = 0
    public var secretsUpdated: Int = 0
    /// Apps whose `rootFolder` does not exist on this Mac — expected when the archive
    /// came from another machine with a different home directory.
    public var appsWithMissingFolders: [String] = []

    public init() {}

    public var isEmpty: Bool {
        appsAdded == 0 && appsUpdated == 0 && appsRemoved == 0
            && secretsAdded == 0 && secretsUpdated == 0
    }

    public var headline: String {
        if isEmpty { return "Nothing changed — the vault already matched the archive." }
        var parts: [String] = []
        if appsAdded > 0 { parts.append("\(appsAdded) app\(appsAdded == 1 ? "" : "s") added") }
        if appsUpdated > 0 { parts.append("\(appsUpdated) app\(appsUpdated == 1 ? "" : "s") updated") }
        if appsRemoved > 0 { parts.append("\(appsRemoved) app\(appsRemoved == 1 ? "" : "s") removed") }
        if secretsAdded > 0 { parts.append("\(secretsAdded) key\(secretsAdded == 1 ? "" : "s") added") }
        if secretsUpdated > 0 { parts.append("\(secretsUpdated) key\(secretsUpdated == 1 ? "" : "s") overwritten") }
        return parts.joined(separator: ", ") + "."
    }
}

public enum VaultMerger: Sendable {
    /// Fold `incoming` apps into `existing` and report what changed.
    ///
    /// Apps match on `id` first, then on case-insensitive name — the same project
    /// registered by hand on two Macs has two different UUIDs. A matched app keeps the
    /// **local** id so existing grants (keyed by app id) stay valid.
    public static func apply(
        incoming: [VaultApp],
        to existing: [VaultApp],
        mode: ImportMode,
        folderExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> (apps: [VaultApp], summary: ImportSummary) {
        var summary = ImportSummary()
        var result: [VaultApp] = mode == .replace ? [] : existing
        var consumedLocalIDs = Set<UUID>()

        for incomingApp in incoming {
            if let index = matchIndex(for: incomingApp, in: existing, skipping: consumedLocalIDs) {
                let localApp = existing[index]
                consumedLocalIDs.insert(localApp.id)

                var merged = localApp
                merged.name = incomingApp.name
                merged.rootFolder = incomingApp.rootFolder
                let (secrets, added, updated) = mergeSecrets(
                    incoming: incomingApp.secrets,
                    into: mode == .replace ? [] : localApp.secrets
                )
                merged.secrets = secrets

                let changed = merged != localApp
                if changed { summary.appsUpdated += 1 }
                summary.secretsAdded += added
                summary.secretsUpdated += updated

                if mode == .replace {
                    result.append(merged)
                } else if let existingIndex = result.firstIndex(where: { $0.id == localApp.id }) {
                    result[existingIndex] = merged
                }
            } else {
                var fresh = incomingApp
                fresh.secrets = dedupedSecrets(incomingApp.secrets)
                result.append(fresh)
                summary.appsAdded += 1
                summary.secretsAdded += fresh.secrets.count
            }
        }

        if mode == .replace {
            let keptIDs = Set(result.map(\.id))
            summary.appsRemoved = existing.filter { !keptIDs.contains($0.id) }.count
        }

        result.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        let incomingNames = Set(incoming.map(\.name))
        summary.appsWithMissingFolders = result
            .filter { incomingNames.contains($0.name) }
            .filter { !$0.rootFolder.isEmpty && !folderExists($0.rootFolder) }
            .map(\.name)

        return (result, summary)
    }

    private static func matchIndex(
        for app: VaultApp,
        in existing: [VaultApp],
        skipping consumed: Set<UUID>
    ) -> Int? {
        if let index = existing.firstIndex(where: { $0.id == app.id && !consumed.contains($0.id) }) {
            return index
        }
        return existing.firstIndex {
            !consumed.contains($0.id)
                && $0.name.localizedCaseInsensitiveCompare(app.name) == .orderedSame
        }
    }

    /// Env keys are case-sensitive. Incoming values win; existing item ids are preserved
    /// so SwiftUI list identity does not churn on import.
    private static func mergeSecrets(
        incoming: [SecretItem],
        into existing: [SecretItem]
    ) -> (secrets: [SecretItem], added: Int, updated: Int) {
        var result = existing
        var added = 0
        var updated = 0

        for item in dedupedSecrets(incoming) {
            if let index = result.firstIndex(where: { $0.key == item.key }) {
                if result[index].value != item.value {
                    result[index].value = item.value
                    updated += 1
                }
            } else {
                result.append(SecretItem(key: item.key, value: item.value))
                added += 1
            }
        }

        result.sort { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
        return (result, added, updated)
    }

    /// Later duplicates win, matching `EnvParser` behaviour.
    private static func dedupedSecrets(_ items: [SecretItem]) -> [SecretItem] {
        var result: [SecretItem] = []
        for item in items {
            if let index = result.firstIndex(where: { $0.key == item.key }) {
                result[index].value = item.value
            } else {
                result.append(item)
            }
        }
        return result.sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
    }
}
