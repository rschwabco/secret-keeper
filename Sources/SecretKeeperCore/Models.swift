import Foundation

/// A registered project whose secrets are bound to a root folder on disk.
public struct VaultApp: Identifiable, Codable, Sendable, Equatable, Hashable {
    public var id: UUID
    public var name: String
    public var rootFolder: String
    public var secrets: [SecretItem]

    public init(
        id: UUID = UUID(),
        name: String,
        rootFolder: String,
        secrets: [SecretItem] = []
    ) {
        self.id = id
        self.name = name
        self.rootFolder = rootFolder
        self.secrets = secrets
    }
}

public struct SecretItem: Identifiable, Codable, Sendable, Equatable, Hashable {
    public var id: UUID
    public var key: String
    public var value: String

    public init(id: UUID = UUID(), key: String, value: String) {
        self.id = id
        self.key = key
        self.value = value
    }
}

public struct Grant: Identifiable, Codable, Sendable, Equatable, Hashable {
    public var id: UUID
    public var appID: UUID
    public var worktreePath: String
    public var envPath: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        appID: UUID,
        worktreePath: String,
        envPath: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.appID = appID
        self.worktreePath = worktreePath
        self.envPath = envPath
        self.createdAt = createdAt
    }
}

/// Plaintext vault payload (only held in memory while unlocked).
public struct VaultPayload: Codable, Sendable, Equatable {
    public var apps: [VaultApp]
    public var grants: [Grant]

    public init(apps: [VaultApp] = [], grants: [Grant] = []) {
        self.apps = apps
        self.grants = grants
    }
}

/// Safe summary of an app for MCP / UI lists (no secret values).
public struct VaultAppSummary: Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var rootFolder: String
    public var secretKeys: [String]

    public init(app: VaultApp) {
        self.id = app.id
        self.name = app.name
        self.rootFolder = app.rootFolder
        self.secretKeys = app.secrets.map(\.key).sorted()
    }
}

public struct GrantSummary: Codable, Sendable, Equatable {
    public var id: UUID
    public var appID: UUID
    public var appName: String
    public var worktreePath: String
    public var envPath: String
    public var createdAt: Date

    public init(grant: Grant, appName: String) {
        self.id = grant.id
        self.appID = grant.appID
        self.appName = appName
        self.worktreePath = grant.worktreePath
        self.envPath = grant.envPath
        self.createdAt = grant.createdAt
    }
}

public enum VaultState: String, Codable, Sendable {
    case locked
    case unlocked
    case unavailable
}
