import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class FolderBrowserViewModel: ObservableObject {
    @Published private(set) var nodes: [RemoteNode] = []
    @Published private(set) var searchResults: [RemoteNode] = []
    @Published private(set) var loadState: LoadState<[RemoteNode]> = .idle
    @Published private(set) var pinnedStateIDs: Set<String> = []
    @Published var bannerMessage: String?
    @Published var searchText = ""
    @Published var selectedSortOrder: NodeSortOrder = .nameAscending
    @Published var isPresentingCreateFolder = false
    @Published var isPresentingUploadPicker = false
    @Published var nodePendingRename: RemoteNode?
    @Published var nodePendingDeletion: RemoteNode?
    @Published var nodePendingRelocation: NodeRelocationRequest?
    @Published var publicLinkShareItem: PublicLinkShareItem?
    @Published var selectedFile: RemoteNode?
    @Published private(set) var activeSearchQuery: String?

    private let session: AccountSession
    private let folderStateID: StateID
    private let nodeRepository: NodeRepository
    private let offlineRepository: OfflineRepository
    private let transferQueueService: TransferQueueService
    private let logger: Logger

    init(
        session: AccountSession,
        folderStateID: StateID,
        nodeRepository: NodeRepository,
        offlineRepository: OfflineRepository,
        transferQueueService: TransferQueueService,
        logger: Logger
    ) {
        self.session = session
        self.folderStateID = folderStateID
        self.nodeRepository = nodeRepository
        self.offlineRepository = offlineRepository
        self.transferQueueService = transferQueueService
        self.logger = logger
    }

    var displayedNodes: [RemoteNode] {
        activeSearchQuery == nil ? nodes : searchResults
    }

    func load(forceRemote: Bool = true) async {
        if forceRemote {
            loadState = .loading
        }
        bannerMessage = nil
        await refreshOfflinePins()

        do {
            let remoteNodes = try await nodeRepository.loadChildren(
                of: folderStateID,
                session: session,
                sortOrder: selectedSortOrder
            )
            nodes = remoteNodes
            loadState = .loaded(remoteNodes)
        } catch {
            let cached = (try? await nodeRepository.cachedChildren(for: folderStateID)) ?? []
            if cached.isEmpty {
                loadState = .failed(error.localizedDescription)
            } else {
                nodes = cached
                loadState = .loaded(cached)
                bannerMessage = "Showing cached results because the server refresh failed."
            }
        }
    }

    func isPinned(_ node: RemoteNode) -> Bool {
        pinnedStateIDs.contains(node.stateID.encodedID)
    }

    func localFileURL(for node: RemoteNode) -> URL? {
        transferQueueService.localFileURL(
            accountID: session.accountID,
            stateID: node.stateID.encodedID
        )
    }

    func search() async {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            activeSearchQuery = nil
            searchResults = []
            return
        }

        bannerMessage = nil
        do {
            let results = try await nodeRepository.search(
                query: trimmed,
                in: folderStateID,
                session: session
            )
            activeSearchQuery = trimmed
            searchResults = results
        } catch {
            bannerMessage = error.localizedDescription
            logger.warning("Search failed in \(folderStateID.encodedID): \(error.localizedDescription)")
        }
    }

    func clearSearchIfNeeded() {
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            activeSearchQuery = nil
            searchResults = []
        }
    }

    func createFolder(named name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            bannerMessage = "Folder names cannot be empty."
            return
        }

        do {
            try await nodeRepository.createFolder(name: trimmed, in: folderStateID, session: session)
            await load()
        } catch {
            bannerMessage = error.localizedDescription
        }
    }

    func rename(node: RemoteNode, newName: String) async {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            bannerMessage = "The new name cannot be empty."
            return
        }

        do {
            try await nodeRepository.rename(node: node, newName: trimmed, session: session)
            await load()
        } catch {
            bannerMessage = error.localizedDescription
        }
    }

    func delete(node: RemoteNode) async {
        do {
            try await nodeRepository.delete(nodes: [node], session: session)
            nodePendingDeletion = nil
            await load()
        } catch {
            bannerMessage = error.localizedDescription
        }
    }

    func prepareRelocation(of node: RemoteNode, operation: NodeRelocationOperation) {
        nodePendingRelocation = NodeRelocationRequest(node: node, operation: operation)
    }

    func relocate(_ request: NodeRelocationRequest, to destination: StateID) async {
        do {
            try validateRelocation(request, destination: destination)
            let successMessage: String
            switch request.operation {
            case .move:
                try await nodeRepository.move(nodes: [request.node], to: destination, session: session)
                successMessage = "Moved \(request.node.name)."
            case .copy:
                try await nodeRepository.copy(nodes: [request.node], to: destination, session: session)
                successMessage = "Copied \(request.node.name)."
            }
            nodePendingRelocation = nil
            if selectedFile?.id == request.node.id {
                selectedFile = nil
            }
            await load()
            bannerMessage = successMessage
        } catch {
            bannerMessage = error.localizedDescription
        }
    }

    func toggleBookmark(node: RemoteNode) async {
        do {
            let enabled = !node.isBookmarked
            try await nodeRepository.setBookmarked(node: node, enabled: enabled, session: session)
            let successMessage = enabled
                ? "Bookmarked \(node.name)."
                : "Removed bookmark from \(node.name)."
            await load()
            bannerMessage = successMessage
        } catch {
            bannerMessage = error.localizedDescription
        }
    }

    func sharePublicLink(node: RemoteNode) async {
        do {
            let address = try await nodeRepository.createOrFetchPublicLink(for: node, session: session)
            let successMessage = node.isShared
                ? "Loaded the public link for \(node.name)."
                : "Created a public link for \(node.name)."
            await load()
            publicLinkShareItem = PublicLinkShareItem(title: node.name, link: address)
            bannerMessage = successMessage
        } catch {
            bannerMessage = error.localizedDescription
        }
    }

    func removePublicLink(node: RemoteNode) async {
        do {
            try await nodeRepository.removePublicLink(for: node, session: session)
            await load()
            bannerMessage = "Removed the public link for \(node.name)."
        } catch {
            bannerMessage = error.localizedDescription
        }
    }

    func queueDownload(_ node: RemoteNode) async {
        let queued = await transferQueueService.enqueue(
            kind: .download,
            accountID: session.accountID,
            stateID: node.stateID.encodedID,
            localURL: nil,
            displayName: node.name
        )
        bannerMessage = queued
            ? "Queued \(node.name) for download."
            : "\(node.name) is already downloaded or queued."
    }

    func handleFileImport(result: Result<[URL], Error>) async {
        do {
            guard let importedURL = try result.get().first else {
                bannerMessage = "No file was selected."
                return
            }
            let stagedURL = try stageImportedFile(importedURL)
            let queued = await transferQueueService.enqueue(
                kind: .upload,
                accountID: session.accountID,
                stateID: folderStateID.encodedID,
                localURL: stagedURL,
                displayName: importedURL.lastPathComponent
            )
            bannerMessage = queued
                ? "Staged \(importedURL.lastPathComponent) for upload."
                : "\(importedURL.lastPathComponent) is already queued for upload."
        } catch {
            bannerMessage = error.localizedDescription
        }
    }

    func toggleOffline(node: RemoteNode) async {
        let shouldEnable = !isPinned(node)
        do {
            try await offlineRepository.toggle(
                node: node,
                accountID: session.accountID,
                enabled: shouldEnable
            )
            await refreshOfflinePins()

            if shouldEnable, !node.isFolder, localFileURL(for: node) == nil {
                let queued = await transferQueueService.enqueue(
                    kind: .download,
                    accountID: session.accountID,
                    stateID: node.stateID.encodedID,
                    localURL: nil,
                    displayName: node.name
                )
                bannerMessage = queued
                    ? "Pinned \(node.name) and queued an offline download."
                    : "Pinned \(node.name) for offline use."
            } else if shouldEnable {
                bannerMessage = node.isFolder
                    ? "Pinned \(node.name) for offline sync."
                    : "Pinned \(node.name) for offline use."
            } else {
                bannerMessage = "Removed \(node.name) from offline roots."
            }
        } catch {
            bannerMessage = error.localizedDescription
        }
    }

    private func refreshOfflinePins() async {
        do {
            let roots = try await offlineRepository.roots(accountID: session.accountID)
            pinnedStateIDs = Set(roots.map(\.encodedState))
        } catch {
            logger.warning("Could not refresh offline roots for \(session.accountID): \(error.localizedDescription)")
        }
    }

    private func validateRelocation(
        _ request: NodeRelocationRequest,
        destination: StateID
    ) throws {
        guard destination.workspaceSlug == request.node.stateID.workspaceSlug else {
            throw AppError.unsupported(
                "Move and copy currently stay inside one workspace, matching the Android contract."
            )
        }
        guard request.operation != .move || destination.encodedID != request.node.stateID.parent().encodedID else {
            throw AppError.unexpected("\(request.node.name) is already in this folder.")
        }
        guard request.node.isFolder else {
            return
        }
        guard
            let sourcePath = request.node.stateID.path?.normalizedFolderPath,
            let destinationPath = destination.path?.normalizedFolderPath
        else {
            return
        }
        if destinationPath == sourcePath || destinationPath.hasPrefix(sourcePath + "/") {
            throw AppError.unexpected("A folder cannot be moved or copied into itself.")
        }
    }

    private func stageImportedFile(_ sourceURL: URL) throws -> URL {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let stagingDirectory = base
            .appending(path: "BitHub", directoryHint: .isDirectory)
            .appending(path: "Staging", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: true
        )

        let sanitized = sourceURL.lastPathComponent.replacingOccurrences(of: "/", with: "-")
        let targetURL = stagingDirectory.appending(path: "\(UUID().uuidString)-\(sanitized)")
        if FileManager.default.fileExists(atPath: targetURL.path) {
            try FileManager.default.removeItem(at: targetURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: targetURL)
        return targetURL
    }
}

