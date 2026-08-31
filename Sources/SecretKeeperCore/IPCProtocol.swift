import Foundation

public enum IPCMethod: String, Codable, Sendable {
    case status
    case listApps
    case grantEnv
    case revokeEnv
    case listGrants
}

public struct IPCRequest: Codable, Sendable {
    public var id: String
    public var method: IPCMethod
    public var worktreePath: String?
    public var app: String?
    public var force: Bool?

    public init(
        id: String = UUID().uuidString,
        method: IPCMethod,
        worktreePath: String? = nil,
        app: String? = nil,
        force: Bool? = nil
    ) {
        self.id = id
        self.method = method
        self.worktreePath = worktreePath
        self.app = app
        self.force = force
    }
}

public struct IPCStatus: Codable, Sendable {
    public var state: VaultState
    public var appRunning: Bool
    public var needsSetup: Bool

    public init(state: VaultState, appRunning: Bool, needsSetup: Bool) {
        self.state = state
        self.appRunning = appRunning
        self.needsSetup = needsSetup
    }
}

public struct IPCGrantResponse: Codable, Sendable {
    public var grantID: String
    public var appName: String
    public var worktreePath: String
    public var symlinkPath: String
    public var envPath: String

    public init(result: GrantResult) {
        self.grantID = result.grant.id.uuidString
        self.appName = result.appName
        self.worktreePath = result.grant.worktreePath
        self.symlinkPath = result.symlinkPath
        self.envPath = result.grant.envPath
    }
}

public struct IPCResponse: Codable, Sendable {
    public var id: String
    public var ok: Bool
    public var error: String?
    public var status: IPCStatus?
    public var apps: [VaultAppSummary]?
    public var grants: [GrantSummary]?
    public var grant: IPCGrantResponse?

    public init(
        id: String,
        ok: Bool,
        error: String? = nil,
        status: IPCStatus? = nil,
        apps: [VaultAppSummary]? = nil,
        grants: [GrantSummary]? = nil,
        grant: IPCGrantResponse? = nil
    ) {
        self.id = id
        self.ok = ok
        self.error = error
        self.status = status
        self.apps = apps
        self.grants = grants
        self.grant = grant
    }

    public static func success(
        id: String,
        status: IPCStatus? = nil,
        apps: [VaultAppSummary]? = nil,
        grants: [GrantSummary]? = nil,
        grant: IPCGrantResponse? = nil
    ) -> IPCResponse {
        IPCResponse(id: id, ok: true, status: status, apps: apps, grants: grants, grant: grant)
    }

    public static func failure(id: String, error: String) -> IPCResponse {
        IPCResponse(id: id, ok: false, error: error)
    }
}

public enum IPCCoding: Sendable {
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public static func encodeLine<T: Encodable>(_ value: T) throws -> Data {
        var data = try encoder.encode(value)
        data.append(contentsOf: [0x0A]) // newline
        return data
    }

    public static func decodeLine<T: Decodable>(_ line: Data, as type: T.Type = T.self) throws -> T {
        try decoder.decode(type, from: line)
    }
}
