import Foundation
import UIKit

private final class InsecureSessionDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

private final class URLSessionFactory {
    private let secureSession: URLSession
    private let insecureSession: URLSession
    private let insecureDelegate = InsecureSessionDelegate()

    init() {
        let secureConfiguration = URLSessionConfiguration.default
        secureConfiguration.waitsForConnectivity = true
        secureConfiguration.timeoutIntervalForRequest = 30
        secureConfiguration.timeoutIntervalForResource = 60
        secureSession = URLSession(configuration: secureConfiguration)

        let insecureConfiguration = URLSessionConfiguration.default
        insecureConfiguration.waitsForConnectivity = true
        insecureConfiguration.timeoutIntervalForRequest = 30
        insecureConfiguration.timeoutIntervalForResource = 60
        insecureSession = URLSession(
            configuration: insecureConfiguration,
            delegate: insecureDelegate,
            delegateQueue: nil
        )
    }

    func session(skipTLSVerification: Bool) -> URLSession {
        skipTLSVerification ? insecureSession : secureSession
    }
}

final class PydioAPIClient {
    private let sessionFactory = URLSessionFactory()
    private let logger: Logger
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(logger: Logger) {
        self.logger = logger
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func inspectServer(address: String, skipTLSVerification: Bool) async throws -> ServerDescriptor {
        let normalizedURL = try normalizeServerURL(address)
        try await ping(baseURL: normalizedURL, skipTLSVerification: skipTLSVerification)

        do {
            let bootConf = try await fetchCellsBootConfiguration(
                baseURL: normalizedURL,
                skipTLSVerification: skipTLSVerification
            )
            let oidc = try await fetchOIDCConfiguration(
                baseURL: normalizedURL,
                skipTLSVerification: skipTLSVerification
            )
            let label = bootConf.customWording?.title ?? normalizedURL.host ?? normalizedURL.absoluteString
            return ServerDescriptor(
                id: StateID(serverURL: normalizedURL.absoluteString).encodedID,
                baseURL: normalizedURL,
                skipTLSVerification: skipTLSVerification,
                type: .cells,
                label: label,
                welcomeMessage: bootConf.customWording?.welcomeMessage,
                iconPath: bootConf.customWording?.icon,
                version: bootConf.ajxpVersion,
                customPrimaryColor: bootConf.other?.vanity?.palette?.primary1Color,
                oauthConfiguration: oidc.asOAuthConfiguration()
            )
        } catch {
            let p8BootConf = try await fetchLegacyBootConfiguration(
                baseURL: normalizedURL,
                skipTLSVerification: skipTLSVerification
            )
            let label = p8BootConf.customWording?.title ?? normalizedURL.host ?? normalizedURL.absoluteString
            return ServerDescriptor(
                id: StateID(serverURL: normalizedURL.absoluteString).encodedID,
                baseURL: normalizedURL,
                skipTLSVerification: skipTLSVerification,
                type: .legacyP8,
                label: label,
                welcomeMessage: p8BootConf.customWording?.welcomeMessage,
                iconPath: p8BootConf.customWording?.icon,
                version: p8BootConf.ajxpVersion,
                customPrimaryColor: nil,
                oauthConfiguration: nil
            )
        }
    }

    func exchangeAuthorizationCode(
        server: ServerDescriptor,
        code: String,
        clientID: String,
        redirectURI: String
    ) async throws -> OAuthToken {
        guard let oauth = server.oauthConfiguration else {
            throw AppError.authentication("OAuth is not configured for \(server.hostDisplayName).")
        }

        let formItems = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "client_id", value: clientID)
        ]

        var request = URLRequest(url: oauth.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = formEncodedData(from: formItems)

        let tokenResponse: TokenResponse = try await send(
            request,
            skipTLSVerification: server.skipTLSVerification
        )
        return tokenResponse.asOAuthToken()
    }