struct FolderBrowserView: View {
    let session: AccountSession
    let services: AppServices
    let folderStateID: StateID
    let title: String

    @StateObject private var viewModel: FolderBrowserViewModel

    init(
        session: AccountSession,
        services: AppServices,
        folderStateID: StateID,
        title: String
    ) {
        self.session = session
        self.services = services
        self.folderStateID = folderStateID
        self.title = title
        _viewModel = StateObject(
            wrappedValue: FolderBrowserViewModel(
                session: session,
                folderStateID: folderStateID,
                nodeRepository: services.nodeRepository,
                offlineRepository: services.offlineRepository,
                transferQueueService: services.transferQueueService,
                logger: services.logger
            )
        )
    }

    var body: some View {
        contentView
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $viewModel.searchText, prompt: "Search in this folder")
        .onSubmit(of: .search) {
            Task {
                await viewModel.search()
            }
        }
        .onChange(of: viewModel.searchText) { _ in
            viewModel.clearSearchIfNeeded()
        }
        .toolbar { browserToolbar }
        .sheet(isPresented: $viewModel.isPresentingCreateFolder) {
            FolderNameSheet(
                title: "Create Folder",
                confirmLabel: "Create",
                initialValue: ""
            ) { name in
                Task {
                    await viewModel.createFolder(named: name)
                }
            }
        }
        .sheet(item: $viewModel.nodePendingRename) { node in
            FolderNameSheet(
                title: "Rename Item",
                confirmLabel: "Rename",
                initialValue: node.name
            ) { newName in
                Task {
                    await viewModel.rename(node: node, newName: newName)
                }
            }
        }
        .sheet(item: $viewModel.nodePendingRelocation) { request in
            RemoteFolderPickerSheet(
                session: session,
                services: services,
                request: request
            ) { destination in
                Task {
                    await viewModel.relocate(request, to: destination)
                }
            }
        }
        .sheet(item: $viewModel.publicLinkShareItem) { item in
            ShareSheet(activityItems: [item.link])
        }
        .sheet(item: $viewModel.selectedFile) { node in
            RemoteNodeDetailSheet(
                node: node,
                queueService: services.transferQueueService,
                accountID: session.accountID,
                isPinned: viewModel.isPinned(node),
                queueDownload: {
                    await viewModel.queueDownload(node)
                },
                requestMove: {
                    viewModel.prepareRelocation(of: node, operation: .move)
                },
                requestCopy: {
                    viewModel.prepareRelocation(of: node, operation: .copy)
                },
                toggleBookmark: {
                    await viewModel.toggleBookmark(node: node)
                },
                sharePublicLink: {
                    await viewModel.sharePublicLink(node: node)
                },
                removePublicLink: {
                    await viewModel.removePublicLink(node: node)
                },
                toggleOffline: {
                    await viewModel.toggleOffline(node: node)
                }
            )
        }
        .fileImporter(
            isPresented: $viewModel.isPresentingUploadPicker,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            Task {
                await viewModel.handleFileImport(result: result)
            }
        }
        .confirmationDialog(
            "Delete this item?",
            isPresented: deleteDialogIsPresented,
            titleVisibility: .visible
        ) {
            deleteConfirmationActions
        }
        .task {
            await viewModel.load()
        }
    }

    @ViewBuilder
    private var contentView: some View {
        switch viewModel.loadState {
        case .idle:
            LoadingCard(title: "Loading folder contents...")
        case .loading where viewModel.displayedNodes.isEmpty:
            LoadingCard(title: "Loading folder contents...")
        case .failed(let message) where viewModel.displayedNodes.isEmpty:
            EmptyStateCard(
                title: "Folder Unavailable",
                message: message,
                systemImage: "folder.badge.questionmark"
            )
        default:
            folderList
        }
    }

    private var folderList: some View {
        List {
            listContent
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private var listContent: some View {
        if let bannerMessage = viewModel.bannerMessage {
            InlineMessageBanner(
                title: "Folder Status",
                message: bannerMessage
            )
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .listRowBackground(Color.clear)
        }

        if viewModel.displayedNodes.isEmpty {
            EmptyStateCard(
                title: viewModel.activeSearchQuery == nil ? "Empty Folder" : "No Matches",
                message: viewModel.activeSearchQuery == nil
                    ? "This folder currently has no visible items."
                    : "No remote nodes matched the current folder-scoped search.",
                systemImage: viewModel.activeSearchQuery == nil ? "folder" : "magnifyingglass"
            )
            .listRowBackground(Color.clear)
        } else {
            ForEach(viewModel.displayedNodes) { node in
                nodeRow(node)
            }
        }
    }

    @ViewBuilder
    private func nodeRow(_ node: RemoteNode) -> some View {
        nodeDestination(node)
            .contextMenu {
                nodeContextMenu(node)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button("Delete", role: .destructive) {
                    viewModel.nodePendingDeletion = node
                }
                Button("Rename") {
                    viewModel.nodePendingRename = node
                }
                .tint(.orange)
            }
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                Button(viewModel.isPinned(node) ? "Unpin" : "Pin") {
                    Task {
                        await viewModel.toggleOffline(node: node)
                    }
                }
                .tint(.teal)

                if !node.isFolder {
                    Button("Download") {
                        Task {
                            await viewModel.queueDownload(node)
                        }
                    }
                    .tint(.blue)
                }
            }
    }

    @ViewBuilder
    private func nodeContextMenu(_ node: RemoteNode) -> some View {
        if !node.isFolder {
            Button("Queue Download") {
                Task {
                    await viewModel.queueDownload(node)
                }
            }
        }
        Button(viewModel.isPinned(node) ? "Remove Offline" : "Pin Offline") {
            Task {
                await viewModel.toggleOffline(node: node)
            }
        }
        Button("Rename") {
            viewModel.nodePendingRename = node
        }
        Button("Move") {
            viewModel.prepareRelocation(of: node, operation: .move)
        }
        Button("Copy") {
            viewModel.prepareRelocation(of: node, operation: .copy)
        }
        Button(node.isBookmarked ? "Remove Bookmark" : "Bookmark") {
            Task {
                await viewModel.toggleBookmark(node: node)
            }
        }
        Button(node.isShared ? "Share Public Link" : "Create Public Link") {
            Task {
                await viewModel.sharePublicLink(node: node)
            }
        }
        if node.isShared {
            Button("Remove Public Link", role: .destructive) {
                Task {
                    await viewModel.removePublicLink(node: node)
                }
            }
        }
        Button("Delete", role: .destructive) {
            viewModel.nodePendingDeletion = node
        }
    }

    @ToolbarContentBuilder
    private var browserToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                ForEach(NodeSortOrder.allCases, id: \.self) { order in
                    Button(order.label) {
                        viewModel.selectedSortOrder = order
                        Task {
                            await viewModel.load()
                        }
                    }
                }
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }

            Button {
                viewModel.isPresentingUploadPicker = true
            } label: {
                Label("Upload", systemImage: "square.and.arrow.up")
            }

            Button {
                viewModel.isPresentingCreateFolder = true
            } label: {
                Label("Create Folder", systemImage: "folder.badge.plus")
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

    private var deleteDialogIsPresented: Binding<Bool> {
        Binding(
            get: { viewModel.nodePendingDeletion != nil },
            set: { if !$0 { viewModel.nodePendingDeletion = nil } }
        )
    }

    @ViewBuilder
    private var deleteConfirmationActions: some View {
        if let node = viewModel.nodePendingDeletion {
            Button("Delete \(node.name)", role: .destructive) {
                Task {
                    await viewModel.delete(node: node)
                }
            }
        }
        Button("Cancel", role: .cancel) {
            viewModel.nodePendingDeletion = nil
        }
    }

    @ViewBuilder
    private func nodeDestination(_ node: RemoteNode) -> some View {
        if node.isFolder {
            NavigationLink {
                FolderBrowserView(
                    session: session,
                    services: services,
                    folderStateID: node.stateID,
                    title: node.name
                )
            } label: {
                NodeRowView(
                    node: node,
                    isPinnedOffline: viewModel.isPinned(node),
                    isAvailableOffline: viewModel.localFileURL(for: node) != nil
                )
            }
        } else {
            Button {
                viewModel.selectedFile = node
            } label: {
                NodeRowView(
                    node: node,
                    isPinnedOffline: viewModel.isPinned(node),
                    isAvailableOffline: viewModel.localFileURL(for: node) != nil
                )
            }
            .buttonStyle(.plain)
        }
    }
}

