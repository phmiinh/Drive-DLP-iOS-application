import Foundation
import SwiftUI
import UniformTypeIdentifiers

actor AccountRepository {
    private let database: AppDatabase
    private let keychain: KeychainStore

    init(database: AppDatabase, keychain: KeychainStore) {
        self.database = database
        self.keychain = keychain
    }

    func sessions() async throws -> [AccountSession] {
        try await database.sessions.load()
    }

    func servers() async throws -> [ServerDescriptor] {
        try await database.servers.load()
    }

    func activeSession() async throws -> AccountSession? {
        try await sessions().first(where: { $0.lifecycleState == .foreground })
    }

    func server(for serverID: String) async throws -> ServerDescriptor? {
        try await servers().first(where: { $0.id == serverID })
    }

    func session(for accountID: String) async throws -> AccountSession? {
        try await sessions().first(where: { $0.accountID == accountID })
    }

    func sessionContext(for accountID: String) async throws -> (AccountSession, ServerDescriptor, OAuthToken) {
        guard
            let session = try await session(for: accountID),
            let server = try await server(for: session.serverID),
            let token = try keychain.value(for: accountID, as: OAuthToken.self)
        else {
            throw AppError.authentication("Missing persisted session context for \(accountID).")
        }
        return (session, server, token)
    }

    func upsert(server: ServerDescriptor) async throws {
        try await database.servers.update { servers in
            if let index = servers.firstIndex(where: { $0.id == server.id }) {
                servers[index] = server
            } else {
                servers.append(server)
            }
        }
    }

    func upsert(session: AccountSession) async throws {
        try await database.sessions.update { sessions in
            if let index = sessions.firstIndex(where: { $0.accountID == session.accountID }) {
                sessions[index] = session
            } else {
                sessions.append(session)
            }
        }
    }

    func saveToken(_ token: OAuthToken, for accountID: String) throws {
        try keychain.set(token, for: accountID)
    }

    func token(for accountID: String) throws -> OAuthToken? {
        try keychain.value(for: accountID, as: OAuthToken.self)
    }

    func saveLegacyCredentials(_ credentials: LegacyP8Credentials, for accountID: String) throws {
        try keychain.set(credentials, for: legacyCredentialsKey(accountID))
    }

    func legacyCredentials(for accountID: String) throws -> LegacyP8Credentials? {
        try keychain.value(for: legacyCredentialsKey(accountID), as: LegacyP8Credentials.self)
    }

    func legacySessionContext(for accountID: String) async throws -> (AccountSession, ServerDescriptor, LegacyP8Credentials) {
        guard
            let session = try await session(for: accountID),
            let server = try await server(for: session.serverID),
            let credentials = try legacyCredentials(for: accountID)
        else {
            throw AppError.authentication("Missing persisted legacy session context for \(accountID).")
        }
        return (session, server, credentials)
    }

    func setActive(accountID: String) async throws {
        try await database.sessions.update { sessions in
            for index in sessions.indices {
                if sessions[index].accountID == accountID {
                    sessions[index].lifecycleState = .foreground
                    sessions[index].updatedAt = Date()
                } else {
                    sessions[index].lifecycleState = .background
                }
            }
        }
    }

    func updateStatus(accountID: String, status: AccountAuthStatus, isReachable: Bool? = nil) async throws {
        try await database.sessions.update { sessions in
            guard let index = sessions.firstIndex(where: { $0.accountID == accountID }) else { return }
            sessions[index].authStatus = status
            if let isReachable {
                sessions[index].isReachable = isReachable
            }
            sessions[index].updatedAt = Date()
        }
    }

    func logout(accountID: String) async throws {
        keychain.delete(account: accountID)
        keychain.delete(account: legacyCredentialsKey(accountID))
        try await updateStatus(accountID: accountID, status: .noCredentials)
    }

    func delete(accountID: String) async throws {
        keychain.delete(account: accountID)
        keychain.delete(account: legacyCredentialsKey(accountID))
        try await database.sessions.update { sessions in
            sessions.removeAll { $0.accountID == accountID }
        }
    }

    private func legacyCredentialsKey(_ accountID: String) -> String {
        "\(accountID):legacy"
    }
}

