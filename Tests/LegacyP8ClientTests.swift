import Foundation
import XCTest
@testable import BitHub

final class LegacyP8ClientTests: XCTestCase {
    func testWorkspaceParserKeepsUserFacingWorkspaces() throws {
        let client = LegacyP8Client(logger: Logger())
        let server = ServerDescriptor(
            id: "https%3A%2F%2Flegacy.example.com",
            baseURL: URL(string: "https://legacy.example.com")!,
            skipTLSVerification: false,
            type: .legacyP8,
            label: "Legacy",
            welcomeMessage: nil,
            iconPath: nil,
            version: "8.2.0",
            customPrimaryColor: nil,
            oauthConfiguration: nil
        )

        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <root>
            <repo id="ws1" repositorySlug="common-files" access_type="fs">
                <label>Common Files</label>
                <description>Team documents</description>
            </repo>
            <repo id="ws2" repositorySlug="settings" access_type="settings">
                <label>Settings</label>
            </repo>
        </root>
        """

        let workspaces = try client.debugParseWorkspaces(xml, server: server)
        XCTAssertEqual(workspaces.count, 1)
        XCTAssertEqual(workspaces.first?.slug, "common-files")
        XCTAssertEqual(workspaces.first?.label, "Common Files")
        XCTAssertEqual(workspaces.first?.rootPath, "/common-files")
    }

    func testNodeParserBuildsStateIdentifiersFromLegacyTreeXML() throws {
        let client = LegacyP8Client(logger: Logger())
        let session = AccountSession(
            accountID: "alice@legacy",
            username: "alice",
            serverID: "legacy",
            serverURL: URL(string: "https://legacy.example.com")!,
            authStatus: .connected,
            lifecycleState: .foreground,
            isReachable: true,
            isLegacy: true,
            skipTLSVerification: false,
            serverLabel: "Legacy",
            welcomeMessage: nil,
            customPrimaryColor: nil,
            createdAt: Date(),
            updatedAt: Date()
        )

        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tree filename="/">
            <tree filename="/Design.pdf" is_file="true" bytesize="42" ajxp_modiftime="1700000000" ajxp_mime="application/pdf">
                <label>Design.pdf</label>
            </tree>
            <tree filename="/Projects" is_file="false" ajxp_modiftime="1700000001">
                <label>Projects</label>
            </tree>
        </tree>
        """

        let nodes = try client.debugParseNodes(xml, workspaceSlug: "common-files", session: session)
        XCTAssertEqual(nodes.count, 2)
        XCTAssertEqual(nodes[0].stateID.path, "/common-files/Design.pdf")
        XCTAssertEqual(nodes[0].kind, .file)
        XCTAssertEqual(nodes[0].size, 42)
        XCTAssertEqual(nodes[1].stateID.path, "/common-files/Projects")
        XCTAssertEqual(nodes[1].kind, .folder)
    }
}