private struct NodeRowView: View {
    let node: RemoteNode
    let isPinnedOffline: Bool
    let isAvailableOffline: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: node.isFolder ? "folder.fill" : "doc.fill")
                .foregroundStyle(node.isFolder ? Color.accentColor : Color.secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(node.name)
                        .font(.body.weight(.medium))
                    if isPinnedOffline {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.teal)
                            .accessibilityLabel("Pinned offline")
                    }
                    if node.isBookmarked {
                        Image(systemName: "bookmark.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                            .accessibilityLabel("Bookmarked")
                    }
                    if node.isShared {
                        Image(systemName: "link.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.blue)
                            .accessibilityLabel("Public link available")
                    }
                    if isAvailableOffline {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                            .accessibilityLabel("Available locally")
                    }
                }
                HStack {
                    Text(node.isFolder ? "Folder" : formattedBytes(node.size))
                    if let mime = node.mimeType, !mime.isEmpty {
                        Text("| \(mime)")
                    }
                    Text("| \(formattedDate(node.modifiedAt))")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

private struct FolderNameSheet: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let confirmLabel: String
    let initialValue: String
    let onConfirm: (String) -> Void

    @State private var value = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $value)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(confirmLabel) {
                        onConfirm(value)
                        dismiss()
                    }
                    .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .onAppear {
            value = initialValue
        }
    }
}

