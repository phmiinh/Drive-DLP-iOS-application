import XCTest
@testable import BitHub

final class StateIDTests: XCTestCase {
    func testRoundTripEncoding() {
        let original = StateID(
            username: "alice",
            serverURL: "https://demo.example.com",
            path: "/common/projects/spec.pdf"
        )

        let decoded = StateID(encodedID: original.encodedID)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded?.workspaceSlug, "common")
        XCTAssertEqual(decoded?.filePath, "/projects/spec.pdf")
        XCTAssertEqual(decoded?.fileName, "spec.pdf")
    }

    func testChildAndParentTransitions() {
        let root = StateID(username: "alice", serverURL: "https://demo.example.com", path: "/common")
        let child = root.child("Design")

        XCTAssertEqual(child.path, "/common/Design")
        XCTAssertEqual(child.parent().path, "/common")
        XCTAssertEqual(root.parent().path, nil)
    }
}