actor NodeRepository {
    private let database: AppDatabase
    private let apiClient: PydioAPIClient
    private let legacyP8Client: LegacyP8Client
    private let accountRepository: AccountRepository

    init(
        database: AppDatabase,
        apiClient: PydioAPIClient,
        legacyP8Client: LegacyP8Client,
        accountRepository: AccountRepository
    ) {
        self.database = database
        self.apiClient = apiClient
        self.legacyP8Client = legacyP8Client
        self.accountRepository = accountRepository
    }

    func loadWorkspaces(for session: AccountSession) async throws -> [Workspace] {
        if session.isLegacy {
            let (_, server, credentials) = try await accountRepository.legacySessionContext(for: session.accountID)
            return try await legacyP8Client.fetchWorkspaces(server: server, credentials: credentials)
        }

        let (_, server, token) = try await accountRepository.sessionContext(for: session.accountID)
        return try await apiClient.fetchWorkspaces(server: server, token: token)
    }

    func loadChildren(
        of folderStateID: StateID,
        session: AccountSession,
        sortOrder: NodeSortOrder
    ) async throws -> [RemoteNode] {
        let children: [RemoteNode]
        if session.isLegacy {
            let (_, server, credentials) = try await accountRepository.legacySessionContext(for: session.accountID)
            children = try await legacyP8Client.listNodes(
                in: folderStateID,
                session: session,
                server: server,
                credentials: credentials,
                sortOrder: sortOrder
            )
        } else {
            let (_, server, token) = try await accountRepository.sessionContext(for: session.accountID)
            children = try await apiClient.listNodes(
                in: folderStateID,
                session: session,
                server: server,
                token: token,
                sortOrder: sortOrder
            )
        }
        try await database.cachedChildren.update { cache in
            cache[folderStateID.encodedID] = children
        }
        return children
    }

    func cachedChildren(for folderStateID: StateID) async throws -> [RemoteNode] {
        try await database.cachedChildren.load()[folderStateID.encodedID] ?? []
    }

    func search(
        query: String,
        in folderStateID: StateID,
        session: AccountSession
    ) async throws -> [RemoteNode] {
        if session.isLegacy {
            let (_, server, credentials) = try await accountRepository.legacySessionContext(for: session.accountID)
            return try await legacyP8Client.searchNodes(
                query: query,
                from: folderStateID,
                session: session,
                server: server,
                credentials: credentials
            )
        }

        let (_, server, token) = try await accountRepository.sessionContext(for: session.accountID)
        return try await apiClient.searchNodes(
            query: query,
            from: folderStateID,
            session: session,
            server: server,
            token: token
        )
    }

    func listBookmarkedNodes(for session: AccountSession) async throws -> [RemoteNode] {
        if session.isLegacy {
            let (_, server, credentials) = try await accountRepository.legacySessionContext(for: session.accountID)
            return try await legacyP8Client.fetchBookmarkedNodes(
                session: session,
                server: server,
                credentials: credentials
            )
        }

        let (_, server, token) = try await accountRepository.sessionContext(for: session.accountID)
        return try await apiClient.fetchBookmarkedNodes(
            session: session,
            server: server,
            token: token
        )
    }

    func createFolder(name: String, in folderStateID: StateID, session: AccountSession) async throws {
        if session.isLegacy {
            let (_, server, credentials) = try await accountRepository.legacySessionContext(for: session.accountID)
            try await legacyP8Client.createFolder(
                name: name,
                in: folderStateID,
                server: server,
                credentials: credentials
            )
            return
        }

        let (_, server, token) = try await accountRepository.sessionContext(for: session.accountID)
        try await apiClient.createFolder(name: name, in: folderStateID, server: server, token: token)
    }

    func rename(node: RemoteNode, newName: String, session: AccountSession) async throws {
        if session.isLegacy {
            let (_, server, credentials) = try await accountRepository.legacySessionContext(for: session.accountID)
            try await legacyP8Client.rename(
                node: node,
                newName: newName,
                server: server,
                credentials: credentials
            )
            return
        }

        let (_, server, token) = try await accountRepository.sessionContext(for: session.accountID)
        try await apiClient.rename(node: node, newName: newName, server: server, token: token)
    }

    func delete(nodes: [RemoteNode], session: AccountSession) async throws {
        if session.isLegacy {
            let (_, server, credentials) = try await accountRepository.legacySessionContext(for: session.accountID)
            try await legacyP8Client.delete(nodes: nodes, server: server, credentials: credentials)
            try await invalidateCaches(for: nodes, destination: nil)
            return
        }

        let (_, server, token) = try await accountRepository.sessionContext(for: session.accountID)
        try await apiClient.delete(nodes: nodes, server: server, token: token)
        try await invalidateCaches(for: nodes, destination: nil)
    }

    func move(nodes: [RemoteNode], to targetFolderStateID: StateID, session: AccountSession) async throws {
        if session.isLegacy {
            let (_, server, credentials) = try await accountRepository.legacySessionContext(for: session.accountID)
            try await legacyP8Client.move(
                nodes: nodes,
                to: targetFolderStateID,
                server: server,
                credentials: credentials
            )
            try await invalidateCaches(for: nodes, destination: targetFolderStateID)
            return
        }

        let (_, server, token) = try await accountRepository.sessionContext(for: session.accountID)
        try await apiClient.move(
            nodes: nodes,
            to: targetFolderStateID,
            server: server,
            token: token
        )
        try await invalidateCaches(for: nodes, destination: targetFolderStateID)
    }

    func copy(nodes: [RemoteNode], to targetFolderStateID: StateID, session: AccountSession) async throws {
        if session.isLegacy {
            let (_, server, credentials) = try await accountRepository.legacySessionContext(for: session.accountID)
            try await legacyP8Client.copy(
                nodes: nodes,
                to: targetFolderStateID,
                server: server,
                credentials: credentials
            )
            try await invalidateCaches(for: nodes, destination: targetFolderStateID)
            return
        }

        let (_, server, token) = try await accountRepository.sessionContext(for: session.accountID)
        try await apiClient.copy(
            nodes: nodes,
            to: targetFolderStateID,
            server: server,
            token: token
        )
        try await invalidateCaches(for: nodes, destination: targetFolderStateID)
    }

    func setBookmarked(node: RemoteNode, enabled: Bool, session: AccountSession) async throws {
        if session.isLegacy {
            let (_, server, credentials) = try await accountRepository.legacySessionContext(for: session.accountID)
            try await legacyP8Client.setBookmarked(
                node: node,
                bookmarked: enabled,
                server: server,
                credentials: credentials
            )
            try await invalidateCaches(for: [node], destination: nil)
            return
        }

        let (_, server, token) = try await accountRepository.sessionContext(for: session.accountID)
        try await apiClient.setBookmarked(
            node: node,
            bookmarked: enabled,
            username: session.username,
            server: server,
            token: token
        )
        try await invalidateCaches(for: [node], destination: nil)
    }

    func createOrFetchPublicLink(for node: RemoteNode, session: AccountSession) async throws -> String {
        if session.isLegacy {
            let (_, server, credentials) = try await accountRepository.legacySessionContext(for: session.accountID)
            let link = try await legacyP8Client.createOrFetchPublicLink(
                for: node,
                server: server,
                credentials: credentials
            )
            try await invalidateCaches(for: [node], destination: nil)
            return link
        }

        let (_, server, token) = try await accountRepository.sessionContext(for: session.accountID)
        let link = try await apiClient.createOrFetchPublicLink(
            for: node,
            username: session.username,
            server: server,
            token: token
        )
        try await invalidateCaches(for: [node], destination: nil)
        return link
    }

    func removePublicLink(for node: RemoteNode, session: AccountSession) async throws {
        if session.isLegacy {
            let (_, server, credentials) = try await accountRepository.legacySessionContext(for: session.accountID)
            try await legacyP8Client.removePublicLink(
                for: node,
                server: server,
                credentials: credentials
            )
            try await invalidateCaches(for: [node], destination: nil)
            return
        }

        let (_, server, token) = try await accountRepository.sessionContext(for: session.accountID)
        try await apiClient.removePublicLink(for: node, server: server, token: token)
        try await invalidateCaches(for: [node], destination: nil)
    }

    func clearCache() async throws {
        try await database.cachedChildren.save([:])
    }

    private func invalidateCaches(for nodes: [RemoteNode], destination: StateID?) async throws {
        let parentIDs = nodes.map { $0.stateID.parent().encodedID }
        let nodeIDs = nodes.map(\.stateID.encodedID)
        let destinationID = destination.map(\.encodedID)
        let keys = Set(parentIDs + nodeIDs + [destinationID].compactMap { $0 })

        try await database.cachedChildren.update { cache in
            for key in keys {
                cache.removeValue(forKey: key)
            }
        }
    }
}

