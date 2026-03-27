import Foundation
import XCTest
@testable import BitHub

final class RemoteNodeMetadataTests: XCTestCase {
    func testCellsMetadataExposesBookmarkAndShareFlags() {
        let node = RemoteNode(
            stateID: StateID(
                username: "alice",
                serverURL: "https://demo.example.com",
                path: "/common/report.pdf"
            ),
            kind: .file,
            name: "report.pdf",
            uuid: "node-1",
            mimeType: "application/pdf",
            size: 1024,
            etag: "etag-1",
            modifiedAt: nil,
            metadata: [
                "bookmark": .string("true"),
                "workspaces_shares": .string("[{\"Scope\":3,\"UUID\":\"share-123\"}]")
            ]
        )

        XCTAssertTrue(node.isBookmarked)
        XCTAssertTrue(node.isShared)
        XCTAssertEqual(node.shareUUID, "share-123")
    }

    func testLegacyMetadataExposesBookmarkAndShareFlags() {
        let node = RemoteNode(
            stateID: StateID(
                username: "bob",
                serverURL: "https://legacy.example.com",
                path: "/common/photo.jpg"
            ),
            kind: .file,
            name: "photo.jpg",
            uuid: nil,
            mimeType: "image/jpeg",
            size: 2048,
            etag: nil,
            modifiedAt: nil,
            metadata: [
                "ajxp_bookmarked": .string("true"),
                "ajxp_shared": .string("true"),
                "share_link": .string("https://legacy.example.com/public/photo")
            ]
        )

        XCTAssertTrue(node.isBookmarked)
        XCTAssertTrue(node.isShared)
        XCTAssertTrue(node.isImageNode)
        XCTAssertEqual(node.publicLinkAddress, "https://legacy.example.com/public/photo")
    }
}
