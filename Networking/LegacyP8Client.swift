import Foundation
import FoundationXML
import UniformTypeIdentifiers

private struct LegacyP8SessionContext {
    var secureToken: String
    var cookieHeader: String
}

private struct LegacyP8Pagination {
    var currentPage: Int
    var totalPages: Int

    var hasMorePages: Bool {
        currentPage < totalPages
    }

    var nextPageSuffix: String {
        "%23\(currentPage + 1)"
    }
}

final class LegacyP8Client {
    private let sessionFactory = TransferSessionFactory()
    private let logger: Logger
    private let uploadRequestSizeLimit = 2 * 1024 * 1204
    private let excludedWorkspaceAccessTypes: Set<String> = [
        "directory",
        "ajxp_conf",
        "ajxp_shared",
        "mysql",
        "imap",
        "jsapi",
        "ajxp_user",
        "ajxp_home",
        "homepage",
        "settings",
        "ajxp_admin",
        "inbox"
    ]

    init(logger: Logger) {
        self.logger = logger
    }

    func authenticate(
        server: ServerDescriptor,
        username: String,
        password: String
    ) async throws {
        let credentials = LegacyP8Credentials(username: username, password: password)
        let context = try await authenticatedContext(server: server, credentials: credentials)
        _ = try await fetchWorkspaces(server: server, context: context)
        logger.info("Authenticated legacy P8 user \(username) on \(server.hostDisplayName)")
    }

    func fetchWorkspaces(
        server: ServerDescriptor,
        credentials: LegacyP8Credentials
    ) async throws -> [Workspace] {
        let context = try await authenticatedContext(server: server, credentials: credentials)
        return try await fetchWorkspaces(server: server, context: context)
    }

    func listNodes(
        in folderStateID: StateID,
        session: AccountSession,
        server: ServerDescriptor,
        credentials: LegacyP8Credentials,
        sortOrder: NodeSortOrder
    ) async throws -> [RemoteNode] {
        let context = try await authenticatedContext(server: server, credentials: credentials)
        let workspaceSlug = try workspaceSlug(from: folderStateID)
        let baseDirectory = normalizedLegacyDirectory(from: folderStateID)

        var currentDirectory = baseDirectory
        var nodes: [RemoteNode] = []

        while true {
            let data = try await sendFormRequest(
                server: server,
                context: context,
                action: "ls",
                parameters: [
                    "options": "al",
                    "dir": currentDirectory,
                    "tmp_repository_id": workspaceSlug
                ]
            )
            let parsed = try parseNodes(
                data: data,
                workspaceSlug: workspaceSlug,
                session: session
            )
            nodes.append(contentsOf: parsed.nodes)
            guard let pagination = parsed.pagination, pagination.hasMorePages else {
                break
            }
            currentDirectory = baseDirectory + pagination.nextPageSuffix
        }

        return sort(nodes: nodes, by: sortOrder)
    }

    func searchNodes(
        query: String,
        from folderStateID: StateID,
        session: AccountSession,
        server: ServerDescriptor,
        credentials: LegacyP8Credentials
    ) async throws -> [RemoteNode] {
        let context = try await authenticatedContext(server: server, credentials: credentials)
        let workspaceSlug = try workspaceSlug(from: folderStateID)
        var parameters: [String: String] = [
            "query": query,
            "tmp_repository_id": workspaceSlug
        ]
        let directory = normalizedLegacyDirectory(from: folderStateID)
        if directory != "/" {
            parameters["dir"] = directory
        }

        let data = try await sendFormRequest(
            server: server,
            context: context,
            action: "search",
            parameters: parameters
        )
        let parsed = try parseNodes(
            data: data,
            workspaceSlug: workspaceSlug,
            session: session
        )
        return sort(nodes: parsed.nodes, by: .nameAscending)
    }

    func fetchBookmarkedNodes(
        session: AccountSession,
        server: ServerDescriptor,
        credentials: LegacyP8Credentials
    ) async throws -> [RemoteNode] {
        let context = try await authenticatedContext(server: server, credentials: credentials)
        let workspaces = try await fetchWorkspaces(server: server, context: context)
        var collected: [RemoteNode] = []

        for workspace in workspaces {
            var currentDirectory = "/"

            while true {
                let data = try await sendFormRequest(
                    server: server,
                    context: context,
                    action: "search_by_keyword",
                    parameters: [
                        "options": "al",
                        "dir": currentDirectory,
                        "tmp_repository_id": workspace.slug,
                        "field": "ajxp_bookmarked"
                    ]
                )
                let parsed = try parseNodes(
                    data: data,
                    workspaceSlug: workspace.slug,
                    session: session
                )
                collected.append(contentsOf: parsed.nodes)
                guard let pagination = parsed.pagination, pagination.hasMorePages else {
                    break
                }
                currentDirectory = "/" + pagination.nextPageSuffix
            }
        }

        return sort(nodes: deduplicate(nodes: collected), by: .nameAscending)
    }

