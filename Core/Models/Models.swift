import Foundation

enum RemoteServerType: String, Codable, Sendable {
    case cells
    case legacyP8
}

enum AccountAuthStatus: String, Codable, Sendable {
    case new
    case noCredentials
    case unauthorized
    case expired
    case refreshing
    case connected
}

enum SessionLifecycleState: String, Codable, Sendable {
    case foreground
    case background
    case paused
}

enum TransferKind: String, Codable, Sendable {
    case upload
    case download
}

enum TransferStatus: String, Codable, Sendable {
    case queued
    case locallyCached
    case processing
    case paused
    case cancelled
    case done
    case error
}

enum NodeSortOrder: String, Codable, Sendable, CaseIterable {
    case nameAscending
    case nameDescending
    case modifiedDescending
    case modifiedAscending
}

enum OfflineRootStatus: String, Codable, Sendable {
    case new
    case active
    case lost
}

enum BackgroundJobStatus: String, Codable, Sendable {
    case new
    case processing
    case done
    case warning
    case cancelled
    case error
    case timeout
}

enum LogLevel: String, Codable, Sendable {
    case debug
    case info
    case warning
    case error
}

enum JSONValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    var stringValue: String? {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            return String(value)
        case .bool(let value):
            return String(value)
        case .object, .array, .null:
            return nil
        }
    }
}

struct OAuthConfiguration: Codable, Hashable, Sendable {
    var authorizeEndpoint: URL
    var tokenEndpoint: URL
    var revokeEndpoint: URL?
    var redirectURI: String = "cellsauth://callback"
    var audience: String?
    var scope: String = "openid email offline profile pydio"
}

struct OAuthToken: Codable, Hashable, Sendable {
    var accessToken: String
    var subject: String?
    var idToken: String?
    var scope: String?
    var tokenType: String
    var refreshToken: String?
    var expiresIn: TimeInterval
    var expirationTime: TimeInterval
    var refreshingSince: TimeInterval

    var isExpired: Bool {
        expirationTime > 0 && Date().timeIntervalSince1970 >= expirationTime
    }
}

struct LegacyP8Credentials: Codable, Hashable, Sendable {
    var username: String
    var password: String
}

struct StateID: Codable, Hashable, Identifiable, Sendable, CustomStringConvertible {
    static let none = StateID(serverURL: "undefined://server")

    var username: String?
    var serverURL: String
    var path: String?

    var id: String {
        encodedID
    }

    var encodedID: String {
        var components: [String] = []
        if let username, !username.isEmpty {
            components.append(Self.encode(username))
        }
        components.append(Self.encode(serverURL))
        if let path, !path.isEmpty, path != "/" {
            components.append(Self.encode(path))
        }
        return components.joined(separator: "@")
    }

    var accountID: String {
        var components: [String] = []
        if let username, !username.isEmpty {
            components.append(Self.encode(username))
        }
        components.append(Self.encode(serverURL))
        return components.joined(separator: "@")
    }

    var account: StateID {
        StateID(username: username, serverURL: serverURL, path: nil)
    }

    var workspaceSlug: String? {
        let value = normalizedPath
        guard !value.isEmpty else { return nil }
        return value.split(separator: "/").first.map(String.init)
    }

    var filePath: String? {
        let value = normalizedPath
        guard !value.isEmpty else { return nil }
        let components = value.split(separator: "/")
        guard components.count > 1 else { return "/" }
        return "/" + components.dropFirst().joined(separator: "/")
    }

    var fileName: String? {
        guard let filePath, filePath != "/" else { return nil }
        return filePath.split(separator: "/").last.map(String.init)
    }

    var description: String {
        var value = username.map { "\($0)@" } ?? ""
        value += serverURL
        if let path, !path.isEmpty, path != "/" {
            value += path
        }
        return value
    }

    init(serverURL: String) {
        self.username = nil
        self.serverURL = serverURL
        self.path = nil
    }

    init(username: String?, serverURL: String, path: String? = nil) {
        self.username = username
        self.serverURL = serverURL
        self.path = path
    }

    init?(encodedID: String) {
        guard !encodedID.isEmpty else {
            return nil
        }
        let parts = encodedID.split(separator: "@", omittingEmptySubsequences: false).map(String.init)
        switch parts.count {
        case 1:
            self.init(serverURL: Self.decode(parts[0]))
        case 2:
            self.init(username: Self.decode(parts[0]), serverURL: Self.decode(parts[1]), path: nil)
        case 3:
            self.init(username: Self.decode(parts[0]), serverURL: Self.decode(parts[1]), path: Self.decode(parts[2]))
        default:
            return nil
        }
    }

    func withPath(_ newPath: String?) -> StateID {
        StateID(username: username, serverURL: serverURL, path: newPath)
    }

    func child(_ fileName: String) -> StateID {
        guard !fileName.contains("/") else {
            return self
        }
        let basePath: String
        if let path, !path.isEmpty, path != "/" {
            basePath = path.hasSuffix("/") ? path : path + "/"
        } else {
            basePath = "/"
        }
        return withPath(basePath + fileName)
    }

    func parent() -> StateID {
        guard let path, !path.isEmpty, path != "/" else {
            return account
        }
        let parts = path.split(separator: "/")
        guard parts.count > 1 else {
            return account
        }
        let newValue = "/" + parts.dropLast().joined(separator: "/")
        return withPath(newValue)
    }

    private var normalizedPath: String {
        (path ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
    }

    private static func decode(_ value: String) -> String {
        value.removingPercentEncoding ?? value
    }
}

struct ServerDescriptor: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var baseURL: URL
    var skipTLSVerification: Bool
    var type: RemoteServerType
    var label: String
    var welcomeMessage: String?
    var iconPath: String?
    var version: String?
    var customPrimaryColor: String?
    var oauthConfiguration: OAuthConfiguration?