@MainActor
final class TransferQueueService: ObservableObject {
    @Published private(set) var records: [TransferRecord] = []

    private let database: AppDatabase
    private let accountRepository: AccountRepository
    private let legacyP8Client: LegacyP8Client
    private let jobRepository: JobRepository
    private let offlineRepository: OfflineRepository
    private let logger: Logger
    private let presigner = CellsS3Presigner()
    private let sessionFactory = TransferSessionFactory()
    private let maxConcurrentTransfers = 2
    private var runningTasks: [UUID: Task<Void, Never>] = [:]
    private var runningJobIDs: [UUID: UUID] = [:]

    init(
        database: AppDatabase,
        accountRepository: AccountRepository,
        legacyP8Client: LegacyP8Client,
        jobRepository: JobRepository,
        offlineRepository: OfflineRepository,
        logger: Logger
    ) {
        self.database = database
        self.accountRepository = accountRepository
        self.legacyP8Client = legacyP8Client
        self.jobRepository = jobRepository
        self.offlineRepository = offlineRepository
        self.logger = logger
    }

    func reload() async {
        do {
            records = try await database.transfers.update { transfers in
                for index in transfers.indices where transfers[index].status == .processing {
                    transfers[index].status = .queued
                    transfers[index].errorMessage = nil
                    transfers[index].updatedAt = Date()
                }
            }
        } catch {
            records = []
        }
        await startPendingTransfersIfNeeded()
    }