    func createFolder(
        name: String,
        in folderStateID: StateID,
        server: ServerDescriptor,
        credentials: LegacyP8Credentials
    ) async throws {
        let context = try await authenticatedContext(server: server, credentials: credentials)
        let workspaceSlug = try workspaceSlug(from: folderStateID)

        _ = try await sendFormRequest(
            server: server,
            context: context,
            action: "mkdir",
            parameters: [
                "tmp_repository_id": workspaceSlug,
                "dir": normalizedLegacyDirectory(from: folderStateID),
                "dirname": name
            ]
        )
    }

    func rename(
        node: RemoteNode,
        newName: String,
        server: ServerDescriptor,
        credentials: LegacyP8Credentials
    ) async throws {
        let context = try await authenticatedContext(server: server, credentials: credentials)
        let workspaceSlug = try workspaceSlug(from: node.stateID)

        _ = try await sendFormRequest(
            server: server,
            context: context,
            action: "rename",
            parameters: [
                "tmp_repository_id": workspaceSlug,
                "file": normalizedLegacyFilePath(from: node.stateID),
                "filename_new": newName
            ]
        )
    }

    func move(
        nodes: [RemoteNode],
        to targetFolderStateID: StateID,
        server: ServerDescriptor,
        credentials: LegacyP8Credentials
    ) async throws {
        try await relocate(
            action: "move",
            nodes: nodes,
            targetFolderStateID: targetFolderStateID,
            server: server,
            credentials: credentials,
            extraParameters: ["force_copy_delete": "true"]
        )
    }

    func copy(
        nodes: [RemoteNode],
        to targetFolderStateID: StateID,
        server: ServerDescriptor,
        credentials: LegacyP8Credentials
    ) async throws {
        try await relocate(
            action: "copy",
            nodes: nodes,
            targetFolderStateID: targetFolderStateID,
            server: server,
            credentials: credentials,
            extraParameters: [:]
        )
    }

    func setBookmarked(
        node: RemoteNode,
        bookmarked: Bool,
        server: ServerDescriptor,
        credentials: LegacyP8Credentials
    ) async throws {
        let context = try await authenticatedContext(server: server, credentials: credentials)
        let workspaceSlug = try workspaceSlug(from: node.stateID)

        _ = try await sendFormRequest(
            server: server,
            context: context,
            action: "get_bookmarks",
            parameters: [
                "bm_action": bookmarked ? "add_bookmark" : "delete_bookmark",
                "bm_path": normalizedLegacyFilePath(from: node.stateID),
                "tmp_repository_id": workspaceSlug
            ]
        )
    }

    func createOrFetchPublicLink(
        for node: RemoteNode,
        server: ServerDescriptor,
        credentials: LegacyP8Credentials
    ) async throws -> String {
        if node.isShared, let existing = try await publicLinkAddress(for: node.stateID, server: server, credentials: credentials) {
            return existing
        }

        let context = try await authenticatedContext(server: server, credentials: credentials)
        let workspaceSlug = try workspaceSlug(from: node.stateID)
        let shareDescription = "Created from BitHub for iOS on \(DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short))"

        _ = try await sendFormRequest(
            server: server,
            context: context,
            action: "share",
            parameters: [
                "tmp_repository_id": workspaceSlug,
                "file": normalizedLegacyFilePath(from: node.stateID),
                "sub_action": "create_minisite",
                "create_guest_user": "true",
                "workspace_label": node.name,
                "workspace_description": shareDescription,
                "simple_right_download": "on",
                "simple_right_read": "on"
            ]
        )

        if let link = try await publicLinkAddress(for: node.stateID, server: server, credentials: credentials) {
            return link
        }
        throw AppError.serverUnreachable("The legacy server created a share without returning a public link.")
    }

    func removePublicLink(
        for node: RemoteNode,
        server: ServerDescriptor,
        credentials: LegacyP8Credentials
    ) async throws {
        let context = try await authenticatedContext(server: server, credentials: credentials)
        let workspaceSlug = try workspaceSlug(from: node.stateID)
        _ = try await sendFormRequest(
            server: server,
            context: context,
            action: "unshare",
            parameters: [
                "tmp_repository_id": workspaceSlug,
                "file": normalizedLegacyFilePath(from: node.stateID)
            ]
        )
    }

