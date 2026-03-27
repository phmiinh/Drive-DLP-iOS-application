import Foundation
import XCTest
@testable import BitHub

final class StoreTests: XCTestCase {
    func testJSONStorePersistsMutations() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let store = JSONStore(fileURL: root.appending(path: "settings.json"), defaultValue: AppSettings())

        let initial = try await store.load()
        XCTAssertEqual(initial.oauthClientID, "cells-mobile")

        let updated = try await store.update { value in
            value.applyMeteredNetworkLimits = false
        }
        XCTAssertFalse(updated.applyMeteredNetworkLimits)

        let reloaded = try await store.load()
        XCTAssertFalse(reloaded.applyMeteredNetworkLimits)
    }

    func testAppDatabaseCreatesBackingFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let database = AppDatabase(rootURL: root)

        _ = try await database.sessions.load()
        _ = try await database.settings.load()

        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: "sessions.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: "settings.json").path))
    }
}

