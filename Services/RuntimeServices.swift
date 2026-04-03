import Foundation

actor LogRepository {
    private let store: JSONStore<[LogRecord]>

    init(store: JSONStore<[LogRecord]>) {
        self.store = store
    }

    func list() async throws -> [LogRecord] {
        try await store.load().sorted { $0.timestamp > $1.timestamp }
    }

    func append(level: LogLevel, tag: String?, message: String, callerID: String?) async {
        let record = LogRecord(
            id: UUID(),
            timestamp: Date(),
            level: level,
            tag: tag,
            message: message,
            callerID: callerID
        )
        do {
            _ = try await store.update { logs in
                logs.insert(record, at: 0)
                if logs.count > 500 {
                    logs = Array(logs.prefix(500))
                }
            }
        } catch {
        }
    }

    func clear() async {
        do {
            try await store.save([])
        } catch {
        }
    }
}

actor JobRepository {
    private let store: JSONStore<[BackgroundJobRecord]>
    private let logger: Logger

    init(store: JSONStore<[BackgroundJobRecord]>, logger: Logger) {
        self.store = store
        self.logger = logger
    }

    func list(showChildren: Bool = true) async throws -> [BackgroundJobRecord] {
        let jobs = try await store.load()
        return jobs
            .filter { showChildren || $0.parentID == nil }
            .sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.createdAt > rhs.createdAt
            }
    }

    func create(
        owner: String,
        template: String,
        label: String,
        parentID: UUID? = nil,
        total: Int64 = -1,
        status: BackgroundJobStatus = .new
    ) async throws -> BackgroundJobRecord {
        let now = Date()
        let job = BackgroundJobRecord(
            id: UUID(),
            owner: owner,
            template: template,
            label: label,
            parentID: parentID,
            status: status,
            progress: 0,
            total: total,
            message: nil,
            progressMessage: nil,
            createdAt: now,
            updatedAt: now,
            startedAt: status == .processing ? now : nil,
            finishedAt: nil
        )
        _ = try await store.update { jobs in
            jobs.insert(job, at: 0)
        }
        return job
    }

    func update(
        jobID: UUID,
        _ mutate: (inout BackgroundJobRecord) -> Void
    ) async throws -> BackgroundJobRecord {
        let updated = try await store.update { jobs in
            guard let index = jobs.firstIndex(where: { $0.id == jobID }) else {
                return
            }
            mutate(&jobs[index])
            jobs[index].updatedAt = Date()
        }
        guard let job = updated.first(where: { $0.id == jobID }) else {
            throw AppError.unexpected("Missing runtime job \(jobID).")
        }
        return job
    }

    func launched(jobID: UUID) async throws {
        _ = try await update(jobID: jobID) { job in
            job.status = .processing
            job.startedAt = Date()
            job.progressMessage = job.progressMessage ?? "Started"
        }
    }

    func incrementProgress(jobID: UUID, increment: Int64, message: String?) async throws {
        _ = try await update(jobID: jobID) { job in
            job.progress += increment
            if let message, !message.isEmpty {
                job.progressMessage = message
            }
        }
    }

    func updateTotal(jobID: UUID, total: Int64, status: BackgroundJobStatus?, message: String?) async throws {
        _ = try await update(jobID: jobID) { job in
            job.total = total
            if let status {
                job.status = status
            }
            if let message, !message.isEmpty {
                job.progressMessage = message
            }
        }
    }

    func complete(jobID: UUID, status: BackgroundJobStatus, message: String?, progressMessage: String?) async throws {
        let finishedAt = Date()
        _ = try await update(jobID: jobID) { job in
            job.status = status
            job.finishedAt = finishedAt
            if job.total > 0 {
                job.progress = job.total
            }
            if let message, !message.isEmpty {
                job.message = message
            }
            if let progressMessage, !progressMessage.isEmpty {
                job.progressMessage = progressMessage
            }
        }
    }

    func clearTerminated() async {
        do {
            try await store.update { jobs in
                jobs.removeAll {
                    $0.status == .done ||
                    $0.status == .cancelled ||
                    $0.status == .error ||
                    $0.status == .timeout
                }
            }
        } catch {
            logger.warning("Could not clear runtime jobs: \(error.localizedDescription)")
        }
    }
}

actor OfflineRepository {
    private let store: JSONStore<[OfflineRootRecord]>

    init(store: JSONStore<[OfflineRootRecord]>) {
        self.store = store
    }

    func roots(accountID: String? = nil) async throws -> [OfflineRootRecord] {
        let roots = try await store.load()
        return roots
            .filter { accountID == nil || $0.accountID == accountID }
            .sorted { lhs, rhs in
                if lhs.displayName != rhs.displayName {
                    return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
                }
                return lhs.encodedState < rhs.encodedState
            }
    }

    func isPinned(stateID: StateID) async throws -> Bool {
        try await roots().contains { $0.encodedState == stateID.encodedID }
    }

    func upsert(root: OfflineRootRecord) async throws {
        _ = try await store.update { roots in
            if let index = roots.firstIndex(where: { $0.encodedState == root.encodedState }) {
                roots[index] = root
            } else {
                roots.append(root)
            }
        }
    }

    func toggle(node: RemoteNode, accountID: String, enabled: Bool) async throws {
        if enabled {
            let root = OfflineRootRecord(
                encodedState: node.stateID.encodedID,
                accountID: accountID,
                displayName: node.name,
                isFolder: node.isFolder,
                status: .new,
                localModificationDate: nil,
                lastCheckDate: nil,
                message: nil,
                storage: "internal"
            )
            try await upsert(root: root)
        } else {
            try await remove(stateID: node.stateID)
        }
    }

    func markSynced(stateID: StateID, message: String?) async throws {
        _ = try await store.update { roots in
            guard let index = roots.firstIndex(where: { $0.encodedState == stateID.encodedID }) else {
                return
            }
            roots[index].status = .active
            roots[index].lastCheckDate = Date()
            roots[index].localModificationDate = Date()
            roots[index].message = message
        }
    }

    func remove(stateID: StateID) async throws {
        _ = try await store.update { roots in
            roots.removeAll { $0.encodedState == stateID.encodedID }
        }
    }
}