    var hostDisplayName: String {
        baseURL.host ?? baseURL.absoluteString
    }
}

struct AccountSession: Codable, Hashable, Identifiable, Sendable {
    var id: String { accountID }

    var accountID: String
    var username: String
    var serverID: String
    var serverURL: URL
    var authStatus: AccountAuthStatus
    var lifecycleState: SessionLifecycleState
    var isReachable: Bool
    var isLegacy: Bool
    var skipTLSVerification: Bool
    var serverLabel: String
    var welcomeMessage: String?
    var customPrimaryColor: String?
    var createdAt: Date
    var updatedAt: Date

    var stateID: StateID {
        StateID(username: username, serverURL: serverURL.absoluteString)
    }
}

struct Workspace: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var slug: String
    var label: String
    var description: String?
    var rootPath: String
}

struct RemoteNode: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case file
        case folder
    }

    var id: String { stateID.encodedID }

    var stateID: StateID
    var kind: Kind
    var name: String
    var uuid: String?
    var mimeType: String?
    var size: Int64?
    var etag: String?
    var modifiedAt: Date?
    var metadata: [String: JSONValue]

    var isFolder: Bool {
        kind == .folder
    }

    var isBookmarked: Bool {
        (metadata.truthyValue(for: "bookmark") == true)
            || (metadata.truthyValue(for: "ajxp_bookmarked") == true)
    }

    var shareUUID: String? {
        metadata["share_Uuid"]?.stringValue?.nonEmpty
            ?? metadata["share_uuid"]?.stringValue?.nonEmpty
            ?? workspaceShareInfo?.uuid
    }

    var publicLinkAddress: String? {
        metadata["share_link"]?.stringValue?.nonEmpty
    }

    var isShared: Bool {
        (metadata.truthyValue(for: "shared") == true)
            || (metadata.truthyValue(for: "ajxp_shared") == true)
            || shareUUID != nil
            || publicLinkAddress != nil
    }

    var isImageNode: Bool {
        metadata.truthyValue(for: "is_image")
            ?? (mimeType?.hasPrefix("image/") ?? false)
    }

    private var workspaceShareInfo: WorkspaceShareInfo? {
        guard let rawValue = metadata["workspaces_shares"]?.stringValue?.data(using: .utf8) else {
            return nil
        }
        guard
            let objects = try? JSONSerialization.jsonObject(with: rawValue) as? [[String: Any]]
        else {
            return nil
        }
        for object in objects {
            let scope = object["Scope"] as? Double
            guard scope == 3 else {
                continue
            }
            return WorkspaceShareInfo(uuid: object["UUID"] as? String)
        }
        return nil
    }

    private struct WorkspaceShareInfo {
        let uuid: String?
    }
}

struct TransferRecord: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var kind: TransferKind
    var status: TransferStatus
    var accountID: String
    var stateID: String?
    var localURL: URL?
    var displayName: String
    var bytesTotal: Int64?
    var bytesTransferred: Int64
    var errorMessage: String?
    var createdAt: Date
    var updatedAt: Date
}

struct OfflineRootRecord: Codable, Hashable, Identifiable, Sendable {
    var id: String { encodedState }

    var encodedState: String
    var accountID: String
    var displayName: String
    var isFolder: Bool
    var status: OfflineRootStatus
    var localModificationDate: Date?
    var lastCheckDate: Date?
    var message: String?
    var storage: String

    var stateID: StateID? {
        StateID(encodedID: encodedState)
    }
}

struct BackgroundJobRecord: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var owner: String
    var template: String
    var label: String
    var parentID: UUID?
    var status: BackgroundJobStatus
    var progress: Int64
    var total: Int64
    var message: String?
    var progressMessage: String?
    var createdAt: Date
    var updatedAt: Date
    var startedAt: Date?
    var finishedAt: Date?

    var progressFraction: Double? {
        guard total > 0 else { return nil }
        return min(max(Double(progress) / Double(total), 0), 1)
    }
}

struct LogRecord: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var timestamp: Date
    var level: LogLevel
    var tag: String?
    var message: String
    var callerID: String?
}

struct AppSettings: Codable, Hashable, Sendable {
    var appDisplayName: String = "BitHub"
    var websiteURL: URL? = URL(string: "https://bitcare.com.vn")
    var oauthClientID: String = "cells-mobile"
    var oauthRedirectURI: String = "cellsauth://callback"
    var applyMeteredNetworkLimits: Bool = true
    var downloadThumbnailsOnMetered: Bool = false
    var useDynamicServerColors: Bool = true
}

enum AppPhase: Sendable {
    case launching
    case onboarding
    case authenticated(AccountSession)
    case accounts
}

enum LoadState<Value: Sendable>: Sendable {
    case idle
    case loading
    case loaded(Value)
    case failed(String)
}

enum AppError: LocalizedError {
    case invalidAddress(String)
    case serverUnreachable(String)
    case unsupported(String)
    case authentication(String)
    case unexpected(String)

    var errorDescription: String? {
        switch self {
        case .invalidAddress(let message),
                .serverUnreachable(let message),
                .unsupported(let message),
                .authentication(let message),
                .unexpected(let message):
            return message
        }
    }
}

private extension Dictionary where Key == String, Value == JSONValue {
    func truthyValue(for key: String) -> Bool? {
        guard let value = self[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return nil
        }
        switch value {
        case "true", "1", "yes", "on":
            return true
        case "false", "0", "no", "off":
            return false
        default:
            return nil
        }
    }
}

extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