    @discardableResult
    func enqueue(
        kind: TransferKind,
        accountID: String,
        stateID: String?,
        localURL: URL?,
        displayName: String
    ) async -> Bool {
        if kind == .download,
           let stateID,
           records.contains(where: {
               guard
                   $0.kind == .download,
                   $0.accountID == accountID,
                   $0.stateID == stateID
               else {
                   return false
               }

               if $0.status == .done || $0.status == .locallyCached {
                   guard let localURL = $0.localURL else {
                       return false
                   }
                   return FileManager.default.fileExists(atPath: localURL.path)
               }

               return $0.status != .cancelled && $0.status != .error
           }) {
            logger.info("Skipping duplicate queued download for \(displayName)")
            return false
        }

        if kind == .upload,
           let localURL,
           records.contains(where: {
               $0.kind == .upload &&
               $0.accountID == accountID &&
               $0.localURL == localURL &&
               ($0.status == .queued || $0.status == .processing)
           }) {
            logger.info("Skipping duplicate queued upload for \(displayName)")
            return false
        }

        let newRecord = TransferRecord(
            id: UUID(),
            kind: kind,
            status: .queued,
            accountID: accountID,
            stateID: stateID,
            localURL: localURL,
            displayName: displayName,
            bytesTotal: nil,
            bytesTransferred: 0,
            errorMessage: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
        do {
            records = try await database.transfers.update { transfers in
                transfers.append(newRecord)
            }
            logger.info("Queued \(kind.rawValue) transfer for \(displayName)")
            await startPendingTransfersIfNeeded()
            return true
        } catch {
            logger.error("Could not enqueue transfer \(displayName): \(error.localizedDescription)")
            return false
        }
    }

    func clearCompleted() async {
        do {
            records = try await database.transfers.update { transfers in
                var retained: [TransferRecord] = []
                retained.reserveCapacity(transfers.count)

                for var record in transfers {
                    if record.kind == .download,
                       record.status == .done,
                       let localURL = record.localURL,
                       FileManager.default.fileExists(atPath: localURL.path) {
                        record.status = .locallyCached
                        record.updatedAt = Date()
                        retained.append(record)
                        continue
                    }

                    if record.status == .done || record.status == .cancelled {
                        continue
                    }
                    retained.append(record)
                }
                transfers = retained
            }
            let activeIDs = Set(records.map(\.id))
            runningTasks = runningTasks.filter { activeIDs.contains($0.key) }
            runningJobIDs = runningJobIDs.filter { activeIDs.contains($0.key) }
        } catch {
            logger.warning("Could not clear completed transfers: \(error.localizedDescription)")
        }
    }

    func purgeDownloadedFiles() async {
        do {
            records = try await database.transfers.update { transfers in
                var retained: [TransferRecord] = []
                retained.reserveCapacity(transfers.count)

                for record in transfers {
                    if record.kind == .download,
                       let localURL = record.localURL,
                       FileManager.default.fileExists(atPath: localURL.path) {
                        try? FileManager.default.removeItem(at: localURL)
                    }

                    if record.kind == .download,
                       (record.status == .done || record.status == .locallyCached) {
                        continue
                    }

                    retained.append(record)
                }
                transfers = retained
            }
            logger.info("Purged downloaded file cache")
        } catch {
            logger.warning("Could not purge downloaded files: \(error.localizedDescription)")
        }
    }

    func retry(id: UUID) async {
        do {
            try await persistRecord(id: id) { record in
                record.status = .queued
                record.errorMessage = nil
                record.updatedAt = Date()
                record.bytesTransferred = 0
            }
            await startPendingTransfersIfNeeded()
        } catch {
            logger.error("Could not retry transfer \(id): \(error.localizedDescription)")
        }
    }

    func cancel(id: UUID) async {
        runningTasks[id]?.cancel()
        runningTasks.removeValue(forKey: id)
        do {
            try await persistRecord(id: id) { record in
                record.status = .cancelled
                record.errorMessage = "Cancelled by user"
                record.updatedAt = Date()
            }
            await startPendingTransfersIfNeeded()
        } catch {
            logger.error("Could not cancel transfer \(id): \(error.localizedDescription)")
        }
    }

    func localFileURL(accountID: String, stateID: String) -> URL? {
        guard
            let record = records.first(where: {
                $0.accountID == accountID &&
                $0.stateID == stateID &&
                $0.kind == .download &&
                ($0.status == .done || $0.status == .locallyCached)
            }),
            let localURL = record.localURL,
            FileManager.default.fileExists(atPath: localURL.path)
        else {
            return nil
        }
        return localURL
    }

    private func startPendingTransfersIfNeeded() async {
        let availableSlots = maxConcurrentTransfers - runningTasks.count
        guard availableSlots > 0 else {
            return
        }

        let pending = records
            .filter { $0.status == .queued && runningTasks[$0.id] == nil }
            .prefix(availableSlots)
        for record in pending {
            await startTransfer(id: record.id)
        }
    }

    private func startTransfer(id: UUID) async {
        guard runningTasks[id] == nil else {
            return
        }

        runningTasks[id] = Task { [weak self] in
            guard let self else {
                return
            }
            await self.executeTransfer(id: id)
            await MainActor.run {
                self.runningTasks.removeValue(forKey: id)
                self.runningJobIDs.removeValue(forKey: id)
            }
            await self.startPendingTransfersIfNeeded()
        }
    }

    private func executeTransfer(id: UUID) async {
        var runtimeJobID: UUID?
        do {
            let record = try await loadRecord(id: id)
            if let runtimeJob = try? await jobRepository.create(
                owner: record.accountID,
                template: "transfer.\(record.kind.rawValue)",
                label: "\(record.kind == .download ? "Download" : "Upload"): \(record.displayName)",
                total: record.bytesTotal ?? -1
            ) {
                runtimeJobID = runtimeJob.id
            }
            if let runtimeJobID {
                runningJobIDs[id] = runtimeJobID
                try? await jobRepository.launched(jobID: runtimeJobID)
            }
            try await persistRecord(id: id) { mutable in
                mutable.status = .processing
                mutable.errorMessage = nil
                mutable.updatedAt = Date()
                if mutable.bytesTotal == nil, let localURL = mutable.localURL {
                    mutable.bytesTotal = (try? localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
                }
            }

            switch record.kind {
            case .download:
                try await executeDownload(id: id, record: record, runtimeJobID: runtimeJobID)
            case .upload:
                try await executeUpload(id: id, record: record, runtimeJobID: runtimeJobID)
            }

            if let runtimeJobID {
                try? await jobRepository.complete(
                    jobID: runtimeJobID,
                    status: .done,
                    message: "Completed \(record.displayName)",
                    progressMessage: "Transfer finished"
                )
            }
            logger.info("Transfer \(id) completed for \(record.displayName)")
        } catch is CancellationError {
            do {
                try await persistRecord(id: id) { record in
                    record.status = .cancelled
                    record.errorMessage = "Cancelled by user"
                    record.updatedAt = Date()
                }
                if let runtimeJobID {
                    try? await jobRepository.complete(
                        jobID: runtimeJobID,
                        status: .cancelled,
                        message: "Cancelled by user",
                        progressMessage: "Transfer cancelled"
                    )
                }
            } catch {
            }
            await cleanupPartialDownloadIfNeeded(id: id)
        } catch {
            do {
                try await persistRecord(id: id) { record in
                    record.status = .error
                    record.errorMessage = error.localizedDescription
                    record.updatedAt = Date()
                }
                if let runtimeJobID {
                    try? await jobRepository.complete(
                        jobID: runtimeJobID,
                        status: .error,
                        message: error.localizedDescription,
                        progressMessage: "Transfer failed"
                    )
                }
            } catch {
            }
            await cleanupPartialDownloadIfNeeded(id: id)
            logger.error("Transfer \(id) failed: \(error.localizedDescription)")
        }
    }

    private func executeDownload(
        id: UUID,
        record: TransferRecord,
        runtimeJobID: UUID?
    ) async throws {
        guard
            let encodedState = record.stateID,
            let stateID = StateID(encodedID: encodedState)
        else {
            throw AppError.unexpected("The queued download has no valid target state.")
        }

        let remoteKey = cleanRemoteKey(from: stateID)
        let destinationURL = try makeDownloadedFileURL(
            accountID: record.accountID,
            remoteKey: remoteKey,
            preferredName: stateID.fileName ?? record.displayName
        )

        var completedTransferSize: Int64 = 0
        let storedDownloadSession = try await accountRepository.session(for: record.accountID)

        if storedDownloadSession?.isLegacy == true {
            let (_, server, credentials) = try await accountRepository.legacySessionContext(for: record.accountID)
            try await legacyP8Client.download(
                stateID: stateID,
                server: server,
                credentials: credentials,
                destinationURL: destinationURL
            ) { [weak self] transferred, expectedLength in
                guard let self else {
                    return
                }
                try await self.persistRecord(id: id) { mutable in
                    mutable.bytesTransferred = transferred
                    if let expectedLength {
                        mutable.bytesTotal = expectedLength
                    }
                    mutable.updatedAt = Date()
                }
                if let runtimeJobID {
                    _ = try? await self.jobRepository.update(jobID: runtimeJobID) { job in
                        if let expectedLength {
                            job.total = expectedLength
                        }
                        job.progress = transferred
                        job.progressMessage = "Downloading \(record.displayName)"
                    }
                }
            }
            completedTransferSize = try destinationURL
                .resourceValues(forKeys: [.fileSizeKey])
                .fileSize
                .map(Int64.init) ?? 0
        } else {
            let (_, server, token) = try await accountRepository.sessionContext(for: record.accountID)
            let signedRequest = try presigner.presign(
                serverURL: server.baseURL,
                bucket: "io",
                key: remoteKey,
                method: "GET",
                accessToken: token.accessToken
            )

            var request = URLRequest(url: signedRequest.url)
            request.httpMethod = "GET"
            signedRequest.headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }

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

            let session = sessionFactory.session(skipTLSVerification: server.skipTLSVerification)
            let (bytes, response) = try await session.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw AppError.unexpected("The download did not return an HTTP response.")
            }
            guard (200 ..< 300).contains(httpResponse.statusCode) else {
                throw AppError.serverUnreachable("Download failed with status \(httpResponse.statusCode).")
            }

            let expectedLength = response.expectedContentLength > 0 ? response.expectedContentLength : -1
            if expectedLength > 0 {
                try await persistRecord(id: id) { mutable in
                    mutable.bytesTotal = expectedLength
                    mutable.updatedAt = Date()
                }
                if let runtimeJobID {
                    _ = try? await jobRepository.update(jobID: runtimeJobID) { job in
                        job.total = expectedLength
                        job.progressMessage = "Downloading \(record.displayName)"
                    }
                }
            }

            var transferred: Int64 = 0
            var buffered = Data()
            var lastPersisted: Int64 = 0

            for try await byte in bytes {
                try Task.checkCancellation()
                buffered.append(byte)
                transferred += 1

                if buffered.count >= 64 * 1024 {
                    try fileHandle.write(contentsOf: buffered)
                    buffered.removeAll(keepingCapacity: true)
                }

                if transferred - lastPersisted >= 128 * 1024 {
                    lastPersisted = transferred
                    try await persistRecord(id: id) { mutable in
                        mutable.bytesTransferred = transferred
                        mutable.updatedAt = Date()
                    }
                    if let runtimeJobID {
                        _ = try? await jobRepository.update(jobID: runtimeJobID) { job in
                            if expectedLength > 0 {
                                job.total = expectedLength
                            }
                            job.progress = transferred
                            job.progressMessage = "Downloading \(record.displayName)"
                        }
                    }
                }
            }

            if !buffered.isEmpty {
                try fileHandle.write(contentsOf: buffered)
            }
            completedTransferSize = transferred
        }

        try await persistRecord(id: id) { mutable in
            mutable.status = .done
            mutable.localURL = destinationURL
            mutable.bytesTransferred = max(mutable.bytesTransferred, completedTransferSize)
            mutable.bytesTotal = max(mutable.bytesTotal ?? 0, completedTransferSize)
            mutable.errorMessage = nil
            mutable.updatedAt = Date()
        }
        if let runtimeJobID {
            _ = try? await jobRepository.update(jobID: runtimeJobID) { job in
                job.progress = max(job.progress, completedTransferSize)
                job.total = max(job.total, completedTransferSize)
                job.progressMessage = "Saved to local cache"
            }
        }
        if (try? await offlineRepository.isPinned(stateID: stateID)) == true {
            try? await offlineRepository.markSynced(
                stateID: stateID,
                message: "Downloaded to local cache"
            )
        }
    }