    func delete(
        nodes: [RemoteNode],
        server: ServerDescriptor,
        credentials: LegacyP8Credentials
    ) async throws {
        let grouped = Dictionary(grouping: nodes) { $0.stateID.workspaceSlug ?? "" }

        for (workspaceSlug, workspaceNodes) in grouped where !workspaceSlug.isEmpty {
            let context = try await authenticatedContext(server: server, credentials: credentials)
            for node in workspaceNodes {
                _ = try await sendFormRequest(
                    server: server,
                    context: context,
                    action: "delete",
                    parameters: [
                        "tmp_repository_id": workspaceSlug,
                        "file_0": normalizedLegacyFilePath(from: node.stateID)
                    ]
                )
            }
        }
    }

    private func relocate(
        action: String,
        nodes: [RemoteNode],
        targetFolderStateID: StateID,
        server: ServerDescriptor,
        credentials: LegacyP8Credentials,
        extraParameters: [String: String]
    ) async throws {
        guard !nodes.isEmpty else {
            return
        }

        let context = try await authenticatedContext(server: server, credentials: credentials)
        let workspaceSlug = try workspaceSlug(from: targetFolderStateID)
        var parameters: [String: String] = [
            "tmp_repository_id": workspaceSlug,
            "dest": normalizedLegacyDirectory(from: targetFolderStateID)
        ]
        for (key, value) in extraParameters {
            parameters[key] = value
        }

        for (index, node) in nodes.enumerated() {
            guard node.stateID.workspaceSlug == workspaceSlug else {
                throw AppError.unsupported(
                    "Move and copy currently stay inside one workspace, matching the Android contract."
                )
            }
            parameters["file_\(index)"] = normalizedLegacyFilePath(from: node.stateID)
        }

        _ = try await sendFormRequest(
            server: server,
            context: context,
            action: action,
            parameters: parameters
        )
    }

    private func publicLinkAddress(
        for stateID: StateID,
        server: ServerDescriptor,
        credentials: LegacyP8Credentials
    ) async throws -> String? {
        let context = try await authenticatedContext(server: server, credentials: credentials)
        let workspaceSlug = try workspaceSlug(from: stateID)
        let data = try await sendFormRequest(
            server: server,
            context: context,
            action: "load_shared_element_data",
            parameters: [
                "tmp_repository_id": workspaceSlug,
                "merged": "true",
                "file": normalizedLegacyFilePath(from: stateID)
            ]
        )
        return try extractPublicLinkAddress(from: data, baseURL: server.baseURL)
    }

    func download(
        stateID: StateID,
        server: ServerDescriptor,
        credentials: LegacyP8Credentials,
        destinationURL: URL,
        progress: @escaping (Int64, Int64?) async throws -> Void
    ) async throws {
        let context = try await authenticatedContext(server: server, credentials: credentials)
        let workspaceSlug = try workspaceSlug(from: stateID)
        let request = try makeFormRequest(
            server: server,
            context: context,
            action: "download",
            parameters: [
                "tmp_repository_id": workspaceSlug,
                "file": normalizedLegacyFilePath(from: stateID)
            ]
        )

        let session = sessionFactory.session(skipTLSVerification: server.skipTLSVerification)
        let (bytes, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppError.unexpected("The legacy download did not return an HTTP response.")
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw AppError.serverUnreachable("Legacy download failed with status \(httpResponse.statusCode).")
        }

        let expectedLength = response.expectedContentLength > 0 ? response.expectedContentLength : nil
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        FileManager.default.createFile(atPath: destinationURL.path, contents: nil)

        let fileHandle = try FileHandle(forWritingTo: destinationURL)
        defer {
            try? fileHandle.close()
        }

        var probe = Data()
        var buffered = Data()
        var didValidateProbe = false
        var transferred: Int64 = 0

        for try await byte in bytes {
            try Task.checkCancellation()

            if !didValidateProbe {
                probe.append(byte)
                if shouldValidateDownloadProbe(probe) {
                    try throwIfLegacyError(in: probe)
                    didValidateProbe = true
                    buffered.append(probe)
                    probe.removeAll(keepingCapacity: false)
                    try await flushDownloadBuffer(
                        &buffered,
                        to: fileHandle,
                        transferred: &transferred,
                        expectedLength: expectedLength,
                        progress: progress
                    )
                }
                continue
            }

            buffered.append(byte)
            if buffered.count >= 64 * 1024 {
                try await flushDownloadBuffer(
                    &buffered,
                    to: fileHandle,
                    transferred: &transferred,
                    expectedLength: expectedLength,
                    progress: progress
                )
            }
        }

        if !didValidateProbe {
            try throwIfLegacyError(in: probe)
            buffered.append(probe)
        }

        if !buffered.isEmpty {
            try await flushDownloadBuffer(
                &buffered,
                to: fileHandle,
                transferred: &transferred,
                expectedLength: expectedLength,
                progress: progress
            )
        }
    }

