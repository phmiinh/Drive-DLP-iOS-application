import Foundation

final class OfflineSyncService {
    private let nodeRepository: NodeRepository
    private let transferQueueService: TransferQueueService
    private let jobRepository: JobRepository
    private let offlineRepository: OfflineRepository
    private let logger: Logger

    init(
        nodeRepository: NodeRepository,
        transferQueueService: TransferQueueService,
        jobRepository: JobRepository,
        offlineRepository: OfflineRepository,
        logger: Logger
    ) {
        self.nodeRepository = nodeRepository
        self.transferQueueService = transferQueueService
        self.jobRepository = jobRepository
        self.offlineRepository = offlineRepository
        self.logger = logger
    }

    @discardableResult
    func syncAll(session: AccountSession) async throws -> UUID {
        let roots = try await offlineRepository.roots(accountID: session.accountID)
        logger.info("Preparing offline sync for \(roots.count) pinned roots in \(session.accountID)")
        let job = try await jobRepository.create(
            owner: session.accountID,
            template: "offline.fullsync",
            label: "Offline sync for \(session.serverLabel)",
            total: Int64(max(roots.count, 1))
        )
        try await jobRepository.launched(jobID: job.id)

        guard !roots.isEmpty else {
            try await jobRepository.complete(
                jobID: job.id,
                status: .warning,
                message: "No offline roots are currently pinned.",
                progressMessage: "Nothing to sync"
            )
            return job.id
        }

        var warnings: [String] = []
        for root in roots {
            do {
                let queuedCount = try await sync(root: root, session: session, parentJobID: job.id)
                try await jobRepository.incrementProgress(
                    jobID: job.id,
                    increment: 1,
                    message: "Prepared \(queuedCount) file(s) for \(root.displayName)"
                )
            } catch {
                warnings.append("\(root.displayName): \(error.localizedDescription)")
                try await jobRepository.incrementProgress(
                    jobID: job.id,
                    increment: 1,
                    message: "Failed to prepare \(root.displayName)"
                )
                logger.warning("Offline root sync failed for \(root.displayName): \(error.localizedDescription)")
            }
        }

        try await jobRepository.complete(
            jobID: job.id,
            status: warnings.isEmpty ? .done : .warning,
            message: warnings.isEmpty
                ? "Prepared \(roots.count) offline root(s)."
                : warnings.joined(separator: "\n"),
            progressMessage: "Offline sync preparation finished"
        )
        logger.info("Offline sync preparation finished for \(session.accountID)")
        return job.id
    }

    @discardableResult
    func sync(root: OfflineRootRecord, session: AccountSession, parentJobID: UUID? = nil) async throws -> Int {
        guard let stateID = root.stateID else {
            throw AppError.unexpected("Pinned offline root \(root.displayName) has an invalid state identifier.")
        }

        let childJob = try await jobRepository.create(
            owner: session.accountID,
            template: "offline.root.sync",
            label: "Sync \(root.displayName)",
            parentID: parentJobID,
            total: root.isFolder ? -1 : 1
        )
        try await jobRepository.launched(jobID: childJob.id)
        logger.info("Preparing offline root \(root.displayName)")

        do {
            let queuedCount = try await queueDownloads(for: root, stateID: stateID, session: session)
            try await offlineRepository.markSynced(
                stateID: stateID,
                message: queuedCount > 0
                    ? "Prepared \(queuedCount) file(s) for offline use"
                    : "Already cached locally"
            )
            try await jobRepository.complete(
                jobID: childJob.id,
                status: .done,
                message: "Prepared \(queuedCount) file(s) for \(root.displayName)",
                progressMessage: "Offline root queued"
            )
            logger.info("Prepared \(queuedCount) file(s) for offline root \(root.displayName)")
            return queuedCount
        } catch {
            try await jobRepository.complete(
                jobID: childJob.id,
                status: .error,
                message: error.localizedDescription,
                progressMessage: "Offline root failed"
            )
            logger.error("Offline root \(root.displayName) failed: \(error.localizedDescription)")
            throw error
        }
    }

    private func queueDownloads(
        for root: OfflineRootRecord,
        stateID: StateID,
        session: AccountSession
    ) async throws -> Int {
        if root.isFolder {
            return try await scanFolder(stateID, session: session)
        }

        let alreadyCached = await MainActor.run {
            transferQueueService.localFileURL(
                accountID: session.accountID,
                stateID: stateID.encodedID
            ) != nil
        }
        guard !alreadyCached else {
            return 0
        }

        let queued = await transferQueueService.enqueue(
            kind: .download,
            accountID: session.accountID,
            stateID: stateID.encodedID,
            localURL: nil,
            displayName: root.displayName
        )
        return queued ? 1 : 0
    }

    private func scanFolder(_ folderStateID: StateID, session: AccountSession) async throws -> Int {
        let children = try await nodeRepository.loadChildren(
            of: folderStateID,
            session: session,
            sortOrder: .nameAscending
        )

        var queuedCount = 0
        for child in children {
            try Task.checkCancellation()
            if child.isFolder {
                queuedCount += try await scanFolder(child.stateID, session: session)
                continue
            }

            let alreadyCached = await MainActor.run {
                transferQueueService.localFileURL(
                    accountID: session.accountID,
                    stateID: child.stateID.encodedID
                ) != nil
            }
            guard !alreadyCached else {
                continue
            }

            let queued = await transferQueueService.enqueue(
                kind: .download,
                accountID: session.accountID,
                stateID: child.stateID.encodedID,
                localURL: nil,
                displayName: child.name
            )
            if queued {
                queuedCount += 1
            }
        }
        return queuedCount
    }
}