    private func executeUpload(
        id: UUID,
        record: TransferRecord,
        runtimeJobID: UUID?
    ) async throws {
        guard let localURL = record.localURL else {
            throw AppError.unexpected("The queued upload has no staged local file.")
        }
        guard FileManager.default.fileExists(atPath: localURL.path) else {
            throw AppError.unexpected("The staged upload file no longer exists.")
        }
        guard
            let encodedParent = record.stateID,
            let parentState = StateID(encodedID: encodedParent)
        else {
            throw AppError.unexpected("The queued upload has no valid remote parent.")
        }

        let total = try localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init) ?? 0
        try await persistRecord(id: id) { mutable in
            mutable.bytesTotal = total > 0 ? total : mutable.bytesTotal
            mutable.updatedAt = Date()
        }
        if let runtimeJobID, total > 0 {
            _ = try? await jobRepository.update(jobID: runtimeJobID) { job in
                job.total = total
                job.progressMessage = "Uploading \(record.displayName)"
            }
        }

        let storedUploadSession = try await accountRepository.session(for: record.accountID)
        if storedUploadSession?.isLegacy == true {
            let (_, server, credentials) = try await accountRepository.legacySessionContext(for: record.accountID)
            try await legacyP8Client.upload(
                localURL: localURL,
                to: parentState,
                displayName: record.displayName,
                server: server,
                credentials: credentials
            ) { [weak self] uploaded, totalBytes in
                guard let self else {
                    return
                }
                try await self.persistRecord(id: id) { mutable in
                    mutable.bytesTransferred = uploaded
                    mutable.bytesTotal = totalBytes
                    mutable.updatedAt = Date()
                }
                if let runtimeJobID {
                    _ = try? await self.jobRepository.update(jobID: runtimeJobID) { job in
                        job.progress = uploaded
                        job.total = totalBytes
                        job.progressMessage = "Uploading \(record.displayName)"
                    }
                }
            }
        } else {
            let (_, server, token) = try await accountRepository.sessionContext(for: record.accountID)
            let targetState = parentState.child(record.displayName)
            let remoteKey = cleanRemoteKey(from: targetState)
            let contentType = mimeType(for: localURL)
            let signedRequest = try presigner.presign(
                serverURL: server.baseURL,
                bucket: "data",
                key: remoteKey,
                method: "PUT",
                accessToken: token.accessToken,
                contentType: contentType
            )

            var request = URLRequest(url: signedRequest.url)
            request.httpMethod = "PUT"
            signedRequest.headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }

            let session = sessionFactory.session(skipTLSVerification: server.skipTLSVerification)
            let (_, response) = try await session.upload(for: request, fromFile: localURL)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw AppError.unexpected("The upload did not return an HTTP response.")
            }
            guard (200 ..< 300).contains(httpResponse.statusCode) else {
                throw AppError.serverUnreachable("Upload failed with status \(httpResponse.statusCode).")
            }
        }

        try await persistRecord(id: id) { mutable in
            mutable.status = .done
            mutable.bytesTransferred = total
            mutable.bytesTotal = total
            mutable.errorMessage = nil
            mutable.updatedAt = Date()
        }
        if let runtimeJobID {
            _ = try? await jobRepository.update(jobID: runtimeJobID) { job in
                job.progress = total
                job.total = total
                job.progressMessage = "Upload finished"
            }
        }
    }

    private func loadRecord(id: UUID) async throws -> TransferRecord {
        let current = try await database.transfers.load()
        guard let record = current.first(where: { $0.id == id }) else {
            throw AppError.unexpected("Missing transfer record \(id).")
        }
        return record
    }

    private func persistRecord(
        id: UUID,
        _ mutate: (inout TransferRecord) -> Void
    ) async throws {
        records = try await database.transfers.update { transfers in
            guard let index = transfers.firstIndex(where: { $0.id == id }) else {
                return
            }
            mutate(&transfers[index])
        }
    }

    private func cleanupPartialDownloadIfNeeded(id: UUID) async {
        guard
            let record = try? await loadRecord(id: id),
            record.kind == .download,
            let encodedState = record.stateID,
            let stateID = StateID(encodedID: encodedState)
        else {
            return
        }

        let remoteKey = cleanRemoteKey(from: stateID)
        if let localURL = try? makeDownloadedFileURL(
            accountID: record.accountID,
            remoteKey: remoteKey,
            preferredName: stateID.fileName ?? record.displayName
        ), FileManager.default.fileExists(atPath: localURL.path) {
            try? FileManager.default.removeItem(at: localURL)
        }
    }

    private func cleanRemoteKey(from stateID: StateID) -> String {
        let path = stateID.path ?? "/"
        return path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func makeDownloadedFileURL(
        accountID: String,
        remoteKey: String,
        preferredName: String
    ) throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let root = base
            .appending(path: "BitHub", directoryHint: .isDirectory)
            .appending(path: "RemoteFiles", directoryHint: .isDirectory)
            .appending(path: sanitizePathComponent(accountID), directoryHint: .isDirectory)

        let parts = remoteKey
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard !parts.isEmpty else {
            return root.appending(path: preferredName)
        }

        let folderParts = Array(parts.dropLast())
        let fileName = parts.last ?? preferredName
        let folderURL = folderParts.reduce(root) { partial, component in
            partial.appending(path: sanitizePathComponent(component), directoryHint: .isDirectory)
        }
        return folderURL.appending(path: sanitizePathComponent(fileName))
    }

    private func sanitizePathComponent(_ value: String) -> String {
        value.replacingOccurrences(of: "/", with: "_")
    }

    private func mimeType(for localURL: URL) -> String {
        if
            let type = UTType(filenameExtension: localURL.pathExtension),
            let mimeType = type.preferredMIMEType
        {
            return mimeType
        }
        return "application/octet-stream"
    }
}