    func upload(
        localURL: URL,
        to parentStateID: StateID,
        displayName: String,
        server: ServerDescriptor,
        credentials: LegacyP8Credentials,
        progress: @escaping (Int64, Int64) async throws -> Void
    ) async throws {
        let context = try await authenticatedContext(server: server, credentials: credentials)
        let workspaceSlug = try workspaceSlug(from: parentStateID)
        let parentDirectory = normalizedLegacyDirectory(from: parentStateID)
        let mimeType = mimeType(for: localURL)
        let fileSize = try localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init) ?? 0
        let handle = try FileHandle(forReadingFrom: localURL)
        defer {
            try? handle.close()
        }

        var uploaded: Int64 = 0
        var currentRemoteName = displayName

        while uploaded < fileSize {
            try Task.checkCancellation()

            let actionParameters = uploadParameters(
                directory: parentDirectory,
                workspaceSlug: workspaceSlug,
                remoteName: currentRemoteName,
                appendedRemoteName: uploaded > 0 ? currentRemoteName : nil
            )
            let (chunk, body, boundary) = try buildNextUploadBody(
                handle: handle,
                offset: uploaded,
                parameters: actionParameters,
                fileName: displayName,
                mimeType: mimeType,
                totalSize: fileSize
            )

            let responseData = try await sendMultipartRequest(
                server: server,
                context: context,
                action: "upload",
                parameters: actionParameters,
                body: body,
                boundary: boundary
            )

            if let uploadedName = extractUploadedFileName(from: responseData), !uploadedName.isEmpty {
                currentRemoteName = uploadedName
            }

            uploaded += Int64(chunk.count)
            try await progress(uploaded, fileSize)
        }
    }

    private func fetchWorkspaces(
        server: ServerDescriptor,
        context: LegacyP8SessionContext
    ) async throws -> [Workspace] {
        let data = try await sendFormRequest(
            server: server,
            context: context,
            action: "get_xml_registry",
            parameters: [
                "xPath": "user/repositories"
            ]
        )
        return try parseWorkspaces(data: data, server: server)
    }

    private func authenticatedContext(
        server: ServerDescriptor,
        credentials: LegacyP8Credentials
    ) async throws -> LegacyP8SessionContext {
        guard server.type == .legacyP8 else {
            throw AppError.unsupported("The legacy P8 client cannot be used with Cells servers.")
        }

        _ = try await fetchAuthSeed(server: server)

        let request = try makeAnonymousFormRequest(
            server: server,
            action: "login",
            parameters: [
                "login_seed": "-1",
                "userid": credentials.username,
                "password": credentials.password
            ]
        )
        let (data, response) = try await sendRaw(
            request,
            skipTLSVerification: server.skipTLSVerification
        )
        let loginResult = try parseLoginResponse(
            data: data,
            response: response,
            requestURL: request.url ?? server.baseURL
        )
        return loginResult
    }

    private func fetchAuthSeed(server: ServerDescriptor) async throws -> String {
        let request = try makeAnonymousGetRequest(server: server, action: "get_seed")
        let (data, _) = try await sendRaw(
            request,
            skipTLSVerification: server.skipTLSVerification
        )
        let payload = String(decoding: data, as: UTF8.self)
        if payload.contains("\"captcha\": true") || payload.contains("\"captcha\":true") {
            throw AppError.unsupported("This legacy server currently requires captcha-based login.")
        }
        return payload.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sendFormRequest(
        server: ServerDescriptor,
        context: LegacyP8SessionContext,
        action: String,
        parameters: [String: String]
    ) async throws -> Data {
        let request = try makeFormRequest(
            server: server,
            context: context,
            action: action,
            parameters: parameters
        )
        let (data, _) = try await sendRaw(
            request,
            skipTLSVerification: server.skipTLSVerification
        )
        try throwIfLegacyError(in: data)
        return data
    }

    private func sendMultipartRequest(
        server: ServerDescriptor,
        context: LegacyP8SessionContext,
        action: String,
        parameters: [String: String],
        body: Data,
        boundary: String
    ) async throws -> Data {
        var request = try makeFormRequest(
            server: server,
            context: context,
            action: action,
            parameters: parameters
        )
        request.httpBody = body
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let (data, _) = try await sendRaw(
            request,
            skipTLSVerification: server.skipTLSVerification
        )
        try throwIfLegacyError(in: data)
        return data
    }

    private func makeAnonymousGetRequest(
        server: ServerDescriptor,
        action: String
    ) throws -> URLRequest {
        let url = try indexURL(
            from: server.baseURL,
            queryItems: [
                URLQueryItem(name: "get_action", value: action)
            ]
        )
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        return request
    }

    private func makeAnonymousFormRequest(
        server: ServerDescriptor,
        action: String,
        parameters: [String: String]
    ) throws -> URLRequest {
        let url = try indexURL(
            from: server.baseURL,
            queryItems: [
                URLQueryItem(name: "get_action", value: action)
            ]
        )
        var bodyParameters = parameters
        bodyParameters["get_action"] = action

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = formEncodedData(from: bodyParameters)
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        return request
    }

    private func makeFormRequest(
        server: ServerDescriptor,
        context: LegacyP8SessionContext,
        action: String,
        parameters: [String: String]
    ) throws -> URLRequest {
        let url = try indexURL(
            from: server.baseURL,
            queryItems: [
                URLQueryItem(name: "get_action", value: action),
                URLQueryItem(name: "secure_token", value: context.secureToken)
            ]
        )
        var bodyParameters = parameters
        bodyParameters["get_action"] = action
        bodyParameters["secure_token"] = context.secureToken

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = formEncodedData(from: bodyParameters)
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(context.cookieHeader, forHTTPHeaderField: "Cookie")
        return request
    }

    private func sendRaw(
        _ request: URLRequest,
        skipTLSVerification: Bool
    ) async throws -> (Data, HTTPURLResponse) {
        let session = sessionFactory.session(skipTLSVerification: skipTLSVerification)
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppError.unexpected("The legacy transport did not return an HTTP response.")
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 401 {
                throw AppError.authentication("Legacy authentication failed with status 401.")
            }
            throw AppError.serverUnreachable(
                "Legacy request failed with status \(httpResponse.statusCode)."
            )
        }
        return (data, httpResponse)
    }

    private func parseLoginResponse(
        data: Data,
        response: HTTPURLResponse,
        requestURL: URL
    ) throws -> LegacyP8SessionContext {
        let parser = XMLParser(data: data)
        let delegate = LegacyLoginParserDelegate()
        parser.delegate = delegate
        guard parser.parse() else {
            throw AppError.authentication("The legacy login response could not be parsed.")
        }

        if delegate.captchaRequired {
            throw AppError.unsupported("This legacy server currently requires captcha-based login.")
        }
        guard delegate.success else {
            throw AppError.authentication(delegate.errorMessage ?? "Legacy credentials are invalid.")
        }
        guard let secureToken = delegate.secureToken, !secureToken.isEmpty else {
            throw AppError.authentication("Legacy login did not return a secure token.")
        }

        let rawHeaders = response.allHeaderFields.reduce(into: [String: String]()) { partial, item in
            guard let key = item.key as? String else {
                return
            }
            partial[key] = String(describing: item.value)
        }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: rawHeaders, for: requestURL)
        let cookieHeader = cookies
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")

        guard !cookieHeader.isEmpty else {
            throw AppError.authentication("Legacy login did not return a usable session cookie.")
        }

        return LegacyP8SessionContext(
            secureToken: secureToken,
            cookieHeader: cookieHeader
        )
    }

    private func parseWorkspaces(
        data: Data,
        server: ServerDescriptor
    ) throws -> [Workspace] {
        let parser = XMLParser(data: data)
        let delegate = LegacyWorkspaceParserDelegate(
            serverID: server.id,
            excludedAccessTypes: excludedWorkspaceAccessTypes
        )
        parser.delegate = delegate
        guard parser.parse() else {
            throw AppError.unexpected("Could not parse legacy workspace list.")
        }
        return delegate.workspaces.sorted {
            $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
        }
    }

    private func parseNodes(
        data: Data,
        workspaceSlug: String,
        session: AccountSession
    ) throws -> (nodes: [RemoteNode], pagination: LegacyP8Pagination?) {
        let parser = XMLParser(data: data)
        let delegate = LegacyNodeParserDelegate(session: session, workspaceSlug: workspaceSlug)
        parser.delegate = delegate
        guard parser.parse() else {
            throw AppError.unexpected("Could not parse the legacy node list.")
        }
        return (delegate.nodes, delegate.pagination)
    }

    private func throwIfLegacyError(in data: Data) throws {
        let probe = String(decoding: data.prefix(1024), as: UTF8.self)
        let lowercased = probe.lowercased()

        if lowercased.contains("<require_auth") {
            throw AppError.authentication("The legacy server requires a new authenticated session.")
        }
        if lowercased.contains("you are not allowed to access") {
            throw AppError.authentication("The legacy secure token has expired.")
        }
        if lowercased.contains("value=\"-4\"") && lowercased.contains("logging_result") {
            throw AppError.unsupported("This legacy server currently requires captcha-based login.")
        }

        let regex = try NSRegularExpression(
            pattern: "<message[^>]*type=[\"']ERROR[\"'][^>]*>(.*?)</message>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        )
        let range = NSRange(probe.startIndex ..< probe.endIndex, in: probe)
        if let match = regex.firstMatch(in: probe, options: [], range: range),
           let messageRange = Range(match.range(at: 1), in: probe) {
            let message = probe[messageRange]
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !message.isEmpty {
                throw AppError.serverUnreachable(message)
            }
            throw AppError.serverUnreachable("The legacy server returned an XML error response.")
        }
    }

    private func extractUploadedFileName(from data: Data) -> String? {
        let payload = String(decoding: data, as: UTF8.self)
        let regex = try? NSRegularExpression(pattern: "filename=[\"']([^\"']+)[\"']", options: [])
        guard
            let regex,
            let match = regex.firstMatch(
                in: payload,
                options: [],
                range: NSRange(payload.startIndex ..< payload.endIndex, in: payload)
            ),
            let range = Range(match.range(at: 1), in: payload)
        else {
            return nil
        }
        return URL(fileURLWithPath: String(payload[range])).lastPathComponent
    }

    private func extractPublicLinkAddress(from data: Data, baseURL: URL) throws -> String? {
        let object = try JSONSerialization.jsonObject(with: data)

        if let dictionary = object as? [String: Any] {
            if let direct = dictionary["LinkUrl"] as? String {
                return resolvePublicLink(direct, baseURL: baseURL)
            }
            if
                let links = dictionary["links"] as? [String: Any],
                let first = links.values.first as? [String: Any],
                let publicLink = first["public_link"] as? String {
                return resolvePublicLink(publicLink, baseURL: baseURL)
            }
        }
        return nil
    }

    private func resolvePublicLink(_ rawValue: String, baseURL: URL) -> String {
        if let absoluteURL = URL(string: rawValue), absoluteURL.scheme != nil {
            return absoluteURL.absoluteString
        }
        let trimmedBase = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let normalizedLink = rawValue.hasPrefix("/") ? rawValue : "/\(rawValue)"
        return trimmedBase + normalizedLink
    }

    private func deduplicate(nodes: [RemoteNode]) -> [RemoteNode] {
        var seen = Set<String>()
        var unique: [RemoteNode] = []
        unique.reserveCapacity(nodes.count)
        for node in nodes {
            if seen.insert(node.id).inserted {
                unique.append(node)
            }
        }
        return unique
    }

    private func flushDownloadBuffer(
        _ buffer: inout Data,
        to fileHandle: FileHandle,
        transferred: inout Int64,
        expectedLength: Int64?,
        progress: @escaping (Int64, Int64?) async throws -> Void
    ) async throws {
        guard !buffer.isEmpty else {
            return
        }
        try fileHandle.write(contentsOf: buffer)
        transferred += Int64(buffer.count)
        let current = transferred
        let total = expectedLength
        buffer.removeAll(keepingCapacity: true)
        try await progress(current, total)
    }

    private func shouldValidateDownloadProbe(_ probe: Data) -> Bool {
        guard !probe.isEmpty else {
            return false
        }
        let prefix = String(decoding: probe, as: UTF8.self)
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return probe.count >= 512
        }
        if trimmed.first != "<" {
            return true
        }
        return probe.count >= 512 || trimmed.contains(">")
    }

    private func buildNextUploadBody(
        handle: FileHandle,
        offset: Int64,
        parameters: [String: String],
        fileName: String,
        mimeType: String,
        totalSize: Int64
    ) throws -> (chunk: Data, body: Data, boundary: String) {
        var requestedCount = Int(
            min(
                Int64(max(uploadRequestSizeLimit - 16 * 1024, 128 * 1024)),
                totalSize - offset
            )
        )
        var lastBody = Data()
        var lastChunk = Data()
        var lastBoundary = ""

        while requestedCount > 0 {
            try handle.seek(toOffset: UInt64(offset))
            let chunk = try handle.read(upToCount: requestedCount) ?? Data()
            guard !chunk.isEmpty else {
                throw AppError.unexpected("Could not read the staged legacy upload file.")
            }

            let boundary = "----BitHubLegacy-\(UUID().uuidString)"
            let body = buildMultipartBody(
                parameters: parameters,
                boundary: boundary,
                fileName: fileName,
                mimeType: mimeType,
                chunk: chunk
            )
            lastBody = body
            lastChunk = chunk
            lastBoundary = boundary

            if body.count <= uploadRequestSizeLimit || chunk.count <= 64 * 1024 {
                return (chunk, body, boundary)
            }

            let overflow = max(body.count - uploadRequestSizeLimit + 1024, 32 * 1024)
            requestedCount = max(chunk.count - overflow, 64 * 1024)
        }

        return (lastChunk, lastBody, lastBoundary)
    }

    private func buildMultipartBody(
        parameters: [String: String],
        boundary: String,
        fileName: String,
        mimeType: String,
        chunk: Data
    ) -> Data {
        var body = Data()
        for key in parameters.keys.sorted() {
            guard let value = parameters[key] else {
                continue
            }
            body.appendString("--\(boundary)\r\n")
            body.appendString("Content-Disposition: form-data; name=\"\(key)\"\r\n")
            body.appendString("Content-Type: text/plain; charset=utf-8\r\n\r\n")
            body.appendString(value)
            body.appendString("\r\n")
        }

        body.appendString("--\(boundary)\r\n")
        body.appendString(
            "Content-Disposition: form-data; name=\"userfile_0\"; filename=\"\(escapedMultipartValue(fileName))\"\r\n"
        )
        body.appendString("Content-Type: \(mimeType)\r\n\r\n")
        body.append(chunk)
        body.appendString("\r\n--\(boundary)--\r\n")
        return body
    }

    private func uploadParameters(
        directory: String,
        workspaceSlug: String,
        remoteName: String,
        appendedRemoteName: String?
    ) -> [String: String] {
        var parameters: [String: String] = [
            "dir": directory,
            "tmp_repository_id": workspaceSlug,
            "urlencoded_filename": remoteName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? remoteName,
            "auto_rename": "true",
            "xhr_uploader": "true"
        ]
        if let appendedRemoteName {
            parameters["appendto_urlencoded_part"] = appendedRemoteName
        }
        return parameters
    }

    private func normalizedLegacyDirectory(from stateID: StateID) -> String {
        stateID.filePath ?? "/"
    }

    private func normalizedLegacyFilePath(from stateID: StateID) -> String {
        stateID.filePath ?? "/"
    }

    private func workspaceSlug(from stateID: StateID) throws -> String {
        guard let workspaceSlug = stateID.workspaceSlug, !workspaceSlug.isEmpty else {
            throw AppError.unexpected("The legacy P8 request is missing a workspace slug.")
        }
        return workspaceSlug
    }

    private func indexURL(
        from baseURL: URL,
        queryItems: [URLQueryItem]
    ) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw AppError.invalidAddress("Could not build the legacy API URL.")
        }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = basePath.isEmpty ? "/index.php" : "/\(basePath)/index.php"
        components.queryItems = queryItems
        guard let url = components.url else {
            throw AppError.invalidAddress("Could not build the legacy API URL.")
        }
        return url
    }

    private func formEncodedData(from parameters: [String: String]) -> Data? {
        let items = parameters.keys.sorted().map { URLQueryItem(name: $0, value: parameters[$0]) }
        var components = URLComponents()
        components.queryItems = items
        return components.percentEncodedQuery?.data(using: .utf8)
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

    private func mimeType(for localURL: URL) -> String {
        if let contentType = UTType(filenameExtension: localURL.pathExtension)?.preferredMIMEType {
            return contentType
        }
        return "application/octet-stream"
    }

    private var userAgent: String {
        "BitHub-iOS/1"
    }

    private func escapedMultipartValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

private final class LegacyLoginParserDelegate: NSObject, XMLParserDelegate {
    private(set) var success = false
    private(set) var secureToken: String?
    private(set) var captchaRequired = false
    private(set) var errorMessage: String?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard elementName == "logging_result" else {
            return
        }
        let value = attributeDict["value"] ?? ""
        if value == "1" {
            success = true
            secureToken = attributeDict["secure_token"]
            return
        }
        if value == "-4" {
            captchaRequired = true
            errorMessage = "Legacy login requires captcha validation."
            return
        }
        errorMessage = "Legacy credentials are invalid."
    }
}

