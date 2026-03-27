import Foundation
import Security

actor JSONStore<Value: Codable & Sendable> {
    private let fileURL: URL
    private let defaultValue: Value
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileURL: URL, defaultValue: Value) {
        self.fileURL = fileURL
        self.defaultValue = defaultValue
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func load() throws -> Value {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try save(defaultValue)
            return defaultValue
        }
        let data = try Data(contentsOf: fileURL)
        if data.isEmpty {
            try save(defaultValue)
            return defaultValue
        }
        return try decoder.decode(Value.self, from: data)
    }

    func save(_ value: Value) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(value)
        try data.write(to: fileURL, options: .atomic)
    }

    @discardableResult
    func update(_ mutate: (inout Value) -> Void) throws -> Value {
        var current = try load()
        mutate(&current)
        try save(current)
        return current
    }
}

final class AppDatabase {
    let sessions: JSONStore<[AccountSession]>
    let servers: JSONStore<[ServerDescriptor]>
    let cachedChildren: JSONStore<[String: [RemoteNode]]>
    let transfers: JSONStore<[TransferRecord]>
    let offlineRoots: JSONStore<[OfflineRootRecord]>
    let jobs: JSONStore<[BackgroundJobRecord]>
    let logs: JSONStore<[LogRecord]>
    let settings: JSONStore<AppSettings>

    init(rootURL: URL) {
        sessions = JSONStore(fileURL: rootURL.appending(path: "sessions.json"), defaultValue: [])
        servers = JSONStore(fileURL: rootURL.appending(path: "servers.json"), defaultValue: [])
        cachedChildren = JSONStore(fileURL: rootURL.appending(path: "cached-children.json"), defaultValue: [:])
        transfers = JSONStore(fileURL: rootURL.appending(path: "transfers.json"), defaultValue: [])
        offlineRoots = JSONStore(fileURL: rootURL.appending(path: "offline-roots.json"), defaultValue: [])
        jobs = JSONStore(fileURL: rootURL.appending(path: "jobs.json"), defaultValue: [])
        logs = JSONStore(fileURL: rootURL.appending(path: "logs.json"), defaultValue: [])
        settings = JSONStore(fileURL: rootURL.appending(path: "settings.json"), defaultValue: AppSettings())
    }
}

final class KeychainStore {
    private let service: String

    init(service: String = "com.bitcare.bithub.ios.keychain") {
        self.service = service
    }

    func set<T: Codable>(_ value: T, for account: String) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw AppError.unexpected("Could not save keychain item for \(account). Status \(status).")
        }
    }

    func value<T: Codable>(for account: String, as type: T.Type) throws -> T? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw AppError.unexpected("Could not load keychain item for \(account). Status \(status).")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }

    func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