final class AppBootstrapService {
    private let settingsStore: JSONStore<AppSettings>
    private let accountRepository: AccountRepository
    private let apiClient: PydioAPIClient
    private let legacyP8Client: LegacyP8Client
    private let logger: Logger

    init(
        settingsStore: JSONStore<AppSettings>,
        accountRepository: AccountRepository,
        apiClient: PydioAPIClient,
        legacyP8Client: LegacyP8Client,
        logger: Logger
    ) {
        self.settingsStore = settingsStore
        self.accountRepository = accountRepository
        self.apiClient = apiClient
        self.legacyP8Client = legacyP8Client
        self.logger = logger
    }

    func settings() async throws -> AppSettings {
        try await settingsStore.load()
    }

    func initialPhase() async -> AppPhase {
        do {
            let sessions = try await accountRepository.sessions()
            guard !sessions.isEmpty else {
                return .onboarding
            }

            let candidate = try await accountRepository.activeSession() ?? sessions.first
            guard let candidate else {
                return .accounts
            }

            if candidate.isLegacy {
                guard let server = try await accountRepository.server(for: candidate.serverID) else {
                    return .accounts
                }
                guard let credentials = try await accountRepository.legacyCredentials(for: candidate.accountID) else {
                    return .accounts
                }

                _ = try await legacyP8Client.fetchWorkspaces(server: server, credentials: credentials)
                try await accountRepository.updateStatus(
                    accountID: candidate.accountID,
                    status: .connected,
                    isReachable: true
                )
                let restored = try await accountRepository.session(for: candidate.accountID) ?? candidate
                return .authenticated(restored)
            }

            guard let token = try await accountRepository.token(for: candidate.accountID) else {
                return .accounts
            }
            guard let server = try await accountRepository.server(for: candidate.serverID) else {
                return .accounts
            }

            let appSettings = try await settingsStore.load()
            let effectiveToken: OAuthToken
            if token.isExpired, let refreshToken = token.refreshToken {
                effectiveToken = try await apiClient.refreshAccessToken(
                    server: server,
                    refreshToken: refreshToken,
                    clientID: appSettings.oauthClientID
                )
                try await accountRepository.saveToken(effectiveToken, for: candidate.accountID)
            } else {
                effectiveToken = token
            }

            _ = try await apiClient.fetchWorkspaces(server: server, token: effectiveToken)
            try await accountRepository.updateStatus(
                accountID: candidate.accountID,
                status: .connected,
                isReachable: true
            )
            let restored = try await accountRepository.session(for: candidate.accountID) ?? candidate
            return .authenticated(restored)
        } catch {
            logger.warning("Bootstrap restore failed: \(error.localizedDescription)")
            return .accounts
        }
    }
}