private final class LegacyWorkspaceParserDelegate: NSObject, XMLParserDelegate {
    private let serverID: String
    private let excludedAccessTypes: Set<String>

    private var currentAttributes: [String: String]?
    private var currentElement = ""
    private var currentValue = ""

    private(set) var workspaces: [Workspace] = []

    init(serverID: String, excludedAccessTypes: Set<String>) {
        self.serverID = serverID
        self.excludedAccessTypes = excludedAccessTypes
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if elementName == "repo" {
            currentAttributes = attributeDict
            return
        }
        guard currentAttributes != nil else {
            return
        }
        if elementName == "label" || elementName == "description" {
            currentElement = elementName
            currentValue = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !currentElement.isEmpty else {
            return
        }
        currentValue += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard var attributes = currentAttributes else {
            return
        }

        if elementName == "label" || elementName == "description" {
            if !currentValue.isEmpty {
                attributes[elementName] = currentValue
            }
            currentAttributes = attributes
            currentElement = ""
            currentValue = ""
            return
        }

        guard elementName == "repo" else {
            return
        }

        defer {
            currentAttributes = nil
            currentElement = ""
            currentValue = ""
        }

        let accessType = attributes["access_type"] ?? ""
        guard !excludedAccessTypes.contains(accessType) else {
            return
        }
        guard let slug = attributes["repositorySlug"], !slug.isEmpty else {
            return
        }

        workspaces.append(
            Workspace(
                id: "\(serverID):\(slug)",
                slug: slug,
                label: attributes["label"]?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? slug,
                description: attributes["description"]?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
                rootPath: "/\(slug)"
            )
        )
    }
}

private final class LegacyNodeParserDelegate: NSObject, XMLParserDelegate {
    private let session: AccountSession
    private let workspaceSlug: String

