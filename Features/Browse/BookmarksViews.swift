import SwiftUI

@MainActor
final class BookmarksViewModel: ObservableObject {
    @Published private(set) var bookmarks: [RemoteNode] = []
    @Published private(set) var loadState: LoadState<[RemoteNode]> = .idle
    @Published var bannerMessage: String?
    @Published var selectedFile: RemoteNode?
    @Published var publicLinkShareItem: PublicLinkShareItem?

    private let session: AccountSession
    private let nodeRepository: NodeRepository
    private let transferQueueService: TransferQueueService
    private let logger: Logger

    init(
        session: AccountSession,
        nodeRepository: NodeRepository,
        transferQueueService: TransferQueueService,
        logger: Logger
    ) {
        self.session = session
        self.nodeRepository = nodeRepository
        self.transferQueueService = transferQueueService
        self.logger = logger
    }

    func load() async {
        loadState = .loading
        bannerMessage = nil

        do {
            let nodes = try await nodeRepository.listBookmarkedNodes(for: session)
            bookmarks = nodes
            loadState = .loaded(nodes)
        } catch {
            bookmarks = []
            loadState = .failed(error.localizedDescription)
        }
    }

    func removeBookmark(from node: RemoteNode) async {
        do {
            try await nodeRepository.setBookmarked(node: node, enabled: false, session: session)
            await load()
            bannerMessage = "Removed bookmark from \(node.name)."
        } catch {
            bannerMessage = error.localizedDescription
            logger.warning("Could not remove bookmark for \(node.stateID.encodedID): \(error.localizedDescription)")
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

    func sharePublicLink(for node: RemoteNode) async {
        do {
            let address = try await nodeRepository.createOrFetchPublicLink(for: node, session: session)
            await load()
            publicLinkShareItem = PublicLinkShareItem(title: node.name, link: address)
            bannerMessage = node.isShared
                ? "Loaded the public link for \(node.name)."
                : "Created a public link for \(node.name)."
        } catch {
            bannerMessage = error.localizedDescription
        }
    }

    func removePublicLink(for node: RemoteNode) async {
        do {
            try await nodeRepository.removePublicLink(for: node, session: session)
            await load()
            bannerMessage = "Removed the public link for \(node.name)."
        } catch {
            bannerMessage = error.localizedDescription
        }
    }

    func localFileURL(for node: RemoteNode) -> URL? {
        transferQueueService.localFileURL(
            accountID: session.accountID,
            stateID: node.stateID.encodedID
        )
    }
}

struct BookmarksView: View {
    let session: AccountSession
    let services: AppServices

    @StateObject private var viewModel: BookmarksViewModel

    init(session: AccountSession, services: AppServices) {
        self.session = session
        self.services = services
        _viewModel = StateObject(
            wrappedValue: BookmarksViewModel(
                session: session,
                nodeRepository: services.nodeRepository,
                transferQueueService: services.transferQueueService,
                logger: services.logger
            )
        )
    }

    var body: some View {
        Group {
            switch viewModel.loadState {
            case .idle:
                LoadingCard(title: "Loading bookmarks...")
            case .loading where viewModel.bookmarks.isEmpty:
                LoadingCard(title: "Loading bookmarks...")
            case .failed(let message) where viewModel.bookmarks.isEmpty:
                EmptyStateCard(
                    title: "No Bookmarks Available",
                    message: message,
                    systemImage: "bookmark.slash"
                )
            default:
                List {
                    if let bannerMessage = viewModel.bannerMessage {
                        InlineMessageBanner(
                            title: "Bookmarks",
                            message: bannerMessage
                        )
                        .listRowBackground(Color.clear)
                    }

                    if viewModel.bookmarks.isEmpty {
                        EmptyStateCard(
                            title: "No Bookmarks Yet",
                            message: "Bookmarked nodes from the current account will appear here.",
                            systemImage: "bookmark"
                        )
                        .listRowBackground(Color.clear)
                    } else {
                        ForEach(viewModel.bookmarks) { node in
                            bookmarkDestination(node)
                                .contextMenu {
                                    if !node.isFolder {
                                        Button("File Details") {
                                            viewModel.selectedFile = node
                                        }
                                        Button("Queue Download") {
                                            Task {
                                                await viewModel.queueDownload(node)
                                            }
                                        }
                                    }
                                    Button(node.isShared ? "Share Public Link" : "Create Public Link") {
                                        Task {
                                            await viewModel.sharePublicLink(for: node)
                                        }
                                    }
                                    if node.isShared {
                                        Button("Remove Public Link", role: .destructive) {
                                            Task {
                                                await viewModel.removePublicLink(for: node)
                                            }
                                        }
                                    }
                                    Button("Remove Bookmark", role: .destructive) {
                                        Task {
                                            await viewModel.removeBookmark(from: node)
                                        }
                                    }
                                }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .refreshable {
                    await viewModel.load()
                }
            }
        }
        .navigationTitle("Bookmarks")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task {
                        await viewModel.load()
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
        .sheet(item: $viewModel.selectedFile) { node in
            BookmarkedFileDetailSheet(
                session: session,
                services: services,
                node: node,
                queueService: services.transferQueueService,
                accountID: session.accountID,
                queueDownload: {
                    await viewModel.queueDownload(node)
                },
                removeBookmark: {
                    await viewModel.removeBookmark(from: node)
                },
                sharePublicLink: {
                    await viewModel.sharePublicLink(for: node)
                },
                removePublicLink: {
                    await viewModel.removePublicLink(for: node)
                }
            )
        }
        .sheet(item: $viewModel.publicLinkShareItem) { item in
            ShareSheet(activityItems: [item.link])
        }
        .task {
            await viewModel.load()
        }
    }

    @ViewBuilder
    private func bookmarkDestination(_ node: RemoteNode) -> some View {
        if node.isFolder {
            NavigationLink {
                FolderBrowserView(
                    session: session,
                    services: services,
                    folderStateID: node.stateID,
                    title: node.name
                )
            } label: {
                BookmarkNodeRowView(
                    node: node,
                    isAvailableOffline: viewModel.localFileURL(for: node) != nil
                )
            }
        } else {
            Button {
                viewModel.selectedFile = node
            } label: {
                BookmarkNodeRowView(
                    node: node,
                    isAvailableOffline: viewModel.localFileURL(for: node) != nil
                )
            }
            .buttonStyle(.plain)
        }
    }
}

private struct BookmarkNodeRowView: View {
    let node: RemoteNode
    let isAvailableOffline: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: node.isFolder ? "folder.fill" : "bookmark.circle.fill")
                .foregroundStyle(node.isFolder ? Color.accentColor : Color.yellow)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(node.name)
                        .font(.body.weight(.medium))
                    if node.isShared {
                        Image(systemName: "link.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }
                    if isAvailableOffline {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
                Text(node.stateID.path ?? "/")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

private struct BookmarkedFileDetailSheet: View {
    @Environment(\.dismiss) private var dismiss

    let session: AccountSession
    let services: AppServices
    let node: RemoteNode
    @ObservedObject var queueService: TransferQueueService
    let accountID: String
    let queueDownload: () async -> Void
    let removeBookmark: () async -> Void
    let sharePublicLink: () async -> Void
    let removePublicLink: () async -> Void

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
                    MetadataRow(label: "Path", value: node.stateID.path ?? "/")
                    MetadataRow(label: "Size", value: formattedBytes(node.size))
                    MetadataRow(label: "Modified", value: formattedDate(node.modifiedAt))
                }

                Section("Actions") {
                    NavigationLink {
                        FolderBrowserView(
                            session: session,
                            services: services,
                            folderStateID: node.stateID.parent(),
                            title: node.stateID.parent().fileName ?? node.stateID.workspaceSlug ?? "Folder"
                        )
                    } label: {
                        Label("Open Containing Folder", systemImage: "folder")
                    }

                    if let cachedLocalURL {
                        Button("Preview Downloaded File") {
                            previewURL = cachedLocalURL
                        }
                        Button("Share Downloaded File") {
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

                    Button(node.isShared ? "Share Public Link" : "Create Public Link") {
                        Task {
                            await sharePublicLink()
                            dismiss()
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

                    Button("Remove Bookmark", role: .destructive) {
                        Task {
                            await removeBookmark()
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