final class AppServices {
    let logger: Logger
    let database: AppDatabase
    let logRepository: LogRepository
    let jobRepository: JobRepository
    let offlineRepository: OfflineRepository
    let accountRepository: AccountRepository
    let nodeRepository: NodeRepository
    let apiClient: PydioAPIClient
    let legacyP8Client: LegacyP8Client
    let authSessionService: AuthSessionService
    let transferQueueService: TransferQueueService
    let offlineSyncService: OfflineSyncService
    let bootstrapService: AppBootstrapService

    @MainActor
    init() {
        let rootURL = Self.makeRootURL()
        database = AppDatabase(rootURL: rootURL)
        logRepository = LogRepository(store: database.logs)
        logger = Logger(logRepository: logRepository)
        jobRepository = JobRepository(store: database.jobs, logger: logger)
        offlineRepository = OfflineRepository(store: database.offlineRoots)
        let keychain = KeychainStore()
        apiClient = PydioAPIClient(logger: logger)
        legacyP8Client = LegacyP8Client(logger: logger)
        accountRepository = AccountRepository(database: database, keychain: keychain)
        nodeRepository = NodeRepository(
            database: database,
            apiClient: apiClient,
            legacyP8Client: legacyP8Client,
            accountRepository: accountRepository
        )
        authSessionService = AuthSessionService(
            apiClient: apiClient,
            legacyP8Client: legacyP8Client,
            accountRepository: accountRepository,
            logger: logger
        )
        transferQueueService = TransferQueueService(
            database: database,
            accountRepository: accountRepository,
            legacyP8Client: legacyP8Client,
            jobRepository: jobRepository,
            offlineRepository: offlineRepository,
            logger: logger
        )
        offlineSyncService = OfflineSyncService(
            nodeRepository: nodeRepository,
            transferQueueService: transferQueueService,
            jobRepository: jobRepository,
            offlineRepository: offlineRepository,
            logger: logger
        )
        bootstrapService = AppBootstrapService(
            settingsStore: database.settings,
            accountRepository: accountRepository,
            apiClient: apiClient,
            legacyP8Client: legacyP8Client,
            logger: logger
        )
    }

    private static func makeRootURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appending(path: "BitHub", directoryHint: .isDirectory)
    }
}