    private var parsedTreeCount = 0
    private var currentAttributes: [String: String]?
    private var currentElement = ""
    private var currentValue = ""

    private(set) var nodes: [RemoteNode] = []
    private(set) var pagination: LegacyP8Pagination?

    init(session: AccountSession, workspaceSlug: String) {
        self.session = session
        self.workspaceSlug = workspaceSlug
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if elementName == "pagination" {
            let current = Int(attributeDict["current"] ?? "") ?? 1
            let total = Int(attributeDict["total"] ?? "") ?? current
            pagination = LegacyP8Pagination(currentPage: current, totalPages: total)
            return
        }

        guard elementName == "tree" || currentAttributes != nil else {
            return
        }

        if elementName == "tree" {
            parsedTreeCount += 1
            if parsedTreeCount == 1 {
                currentAttributes = nil
                return
            }
            currentAttributes = attributeDict
            currentElement = ""
            currentValue = ""
            return
        }

        if elementName.lowercased() == "label" || elementName.lowercased() == "description" {
            currentElement = elementName
            currentValue = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard currentAttributes != nil, !currentElement.isEmpty else {
            return
        }
        currentValue += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard var attributes = currentAttributes else {
            return
        }

        if elementName == "label" || elementName == "description" {
            if !currentValue.isEmpty {
                attributes[elementName] = currentValue
            }
            currentAttributes = attributes
            currentElement = ""
            currentValue = ""
            return
        }

        guard elementName == "tree" else {
            return
        }

        defer {
            currentAttributes = nil
            currentElement = ""
            currentValue = ""
        }

        let relativePath = attributes["filename"]?.nonEmpty ?? "/"
        let normalizedRelativePath = relativePath == "/" ? "/" : (relativePath.hasPrefix("/") ? relativePath : "/\(relativePath)")
        let statePath = normalizedRelativePath == "/" ? "/\(workspaceSlug)" : "/\(workspaceSlug)\(normalizedRelativePath)"
        let derivedName = normalizedRelativePath == "/"
            ? nil
            : URL(fileURLWithPath: normalizedRelativePath).lastPathComponent.nonEmpty
        let name = derivedName
            ?? attributes["label"]?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? workspaceSlug

        let isFile = (attributes["is_file"] ?? "").lowercased() == "true"
        let mimeType: String
        if isFile {
            mimeType = attributes["image_type"]?.nonEmpty
                ?? attributes["ajxp_mime"]?.nonEmpty
                ?? "application/octet-stream"
        } else if attributes["ajxp_mime"] == "ajxp_recycle" {
            mimeType = "pydio/recycle"
        } else {
            mimeType = "pydio/nodes-list"
        }

        let modifiedAt = Double(attributes["ajxp_modiftime"] ?? "").map {
            Date(timeIntervalSince1970: $0)
        }
        let size = Int64(attributes["bytesize"] ?? "")
        let metadata = attributes.reduce(into: [String: JSONValue]()) { partial, item in
            partial[item.key] = .string(item.value)
        }

        nodes.append(
            RemoteNode(
                stateID: StateID(
                    username: session.username,
                    serverURL: session.serverURL.absoluteString,
                    path: statePath
                ),
                kind: isFile ? .file : .folder,
                name: name,
                uuid: attributes["ajxp_node"]?.nonEmpty ?? attributes["uuid"]?.nonEmpty,
                mimeType: mimeType,
                size: size,
                etag: attributes["etag"],
                modifiedAt: modifiedAt,
                metadata: metadata
            )
        )
    }
}

private extension Data {
    mutating func appendString(_ value: String) {
        append(Data(value.utf8))
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}

#if DEBUG
extension LegacyP8Client {
    func debugParseWorkspaces(
        _ xml: String,
        server: ServerDescriptor
    ) throws -> [Workspace] {
        try parseWorkspaces(data: Data(xml.utf8), server: server)
    }

    func debugParseNodes(
        _ xml: String,
        workspaceSlug: String,
        session: AccountSession
    ) throws -> [RemoteNode] {
        try parseNodes(
            data: Data(xml.utf8),
            workspaceSlug: workspaceSlug,
            session: session
        ).nodes
    }
}
#endif
