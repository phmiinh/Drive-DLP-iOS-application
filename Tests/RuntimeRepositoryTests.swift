import Foundation
import XCTest
@testable import BitHub

final class RuntimeRepositoryTests: XCTestCase {
    func testOfflineRepositoryTogglePersistsRoots() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let database = AppDatabase(rootURL: root)
        let repository = OfflineRepository(store: database.offlineRoots)

        let stateID = StateID(
            username: "alice",
            serverURL: "https://demo.example.com",
            path: "/common/spec.pdf"
        )
        let node = RemoteNode(
            stateID: stateID,
            kind: .file,
            name: "spec.pdf",
            uuid: nil,
            mimeType: "application/pdf",
            size: 2048,
            etag: nil,
            modifiedAt: Date(),
            metadata: [:]
        )

        try await repository.toggle(node: node, accountID: stateID.accountID, enabled: true)
        let pinned = try await repository.roots(accountID: stateID.accountID)
        XCTAssertEqual(pinned.count, 1)
        XCTAssertEqual(pinned.first?.encodedState, stateID.encodedID)

        try await repository.toggle(node: node, accountID: stateID.accountID, enabled: false)
        let cleared = try await repository.roots(accountID: stateID.accountID)
        XCTAssertTrue(cleared.isEmpty)
    }

    func testJobRepositoryLifecyclePersistsStatus() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let database = AppDatabase(rootURL: root)
        let repository = JobRepository(store: database.jobs, logger: Logger())

        let job = try await repository.create(
            owner: "demo-account",
            template: "offline.fullsync",
            label: "Full sync"
        )
        try await repository.launched(jobID: job.id)
        _ = try await repository.update(jobID: job.id) { current in
            current.progress = 2
            current.total = 5
            current.progressMessage = "Preparing files"
        }
        try await repository.complete(
            jobID: job.id,
            status: .done,
            message: "Completed",
            progressMessage: "All files prepared"
        )

        let jobs = try await repository.list()
        XCTAssertEqual(jobs.first?.status, .done)
        XCTAssertEqual(jobs.first?.message, "Completed")
        XCTAssertEqual(jobs.first?.progress, 5)
    }
}