private struct RemoteNodeDetailSheet: View {
    @Environment(\.dismiss) private var dismiss

    let node: RemoteNode
    @ObservedObject var queueService: TransferQueueService
    let accountID: String
    let isPinned: Bool
    let queueDownload: () async -> Void
    let requestMove: () -> Void
    let requestCopy: () -> Void
    let toggleBookmark: () async -> Void
    let sharePublicLink: () async -> Void
    let removePublicLink: () async -> Void
    let toggleOffline: () async -> Void

    @State private var previewURL: URL?
    @State private var shareURL: URL?

    private var cachedLocalURL: URL? {
        queueService.localFileURL(accountID: accountID, stateID: node.stateID.encodedID)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Metadata") {
                    MetadataRow(label: "Name", value: node.name)
                    MetadataRow(label: "Type", value: node.kind.rawValue.capitalized)
                    MetadataRow(label: "Size", value: formattedBytes(node.size))
                    MetadataRow(label: "Modified", value: formattedDate(node.modifiedAt))
                    MetadataRow(label: "Path", value: node.stateID.path ?? "/")
                }

                if !node.metadata.isEmpty {
                    Section("Raw Metadata") {
                        ForEach(node.metadata.keys.sorted(), id: \.self) { key in
                            MetadataRow(label: key, value: node.metadata[key]?.stringValue ?? "Unsupported")
                        }
                    }
                }