    func refreshAccessToken(
        server: ServerDescriptor,
        refreshToken: String,
        clientID: String
    ) async throws -> OAuthToken {
        guard let oauth = server.oauthConfiguration else {
            throw AppError.authentication("OAuth is not configured for \(server.hostDisplayName).")
        }

        let formItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: clientID)
        ]

        var request = URLRequest(url: oauth.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = formEncodedData(from: formItems)

        let tokenResponse: TokenResponse = try await send(
            request,
            skipTLSVerification: server.skipTLSVerification
        )
        return tokenResponse.asOAuthToken()
    }

    func fetchWorkspaces(server: ServerDescriptor, token: OAuthToken) async throws -> [Workspace] {
        let request = WorkspaceSearchRequest(limit: "200", offset: "0")
        let url = try apiURL(server.baseURL, path: "/workspace")
        let response: WorkspaceCollectionResponse = try await sendAuthenticated(
            url: url,
            method: "POST",
            body: request,
            server: server,
            token: token
        )
        return (response.workspaces ?? []).compactMap { workspace in
            guard let slug = workspace.slug, !slug.isEmpty else {
                return nil
            }
            return Workspace(
                id: "\(server.id):\(slug)",
                slug: slug,
                label: workspace.label ?? slug,
                description: workspace.description,
                rootPath: "/" + slug
            )
        }.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    func listNodes(
        in folderStateID: StateID,
        session: AccountSession,
        server: ServerDescriptor,
        token: OAuthToken,
        sortOrder: NodeSortOrder
    ) async throws -> [RemoteNode] {
        let fullPath = try treeBasePath(for: folderStateID)
        let request = BulkMetaRequest(nodePaths: ["\(fullPath)/*"], allMetaProviders: true, limit: 200, offset: 0)
        let url = try apiURL(server.baseURL, path: "/tree/stats")
        let response: BulkMetaResponse = try await sendAuthenticated(
            url: url,
            method: "POST",
            body: request,
            server: server,
            token: token
        )
        let nodes = (response.nodes ?? [])
            .compactMap { $0.asRemoteNode(session: session) }
            .filter { $0.stateID.encodedID != folderStateID.encodedID }
        return sort(nodes: nodes, by: sortOrder)
    }

    func searchNodes(
        query: String,
        from folderStateID: StateID,
        session: AccountSession,
        server: ServerDescriptor,
        token: OAuthToken
    ) async throws -> [RemoteNode] {
        let pathPrefix = try treeBasePath(for: folderStateID)
        let request = TreeSearchRequest(
            details: true,
            from: 0,
            query: TreeQuery(fileName: query, pathPrefix: [pathPrefix]),
            size: 50
        )
        let url = try apiURL(server.baseURL, path: "/search/nodes")
        let response: SearchResponse = try await sendAuthenticated(
            url: url,
            method: "POST",
            body: request,
            server: server,
            token: token
        )
        return (response.results ?? []).compactMap { $0.asRemoteNode(session: session) }
    }

    func fetchBookmarkedNodes(
        session: AccountSession,
        server: ServerDescriptor,
        token: OAuthToken
    ) async throws -> [RemoteNode] {
        let url = try apiURL(server.baseURL, path: "/user-meta/bookmarks")
        let request = UserBookmarksRequest(all: true)
        let response: BulkMetaResponse = try await sendAuthenticated(
            url: url,
            method: "POST",
            body: request,
            server: server,
            token: token
        )
        return (response.nodes ?? [])
            .flatMap { $0.asBookmarkedNodes(session: session) }
            .sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    func createFolder(
        name: String,
        in folderStateID: StateID,
        server: ServerDescriptor,
        token: OAuthToken
    ) async throws {
        guard let workspaceSlug = folderStateID.workspaceSlug else {
            throw AppError.unexpected("Cannot create a folder without a workspace slug.")
        }
        let parentPath = folderStateID.filePath ?? "/"
        let fullPath = normalizeTreePath("\(workspaceSlug)\(parentPath)/\(name)")
        let node = TreeNodePayload(path: fullPath, type: "COLLECTION")
        let body = CreateNodesRequest(nodes: [node], recursive: false)
        let url = try apiURL(server.baseURL, path: "/tree/create")
        try await sendAuthenticatedVoid(url: url, method: "POST", body: body, server: server, token: token)
    }

    func rename(
        node: RemoteNode,
        newName: String,
        server: ServerDescriptor,
        token: OAuthToken
    ) async throws {
        guard let workspaceSlug = node.stateID.workspaceSlug else {
            throw AppError.unexpected("Cannot rename a node with no workspace slug.")
        }
        let sourceFile = node.stateID.filePath ?? "/"
        let parentFolder = (sourceFile as NSString).deletingLastPathComponent
        let normalizedParent = parentFolder.isEmpty ? "/" : parentFolder
        let destination = normalizedParent == "/" ? "/\(newName)" : "\(normalizedParent)/\(newName)"
        let parameters = MoveJobParameters(
            nodes: [normalizeTreePath("\(workspaceSlug)\(sourceFile)")],
            target: normalizeTreePath("\(workspaceSlug)\(destination)"),
            targetParent: false
        )
        let body = UserJobRequest(jobName: "move", jsonParameters: parameters.jsonString())
        let url = try apiURL(server.baseURL, path: "/jobs/user/move")
        try await sendAuthenticatedVoid(url: url, method: "PUT", body: body, server: server, token: token)
    }

    func move(
        nodes: [RemoteNode],
        to targetFolderStateID: StateID,
        server: ServerDescriptor,
        token: OAuthToken
    ) async throws {
        try await runRelocationJob(
            name: "move",
            nodes: nodes,
            targetFolderStateID: targetFolderStateID,
            server: server,
            token: token
        )
    }

    func copy(
        nodes: [RemoteNode],
        to targetFolderStateID: StateID,
        server: ServerDescriptor,
        token: OAuthToken
    ) async throws {
        try await runRelocationJob(
            name: "copy",
            nodes: nodes,
            targetFolderStateID: targetFolderStateID,
            server: server,
            token: token
        )
    }

    func delete(
        nodes: [RemoteNode],
        server: ServerDescriptor,
        token: OAuthToken
    ) async throws {
        let payload = nodes.map { TreeNodePayload(path: normalizeTreePath($0.stateID.path ?? ""), type: nil) }
        let body = DeleteNodesRequest(nodes: payload, recursive: false, removePermanently: false)
        let url = try apiURL(server.baseURL, path: "/tree/delete")
        try await sendAuthenticatedVoid(url: url, method: "POST", body: body, server: server, token: token)
    }

    func setBookmarked(
        node: RemoteNode,
        bookmarked: Bool,
        username: String,
        server: ServerDescriptor,
        token: OAuthToken
    ) async throws {
        guard let nodeUUID = node.uuid?.nonEmpty else {
            throw AppError.unsupported("This node cannot be bookmarked because its UUID is missing.")
        }

        let url = try apiURL(server.baseURL, path: "/user-meta/update")
        if bookmarked {
            let request = UpdateUserMetaRequest(
                metaDatas: [
                    UserMetaRecord(
                        jsonValue: "true",
                        namespace: "bookmark",
                        nodeUuid: nodeUUID,
                        policies: [
                            resourcePolicy(for: nodeUUID, username: username, action: .owner),
                            resourcePolicy(for: nodeUUID, username: username, action: .read),
                            resourcePolicy(for: nodeUUID, username: username, action: .write)
                        ],
                        policiesContextEditable: nil,
                        resolvedNode: nil,
                        uuid: nil
                    )
                ],
                operation: .put
            )
            try await sendAuthenticatedVoid(url: url, method: "PUT", body: request, server: server, token: token)
            return
        }

        let searchURL = try apiURL(server.baseURL, path: "/user-meta/search")
        let searchRequest = SearchUserMetaRequest(
            metaUuids: [],
            namespace: "bookmark",
            nodeUuids: [nodeUUID],
            resourceQuery: nil,
            resourceSubjectOwner: nil
        )
        let existing: UserMetaCollectionResponse = try await sendAuthenticated(
            url: searchURL,
            method: "POST",
            body: searchRequest,
            server: server,
            token: token
        )
        guard let records = existing.metadatas, !records.isEmpty else {
            return
        }

        let deleteRequest = UpdateUserMetaRequest(metaDatas: records, operation: .delete)
        try await sendAuthenticatedVoid(url: url, method: "PUT", body: deleteRequest, server: server, token: token)
    }

    func createOrFetchPublicLink(
        for node: RemoteNode,
        username: String,
        server: ServerDescriptor,
        token: OAuthToken
    ) async throws -> String {
        if let shareUUID = node.shareUUID?.nonEmpty {
            return try await getShareAddress(shareUUID: shareUUID, server: server, token: token)
        }
        guard let nodeUUID = node.uuid?.nonEmpty else {
            throw AppError.unsupported("This node cannot be shared because its UUID is missing.")
        }

        let templateName = node.isImageNode ? "pydio_unique_strip" : "pydio_shared_folder"
        let request = PutShareLinkRequest(
            createPassword: nil,
            passwordEnabled: nil,
            shareLink: ShareLinkResponse(
                accessEnd: nil,
                accessStart: nil,
                currentDownloads: nil,
                description: shareDescription(for: username),
                label: node.name,
                linkHash: nil,
                linkUrl: nil,
                maxDownloads: nil,
                passwordRequired: nil,
                permissions: [.preview, .download],
                policies: [],
                policiesContextEditable: true,
                restrictToTargetUsers: nil,
                rootNodes: [ShareTreeNode(uuid: nodeUUID)],
                targetUsers: nil,
                userLogin: nil,
                userUuid: nil,
                uuid: nil,
                viewTemplateName: templateName
            ),
            updateCustomHash: nil,
            updatePassword: nil
        )
        let url = try apiURL(server.baseURL, path: "/share/link")
        let response: ShareLinkResponse = try await sendAuthenticated(
            url: url,
            method: "PUT",
            body: request,
            server: server,
            token: token
        )
        guard let link = response.linkUrl?.nonEmpty else {
            throw AppError.serverUnreachable("The server created a share without returning a link URL.")
        }
        return resolveShareAddress(link, baseURL: server.baseURL)
    }

    func removePublicLink(
        for node: RemoteNode,
        server: ServerDescriptor,
        token: OAuthToken
    ) async throws {
        guard let shareUUID = node.shareUUID?.nonEmpty else {
            throw AppError.unsupported("This node does not currently expose a removable public link.")
        }
        var request = URLRequest(url: try apiURL(server.baseURL, path: "/share/link/\(shareUUID)"))
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        _ = try await sendRaw(request, skipTLSVerification: server.skipTLSVerification)
    }

    private func runRelocationJob(
        name: String,
        nodes: [RemoteNode],
        targetFolderStateID: StateID,
        server: ServerDescriptor,
        token: OAuthToken
    ) async throws {
        guard !nodes.isEmpty else {
            return
        }
        guard let targetWorkspaceSlug = targetFolderStateID.workspaceSlug else {
            throw AppError.unexpected("Cannot \(name) nodes without a target workspace.")
        }

        let sourcePaths = try nodes.map { node -> String in
            guard let nodePath = node.stateID.path else {
                throw AppError.unexpected("Cannot \(name) a node with no remote path.")
            }
            guard node.stateID.workspaceSlug == targetWorkspaceSlug else {
                throw AppError.unsupported(
                    "Move and copy currently stay inside one workspace, matching the Android contract."
                )
            }
            return normalizeTreePath(nodePath)
        }

        let targetFolder = targetFolderStateID.filePath ?? "/"
        let parameters = MoveJobParameters(
            nodes: sourcePaths,
            target: normalizeTreePath("\(targetWorkspaceSlug)\(targetFolder)"),
            targetParent: true
        )
        let body = UserJobRequest(jobName: name, jsonParameters: parameters.jsonString())
        let url = try apiURL(server.baseURL, path: "/jobs/user/\(name)")
        try await sendAuthenticatedVoid(url: url, method: "PUT", body: body, server: server, token: token)
    }

    private func getShareAddress(
        shareUUID: String,
        server: ServerDescriptor,
        token: OAuthToken
    ) async throws -> String {
        var request = URLRequest(url: try apiURL(server.baseURL, path: "/share/link/\(shareUUID)"))
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        let response: ShareLinkResponse = try await send(request, skipTLSVerification: server.skipTLSVerification)
        guard let link = response.linkUrl?.nonEmpty else {
            throw AppError.serverUnreachable("The server did not return a usable public link address.")
        }
        return resolveShareAddress(link, baseURL: server.baseURL)
    }

    private func resolveShareAddress(_ link: String, baseURL: URL) -> String {
        if let absoluteURL = URL(string: link), absoluteURL.scheme != nil {
            return absoluteURL.absoluteString
        }
        let trimmedBase = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let normalizedLink = link.hasPrefix("/") ? link : "/\(link)"
        return trimmedBase + normalizedLink
    }

    private func shareDescription(for username: String) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Created from BitHub for iOS by \(username) on \(formatter.string(from: Date()))"
    }

    private func resourcePolicy(
        for nodeUUID: String,
        username: String,
        action: ResourcePolicyAction
    ) -> ResourcePolicy {
        ResourcePolicy(
            action: action,
            effect: .allow,
            jsonConditions: nil,
            resource: nodeUUID,
            subject: "user:\(username)",
            id: nil
        )
    }

    private func ping(baseURL: URL, skipTLSVerification: Bool) async throws {
        var request = URLRequest(url: baseURL)
        request.httpMethod = "GET"
        _ = try await sendRaw(request, skipTLSVerification: skipTLSVerification)
    }

    private func fetchCellsBootConfiguration(
        baseURL: URL,
        skipTLSVerification: Bool
    ) async throws -> BootConfigurationResponse {
        var request = URLRequest(url: try apiURL(baseURL, path: "/frontend/bootconf"))
        request.httpMethod = "GET"
        return try await send(request, skipTLSVerification: skipTLSVerification)
    }

    private func fetchOIDCConfiguration(
        baseURL: URL,
        skipTLSVerification: Bool
    ) async throws -> OIDCResponse {
        var request = URLRequest(url: baseURL.appending(path: "oidc/.well-known/openid-configuration"))
        request.httpMethod = "GET"
        return try await send(request, skipTLSVerification: skipTLSVerification)
    }

    private func fetchLegacyBootConfiguration(
        baseURL: URL,
        skipTLSVerification: Bool
    ) async throws -> BootConfigurationResponse {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.path = "/index.php"
        components?.queryItems = [URLQueryItem(name: "get_action", value: "get_boot_conf")]
        guard let url = components?.url else {
            throw AppError.invalidAddress("Could not build legacy boot configuration URL.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        return try await send(request, skipTLSVerification: skipTLSVerification)
    }

    private func sendAuthenticated<T: Decodable, Body: Encodable>(
        url: URL,
        method: String,
        body: Body,
        server: ServerDescriptor,
        token: OAuthToken
    ) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = try encoder.encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        return try await send(request, skipTLSVerification: server.skipTLSVerification)
    }

    private func sendAuthenticatedVoid<Body: Encodable>(
        url: URL,
        method: String,
        body: Body,
        server: ServerDescriptor,
        token: OAuthToken
    ) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = try encoder.encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        _ = try await sendRaw(request, skipTLSVerification: server.skipTLSVerification)
    }

    private func send<T: Decodable>(
        _ request: URLRequest,
        skipTLSVerification: Bool
    ) async throws -> T {
        let (data, _) = try await sendRaw(request, skipTLSVerification: skipTLSVerification)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            logger.error("Decoding failed for \(request.url?.absoluteString ?? "unknown"): \(error)")
            throw AppError.unexpected("The server returned an unexpected response.")
        }
    }

    @discardableResult
    private func sendRaw(
        _ request: URLRequest,
        skipTLSVerification: Bool
    ) async throws -> (Data, HTTPURLResponse) {
        let session = sessionFactory.session(skipTLSVerification: skipTLSVerification)
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppError.unexpected("The server did not return an HTTP response.")
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 401 {
                throw AppError.authentication("Authentication failed with status 401.")
            }
            let message = String(data: data, encoding: .utf8) ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            throw AppError.serverUnreachable(message)
        }
        return (data, httpResponse)
    }

    private func normalizeServerURL(_ address: String) throws -> URL {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AppError.invalidAddress("Server address is empty.")
        }

        let normalizedInput = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard var components = URLComponents(string: normalizedInput) else {
            throw AppError.invalidAddress("Server address is not valid.")
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if let path = components.path.removingPercentEncoding, path == "/" || path.isEmpty {
            components.path = ""
        } else {
            components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !components.path.isEmpty {
                components.path = "/" + components.path
            }
        }
        components.query = nil
        components.fragment = nil
        guard let url = components.url else {
            throw AppError.invalidAddress("Server address is not valid.")
        }
        return url
    }

    private func apiURL(_ baseURL: URL, path: String) throws -> URL {
        baseURL.appending(path: "a\(path)")
    }

    private func treeBasePath(for stateID: StateID) throws -> String {
        guard let path = stateID.path else {
            throw AppError.unexpected("A workspace or folder path is required.")
        }
        let normalized = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !normalized.isEmpty else {
            throw AppError.unexpected("The current path cannot be empty.")
        }
        return normalized
    }

    private func sort(nodes: [RemoteNode], by order: NodeSortOrder) -> [RemoteNode] {
        switch order {
        case .nameAscending:
            return nodes.sorted { compareFoldersFirst(lhs: $0, rhs: $1) { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } }
        case .nameDescending:
            return nodes.sorted { compareFoldersFirst(lhs: $0, rhs: $1) { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedDescending } }
        case .modifiedDescending:
            return nodes.sorted { compareFoldersFirst(lhs: $0, rhs: $1) { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) } }
        case .modifiedAscending:
            return nodes.sorted { compareFoldersFirst(lhs: $0, rhs: $1) { ($0.modifiedAt ?? .distantFuture) < ($1.modifiedAt ?? .distantFuture) } }
        }
    }

    private func compareFoldersFirst(
        lhs: RemoteNode,
        rhs: RemoteNode,
        fallback: (RemoteNode, RemoteNode) -> Bool
    ) -> Bool {
        if lhs.isFolder != rhs.isFolder {
            return lhs.isFolder && !rhs.isFolder
        }
        return fallback(lhs, rhs)
    }

    private func formEncodedData(from items: [URLQueryItem]) -> Data? {
        var components = URLComponents()
        components.queryItems = items
        return components.percentEncodedQuery?.data(using: .utf8)
    }

    private func normalizeTreePath(_ value: String) -> String {
        value
            .replacingOccurrences(of: "//", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

private struct BootConfigurationResponse: Decodable {
    struct CustomWording: Decodable {
        var title: String?
        var icon: String?
        var welcomeMessage: String?
    }

    struct VanityRoot: Decodable {
        struct Vanity: Decodable {
            struct Palette: Decodable {
                var primary1Color: String?
            }

            var palette: Palette?
        }

        var vanity: Vanity?
    }

    var customWording: CustomWording?
    var ajxpVersion: String?
    var other: VanityRoot?
}

private struct OIDCResponse: Decodable {
    var authorizationEndpoint: URL
    var tokenEndpoint: URL
    var revocationEndpoint: URL?

    enum CodingKeys: String, CodingKey {
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case revocationEndpoint = "revocation_endpoint"
    }

    func asOAuthConfiguration() -> OAuthConfiguration {
        OAuthConfiguration(
            authorizeEndpoint: authorizationEndpoint,
            tokenEndpoint: tokenEndpoint,
            revokeEndpoint: revocationEndpoint
        )
    }
}

private struct TokenResponse: Decodable {
    var accessToken: String
    var expiresIn: Double
    var scope: String?
    var idToken: String?
    var refreshToken: String?
    var tokenType: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case scope
        case idToken = "id_token"
        case refreshToken = "refresh_token"
        case tokenType = "token_type"
    }

    func asOAuthToken() -> OAuthToken {
        OAuthToken(
            accessToken: accessToken,
            subject: nil,
            idToken: idToken,
            scope: scope,
            tokenType: tokenType,
            refreshToken: refreshToken,
            expiresIn: expiresIn,
            expirationTime: Date().timeIntervalSince1970 + expiresIn,
            refreshingSince: 0
        )
    }
}

private struct WorkspaceSearchRequest: Encodable {
    var limit: String
    var offset: String
    var operation: String = "OR"
    var queries: [String] = []

    enum CodingKeys: String, CodingKey {
        case limit = "Limit"
        case offset = "Offset"
        case operation = "Operation"
        case queries = "Queries"
    }
}

private struct WorkspaceCollectionResponse: Decodable {
    var total: Int?
    var workspaces: [WorkspaceResponse]?

    enum CodingKeys: String, CodingKey {
        case total = "Total"
        case workspaces = "Workspaces"
    }
}

private struct WorkspaceResponse: Decodable {
    var description: String?
    var label: String?
    var slug: String?

    enum CodingKeys: String, CodingKey {
        case description = "Description"
        case label = "Label"
        case slug = "Slug"
    }
}

private struct BulkMetaRequest: Encodable {
    var nodePaths: [String]
    var allMetaProviders: Bool
    var limit: Int
    var offset: Int

    enum CodingKeys: String, CodingKey {
        case nodePaths = "NodePaths"
        case allMetaProviders = "AllMetaProviders"
        case limit = "Limit"
        case offset = "Offset"
    }
}

private struct BulkMetaResponse: Decodable {
    var nodes: [TreeNodeResponse]?

    enum CodingKeys: String, CodingKey {
        case nodes = "Nodes"
    }
}

private struct SearchResponse: Decodable {
    var results: [TreeNodeResponse]?

    enum CodingKeys: String, CodingKey {
        case results = "Results"
    }
}

private struct UserBookmarksRequest: Encodable {
    var all: Bool

    enum CodingKeys: String, CodingKey {
        case all = "All"
    }
}

private struct TreeSearchRequest: Encodable {
    var details: Bool
    var from: Int
    var query: TreeQuery
    var size: Int

    enum CodingKeys: String, CodingKey {
        case details = "Details"
        case from = "From"
        case query = "Query"
        case size = "Size"
    }
}

private struct TreeQuery: Encodable {
    var fileName: String
    var pathPrefix: [String]

    enum CodingKeys: String, CodingKey {
        case fileName = "FileName"
        case pathPrefix = "PathPrefix"
    }
}

private struct TreeNodeResponse: Codable {
    var appearsIn: [WorkspaceRelativePathResponse]?
    var path: String?
    var type: String?
    var size: String?
    var etag: String?
    var mtime: String?
    var uuid: String?
    var metaStore: [String: JSONValue]?

    enum CodingKeys: String, CodingKey {
        case appearsIn = "AppearsIn"
        case path = "Path"
        case type = "Type"
        case size = "Size"
        case etag = "Etag"
        case mtime = "MTime"
        case uuid = "Uuid"
        case metaStore = "MetaStore"
    }

    func asRemoteNode(session: AccountSession) -> RemoteNode? {
        guard let path else { return nil }
        let normalized = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !normalized.isEmpty else { return nil }
        let fullPath = "/" + normalized
        let stateID = StateID(
            username: session.username,
            serverURL: session.serverURL.absoluteString,
            path: fullPath
        )
        let resolvedName = fullPath.split(separator: "/").last.map(String.init) ?? fullPath
        let date = mtime.flatMap { TimeInterval($0) }.map(Date.init(timeIntervalSince1970:))
        let byteSize = size.flatMap(Int64.init)
        let mime = metaStore?["mime"]?.stringValue ?? metaStore?["mimeType"]?.stringValue
        return RemoteNode(
            stateID: stateID,
            kind: type == "COLLECTION" ? .folder : .file,
            name: resolvedName,
            uuid: uuid,
            mimeType: mime,
            size: byteSize,
            etag: etag,
            modifiedAt: date,
            metadata: metaStore ?? [:]
        )
    }

    func asBookmarkedNodes(session: AccountSession) -> [RemoteNode] {
        guard let appearsIn, !appearsIn.isEmpty else {
            return asRemoteNode(session: session).map { [$0] } ?? []
        }
        return appearsIn.compactMap { location in
            guard let workspaceSlug = location.wsSlug?.nonEmpty else {
                return nil
            }
            let relativePath = location.path?.nonEmpty ?? "/"
            let normalizedRelativePath = relativePath == "/"
                ? "/"
                : (relativePath.hasPrefix("/") ? relativePath : "/\(relativePath)")
            let fullPath = normalizedRelativePath == "/"
                ? "/\(workspaceSlug)"
                : "/\(workspaceSlug)\(normalizedRelativePath)"
            let stateID = StateID(
                username: session.username,
                serverURL: session.serverURL.absoluteString,
                path: fullPath
            )
            let resolvedName = normalizedRelativePath == "/"
                ? (location.wsLabel?.nonEmpty ?? workspaceSlug)
                : (fullPath.split(separator: "/").last.map(String.init) ?? fullPath)
            let date = mtime.flatMap { TimeInterval($0) }.map(Date.init(timeIntervalSince1970:))
            let byteSize = size.flatMap(Int64.init)
            let mime = metaStore?["mime"]?.stringValue ?? metaStore?["mimeType"]?.stringValue
            return RemoteNode(
                stateID: stateID,
                kind: type == "COLLECTION" ? .folder : .file,
                name: resolvedName,
                uuid: uuid,
                mimeType: mime,
                size: byteSize,
                etag: etag,
                modifiedAt: date,
                metadata: metaStore ?? [:]
            )
        }
    }
}

private struct WorkspaceRelativePathResponse: Codable {
    var path: String?
    var wsLabel: String?
    var wsScope: String?
    var wsSlug: String?
    var wsUuid: String?

    enum CodingKeys: String, CodingKey {
        case path = "Path"
        case wsLabel = "WsLabel"
        case wsScope = "WsScope"
        case wsSlug = "WsSlug"
        case wsUuid = "WsUuid"
    }
}

private struct TreeNodePayload: Encodable {
    var path: String
    var type: String?

    enum CodingKeys: String, CodingKey {
        case path = "Path"
        case type = "Type"
    }
}

private struct CreateNodesRequest: Encodable {
    var nodes: [TreeNodePayload]
    var recursive: Bool

    enum CodingKeys: String, CodingKey {
        case nodes = "Nodes"
        case recursive = "Recursive"
    }
}

private struct DeleteNodesRequest: Encodable {
    var nodes: [TreeNodePayload]
    var recursive: Bool
    var removePermanently: Bool

    enum CodingKeys: String, CodingKey {
        case nodes = "Nodes"
        case recursive = "Recursive"
        case removePermanently = "RemovePermanently"
    }
}

private struct MoveJobParameters: Encodable {
    var nodes: [String]
    var target: String
    var targetParent: Bool

    func jsonString() -> String {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(self) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

private struct UserJobRequest: Encodable {
    var jobName: String
    var jsonParameters: String

    enum CodingKeys: String, CodingKey {
        case jobName = "JobName"
        case jsonParameters = "JsonParameters"
    }
}

private struct SearchUserMetaRequest: Encodable {
    var metaUuids: [String]
    var namespace: String?
    var nodeUuids: [String]
    var resourceQuery: JSONValue?
    var resourceSubjectOwner: String?

    enum CodingKeys: String, CodingKey {
        case metaUuids = "MetaUuids"
        case namespace = "Namespace"
        case nodeUuids = "NodeUuids"
        case resourceQuery = "ResourceQuery"
        case resourceSubjectOwner = "ResourceSubjectOwner"
    }
}

private struct UpdateUserMetaRequest: Encodable {
    var metaDatas: [UserMetaRecord]
    var operation: UserMetaOperation

    enum CodingKeys: String, CodingKey {
        case metaDatas = "MetaDatas"
        case operation = "Operation"
    }
}

private enum UserMetaOperation: String, Encodable {
    case put = "PUT"
    case delete = "DELETE"
}

private struct UserMetaCollectionResponse: Decodable {
    var metadatas: [UserMetaRecord]?

    enum CodingKeys: String, CodingKey {
        case metadatas = "Metadatas"
    }
}

private struct UserMetaRecord: Codable {
    var jsonValue: String?
    var namespace: String?
    var nodeUuid: String?
    var policies: [ResourcePolicy]?
    var policiesContextEditable: Bool?
    var resolvedNode: ShareTreeNode?
    var uuid: String?

    enum CodingKeys: String, CodingKey {
        case jsonValue = "JsonValue"
        case namespace = "Namespace"
        case nodeUuid = "NodeUuid"
        case policies = "Policies"
        case policiesContextEditable = "PoliciesContextEditable"
        case resolvedNode = "ResolvedNode"
        case uuid = "Uuid"
    }
}

private struct ResourcePolicy: Codable {
    var action: ResourcePolicyAction?
    var effect: ResourcePolicyEffect?
    var jsonConditions: String?
    var resource: String?
    var subject: String?
    var id: String?

    enum CodingKeys: String, CodingKey {
        case action = "Action"
        case effect = "Effect"
        case jsonConditions = "JsonConditions"
        case resource = "Resource"
        case subject = "Subject"
        case id
    }
}

private enum ResourcePolicyAction: String, Codable {
    case any = "ANY"
    case owner = "OWNER"
    case read = "READ"
    case write = "WRITE"
    case editRules = "EDIT_RULES"
}

private enum ResourcePolicyEffect: String, Codable {
    case deny = "deny"
    case allow = "allow"
}

private struct PutShareLinkRequest: Encodable {
    var createPassword: String?
    var passwordEnabled: Bool?
    var shareLink: ShareLinkResponse?
    var updateCustomHash: String?
    var updatePassword: String?

    enum CodingKeys: String, CodingKey {
        case createPassword = "CreatePassword"
        case passwordEnabled = "PasswordEnabled"
        case shareLink = "ShareLink"
        case updateCustomHash = "UpdateCustomHash"
        case updatePassword = "UpdatePassword"
    }
}

private struct ShareLinkResponse: Codable {
    var accessEnd: String?
    var accessStart: String?
    var currentDownloads: String?
    var description: String?
    var label: String?
    var linkHash: String?
    var linkUrl: String?
    var maxDownloads: String?
    var passwordRequired: Bool?
    var permissions: [ShareLinkAccessType]?
    var policies: [ResourcePolicy]?
    var policiesContextEditable: Bool?
    var restrictToTargetUsers: Bool?
    var rootNodes: [ShareTreeNode]?
    var targetUsers: [String: JSONValue]?
    var userLogin: String?
    var userUuid: String?
    var uuid: String?
    var viewTemplateName: String?

    enum CodingKeys: String, CodingKey {
        case accessEnd = "AccessEnd"
        case accessStart = "AccessStart"
        case currentDownloads = "CurrentDownloads"
        case description = "Description"
        case label = "Label"
        case linkHash = "LinkHash"
        case linkUrl = "LinkUrl"
        case maxDownloads = "MaxDownloads"
        case passwordRequired = "PasswordRequired"
        case permissions = "Permissions"
        case policies = "Policies"
        case policiesContextEditable = "PoliciesContextEditable"
        case restrictToTargetUsers = "RestrictToTargetUsers"
        case rootNodes = "RootNodes"
        case targetUsers = "TargetUsers"
        case userLogin = "UserLogin"
        case userUuid = "UserUuid"
        case uuid = "Uuid"
        case viewTemplateName = "ViewTemplateName"
    }
}

private struct ShareTreeNode: Codable {
    var uuid: String?

    enum CodingKeys: String, CodingKey {
        case uuid = "Uuid"
    }
}

private enum ShareLinkAccessType: String, Codable {
    case noAccess = "NoAccess"
    case preview = "Preview"
    case download = "Download"
    case upload = "Upload"
}
