import SwiftUI

@MainActor
final class OfflineRootsViewModel: ObservableObject {
    @Published private(set) var roots: [OfflineRootRecord] = []
    @Published private(set) var loadState: LoadState<[OfflineRootRecord]> = .idle
    @Published var statusMessage: String?

    private let session: AccountSession
    private let offlineRepository: OfflineRepository
    private let offlineSyncService: OfflineSyncService
    private let transferQueueService: TransferQueueService
    private let logger: Logger

    init(session: AccountSession, services: AppServices) {
        self.session = session
        self.offlineRepository = services.offlineRepository
        self.offlineSyncService = services.offlineSyncService
        self.transferQueueService = services.transferQueueService
        self.logger = services.logger
    }

    func load() async {
        loadState = .loading
        do {
            let roots = try await offlineRepository.roots(accountID: session.accountID)
            self.roots = roots
            loadState = .loaded(roots)
        } catch {
            self.roots = []
            loadState = .failed(error.localizedDescription)
            logger.warning("Could not load offline roots: \(error.localizedDescription)")
        }
    }

    func syncAll() async {
        do {
            _ = try await offlineSyncService.syncAll(session: session)
            statusMessage = "Queued offline sync preparation for all pinned roots."
            await load()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func sync(root: OfflineRootRecord) async {
        do {
            _ = try await offlineSyncService.sync(root: root, session: session)
            statusMessage = "Prepared offline content for \(root.displayName)."
            await load()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func remove(root: OfflineRootRecord) async {
        guard let stateID = root.stateID else {
            statusMessage = "The selected offline root is invalid."
            return
        }

        do {
            try await offlineRepository.remove(stateID: stateID)
            statusMessage = "Removed \(root.displayName) from offline roots."
            await load()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func localFileURL(for root: OfflineRootRecord) -> URL? {
        transferQueueService.localFileURL(
            accountID: session.accountID,
            stateID: root.encodedState
        )
    }
}

struct OfflineRootsView: View {
    let session: AccountSession
    let services: AppServices

    @StateObject private var viewModel: OfflineRootsViewModel
    @State private var previewURL: URL?
    @State private var shareURL: URL?

    init(session: AccountSession, services: AppServices) {
        self.session = session
        self.services = services
        _viewModel = StateObject(wrappedValue: OfflineRootsViewModel(session: session, services: services))
    }

    var body: some View {
        Group {
            switch viewModel.loadState {
            case .idle where viewModel.roots.isEmpty, .loading where viewModel.roots.isEmpty:
                LoadingCard(title: "Loading offline roots...")
            case .failed(let message) where viewModel.roots.isEmpty:
                EmptyStateCard(
                    title: "Offline Roots Unavailable",
                    message: message,
                    systemImage: "arrow.down.circle"
                )
            default:
                List {
                    if let statusMessage = viewModel.statusMessage {
                        InlineMessageBanner(
                            title: "Offline Status",
                            message: statusMessage,
                            tint: .teal
                        )
                        .listRowBackground(Color.clear)
                    }

                    if viewModel.roots.isEmpty {
                        EmptyStateCard(
                            title: "No Offline Roots",
                            message: "Pin files or folders from the browser to prepare them for offline access.",
                            systemImage: "arrow.down.circle"
                        )
                        .listRowBackground(Color.clear)
                    } else {
                        ForEach(viewModel.roots) { root in
                            offlineRootDestination(root)
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button("Remove", role: .destructive) {
                                        Task {
                                            await viewModel.remove(root: root)
                                        }
                                    }
                                }
                                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                    Button("Sync") {
                                        Task {
                                            await viewModel.sync(root: root)
                                        }
                                    }
                                    .tint(.blue)
                                }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Offline")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Sync All") {
                    Task {
                        await viewModel.syncAll()
                    }
                }

                Button {
                    Task {
                        await viewModel.load()
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
        .sheet(
            isPresented: Binding(
                get: { previewURL != nil },
                set: { if !$0 { previewURL = nil } }
            )
        ) {
            if let previewURL {
                QuickLookPreviewSheet(fileURL: previewURL)
            }
        }
        .sheet(
            isPresented: Binding(
                get: { shareURL != nil },
                set: { if !$0 { shareURL = nil } }
            )
        ) {
            if let shareURL {
                ShareSheet(activityItems: [shareURL])
            }
        }
        .task {
            await viewModel.load()
        }
    }

    @ViewBuilder
    private func offlineRootDestination(_ root: OfflineRootRecord) -> some View {
        if root.isFolder, let stateID = root.stateID {
            NavigationLink {
                FolderBrowserView(
                    session: session,
                    services: services,
                    folderStateID: stateID,
                    title: root.displayName
                )
            } label: {
                OfflineRootRowView(
                    root: root,
                    hasLocalFile: false
                )
            }
            .contextMenu {
                Button("Sync Now") {
                    Task {
                        await viewModel.sync(root: root)
                    }
                }
                Button("Remove Offline Root", role: .destructive) {
                    Task {
                        await viewModel.remove(root: root)
                    }
                }
            }
        } else {
            let localURL = viewModel.localFileURL(for: root)
            Button {
                if let localURL {
                    previewURL = localURL
                }
            } label: {
                OfflineRootRowView(root: root, hasLocalFile: localURL != nil)
            }
            .buttonStyle(.plain)
            .contextMenu {
                if let localURL {
                    Button("Preview Downloaded File") {
                        previewURL = localURL
                    }
                    Button("Share File") {
                        shareURL = localURL
                    }
                }
                Button(localURL == nil ? "Prepare Offline Download" : "Refresh Offline Copy") {
                    Task {
                        await viewModel.sync(root: root)
                    }
                }
                Button("Remove Offline Root", role: .destructive) {
                    Task {
                        await viewModel.remove(root: root)
                    }
                }
            }
        }
    }
}

private struct OfflineRootRowView: View {
    let root: OfflineRootRecord
    let hasLocalFile: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: root.isFolder ? "folder.fill" : "doc.fill")
                    .foregroundStyle(root.isFolder ? Color.accentColor : Color.secondary)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(root.displayName)
                            .font(.body.weight(.medium))
                        Text(root.status.rawValue.capitalized)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(statusTint.opacity(0.15), in: Capsule())
                            .foregroundStyle(statusTint)
                        if hasLocalFile {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    }

                    Text(root.isFolder ? "Folder offline root" : "File offline root")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if let message = root.message, !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("Last check: \(formattedDate(root.lastCheckDate))")
                if let localModificationDate = root.localModificationDate {
                    Text("| Updated \(formattedDate(localModificationDate))")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }

    private var statusTint: Color {
        switch root.status {
        case .new:
            return .orange
        case .active:
            return .green
        case .lost:
            return .red
        }
    }
}

@MainActor
final class JobsViewModel: ObservableObject {
    @Published private(set) var jobs: [BackgroundJobRecord] = []
    @Published private(set) var loadState: LoadState<[BackgroundJobRecord]> = .idle
    @Published var showChildren = true
    @Published var statusMessage: String?

    private let jobRepository: JobRepository
    private let logger: Logger

    init(services: AppServices) {
        self.jobRepository = services.jobRepository
        self.logger = services.logger
    }

    func load() async {
        do {
            let jobs = try await jobRepository.list(showChildren: showChildren)
            self.jobs = jobs
            loadState = .loaded(jobs)
        } catch {
            self.jobs = []
            loadState = .failed(error.localizedDescription)
            logger.warning("Could not load runtime jobs: \(error.localizedDescription)")
        }
    }

    func clearTerminated() async {
        await jobRepository.clearTerminated()
        statusMessage = "Removed terminated jobs."
        await load()
    }
}

struct JobsView: View {
    @StateObject private var viewModel: JobsViewModel

    init(services: AppServices) {
        _viewModel = StateObject(wrappedValue: JobsViewModel(services: services))
    }

    var body: some View {
        Group {
            switch viewModel.loadState {
            case .idle where viewModel.jobs.isEmpty, .loading where viewModel.jobs.isEmpty:
                LoadingCard(title: "Loading jobs...")
            case .failed(let message) where viewModel.jobs.isEmpty:
                EmptyStateCard(
                    title: "No Jobs Available",
                    message: message,
                    systemImage: "tray.full"
                )
            default:
                List {
                    if let statusMessage = viewModel.statusMessage {
                        InlineMessageBanner(
                            title: "Job Status",
                            message: statusMessage,
                            tint: .blue
                        )
                        .listRowBackground(Color.clear)
                    }

                    if viewModel.jobs.isEmpty {
                        EmptyStateCard(
                            title: "No Active Jobs",
                            message: "Transfer and offline sync runtime jobs will appear here.",
                            systemImage: "tray"
                        )
                        .listRowBackground(Color.clear)
                    } else {
                        ForEach(viewModel.jobs) { job in
                            JobRowView(job: job)
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Jobs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(viewModel.showChildren ? "Hide Children" : "Show Children") {
                    viewModel.showChildren.toggle()
                    Task {
                        await viewModel.load()
                    }
                }

                Button("Clear Finished") {
                    Task {
                        await viewModel.clearTerminated()
                    }
                }

                Button {
                    Task {
                        await viewModel.load()
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
        .task {
            while !Task.isCancelled {
                await viewModel.load()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
}

private struct JobRowView: View {
    let job: BackgroundJobRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(job.label)
                        .font(.subheadline.weight(.semibold))
                    Text("#\(job.id.uuidString.prefix(8)) | \(job.template)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(job.status.rawValue.capitalized)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(statusTint.opacity(0.15), in: Capsule())
                    .foregroundStyle(statusTint)
            }

            if let fraction = job.progressFraction, fraction > 0, fraction < 1.01 {
                ProgressView(value: fraction)
            }

            if let progressMessage = job.progressMessage, !progressMessage.isEmpty {
                Text(progressMessage)
                    .font(.caption)
            }

            if let message = job.message, !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("Updated \(formattedDate(job.updatedAt))")
                if let startedAt = job.startedAt {
                    Text("| Started \(formattedDate(startedAt))")
                }
                if let finishedAt = job.finishedAt {
                    Text("| Finished \(formattedDate(finishedAt))")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }

    private var statusTint: Color {
        switch job.status {
        case .new, .processing:
            return .blue
        case .done:
            return .green
        case .warning, .cancelled:
            return .orange
        case .error, .timeout:
            return .red
        }
    }
}

@MainActor
final class LogsViewModel: ObservableObject {
    @Published private(set) var logs: [LogRecord] = []
    @Published private(set) var loadState: LoadState<[LogRecord]> = .idle
    @Published var statusMessage: String?

    private let logRepository: LogRepository
    private let logger: Logger

    init(services: AppServices) {
        self.logRepository = services.logRepository
        self.logger = services.logger
    }

    func load() async {
        do {
            let logs = try await logRepository.list()
            self.logs = logs
            loadState = .loaded(logs)
        } catch {
            self.logs = []
            loadState = .failed(error.localizedDescription)
            logger.warning("Could not load runtime logs: \(error.localizedDescription)")
        }
    }

    func clear() async {
        await logRepository.clear()
        statusMessage = "Cleared runtime logs."
        await load()
    }
}

struct LogsView: View {
    @StateObject private var viewModel: LogsViewModel

    init(services: AppServices) {
        _viewModel = StateObject(wrappedValue: LogsViewModel(services: services))
    }

    var body: some View {
        Group {
            switch viewModel.loadState {
            case .idle where viewModel.logs.isEmpty, .loading where viewModel.logs.isEmpty:
                LoadingCard(title: "Loading logs...")
            case .failed(let message) where viewModel.logs.isEmpty:
                EmptyStateCard(
                    title: "No Logs Available",
                    message: message,
                    systemImage: "doc.text.magnifyingglass"
                )
            default:
                List {
                    if let statusMessage = viewModel.statusMessage {
                        InlineMessageBanner(
                            title: "Log Status",
                            message: statusMessage,
                            tint: .orange
                        )
                        .listRowBackground(Color.clear)
                    }

                    if viewModel.logs.isEmpty {
                        EmptyStateCard(
                            title: "No Runtime Logs",
                            message: "Network, auth, transfer, and sync events will appear here.",
                            systemImage: "doc.text"
                        )
                        .listRowBackground(Color.clear)
                    } else {
                        ForEach(viewModel.logs) { log in
                            LogRowView(log: log)
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Logs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Clear") {
                    Task {
                        await viewModel.clear()
                    }
                }

                Button {
                    Task {
                        await viewModel.load()
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
        .task {
            while !Task.isCancelled {
                await viewModel.load()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
}

private struct LogRowView: View {
    let log: LogRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(formattedAbsoluteDate(log.timestamp))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(log.level.rawValue.uppercased())
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(levelTint.opacity(0.15), in: Capsule())
                    .foregroundStyle(levelTint)
            }

            if let tag = log.tag, !tag.isEmpty {
                Text(tag)
                    .font(.caption.weight(.semibold))
            }

            Text(log.message)
                .font(.subheadline)

            if let callerID = log.callerID, !callerID.isEmpty {
                Text("Caller: \(callerID)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }

    private var levelTint: Color {
        switch log.level {
        case .debug:
            return .blue
        case .info:
            return .green
        case .warning:
            return .orange
        case .error:
            return .red
        }
    }
}

private func formattedAbsoluteDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .medium
    return formatter.string(from: date)
}