                Section("Actions") {
                    if !node.isFolder {
                        if let cachedLocalURL {
                            Button("Preview Downloaded File") {
                                previewURL = cachedLocalURL
                            }
                            Button("Share File") {
                                shareURL = cachedLocalURL
                            }
                        }

                        Button(cachedLocalURL == nil ? "Queue Download" : "Download Fresh Copy") {
                            Task {
                                await queueDownload()
                                if cachedLocalURL == nil {
                                    dismiss()
                                }
                            }
                        }
                    }

                    Button("Move") {
                        dismiss()
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 150_000_000)
                            requestMove()
                        }
                    }

                    Button("Copy") {
                        dismiss()
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 150_000_000)
                            requestCopy()
                        }
                    }

                    Button(node.isBookmarked ? "Remove Bookmark" : "Bookmark") {
                        Task {
                            await toggleBookmark()
                            dismiss()
                        }
                    }

                    Button(node.isShared ? "Share Public Link" : "Create Public Link") {
                        dismiss()
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 150_000_000)
                            await sharePublicLink()
                        }
                    }

                    if node.isShared {
                        Button("Remove Public Link", role: .destructive) {
                            Task {
                                await removePublicLink()
                                dismiss()
                            }
                        }
                    }

                    Button(isPinned ? "Remove Offline Pin" : "Pin for Offline") {
                        Task {
                            await toggleOffline()
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(node.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") {
                        dismiss()
                    }
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
    }
}

enum NodeRelocationOperation: String, Identifiable, Sendable {
    case move
    case copy

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .move:
            return "Move"
        case .copy:
            return "Copy"
        }
    }

    var destinationPrompt: String {
        switch self {
        case .move:
            return "Move Here"
        case .copy:
            return "Copy Here"
        }
    }
}

struct NodeRelocationRequest: Identifiable, Sendable {
    let id = UUID()
    let node: RemoteNode
    let operation: NodeRelocationOperation
}

struct PublicLinkShareItem: Identifiable, Sendable {
    let id = UUID()
    let title: String
    let link: String
}

private extension NodeSortOrder {
    var label: String {
        switch self {
        case .nameAscending:
            return "Name A-Z"
        case .nameDescending:
            return "Name Z-A"
        case .modifiedDescending:
            return "Newest First"
        case .modifiedAscending:
            return "Oldest First"
        }
    }
}

private extension String {
    var normalizedFolderPath: String {
        if self == "/" {
            return "/"
        }
        let trimmed = trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "/" + trimmed
    }
}
