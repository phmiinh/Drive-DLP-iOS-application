import SwiftUI

@MainActor
final class RemoteFolderPickerViewModel: ObservableObject {
    @Published private(set) var folders: [RemoteNode] = []
    @Published private(set) var loadState: LoadState<[RemoteNode]> = .idle

    private let session: AccountSession
    private let folderStateID: StateID
    private let request: NodeRelocationRequest
    private let nodeRepository: NodeRepository
    private let logger: Logger

    init(
        session: AccountSession,
        folderStateID: StateID,
        request: NodeRelocationRequest,
        nodeRepository: NodeRepository,
        logger: Logger
    ) {
        self.session = session
        self.folderStateID = folderStateID
        self.request = request
        self.nodeRepository = nodeRepository
        self.logger = logger
    }

    func load() async {
        loadState = .loading

        do {
            let children = try await nodeRepository.loadChildren(
                of: folderStateID,
                session: session,
                sortOrder: .nameAscending
            )
            let remoteFolders = children.filter { node in
                node.isFolder && node.stateID.encodedID != request.node.stateID.encodedID
            }
            folders = remoteFolders
            loadState = .loaded(remoteFolders)
        } catch {
            logger.warning("Could not load relocation targets for \(folderStateID.encodedID): \(error.localizedDescription)")
            folders = []
            loadState = .failed(error.localizedDescription)
        }
    }
}

struct RemoteFolderPickerSheet: View {
    let session: AccountSession
    let services: AppServices
    let request: NodeRelocationRequest
    let onSelect: (StateID) -> Void

    private var workspaceRootStateID: StateID {
        StateID(
            username: session.username,
            serverURL: session.serverURL.absoluteString,
            path: "/\(request.node.stateID.workspaceSlug ?? "")"
        )
    }

    var body: some View {
        NavigationStack {
            RemoteFolderPickerView(
                session: session,
                services: services,
                folderStateID: workspaceRootStateID,
                request: request,
                isRoot: true,
                onSelect: onSelect
            )
        }
    }
}

private struct RemoteFolderPickerView: View {
    @Environment(\.dismiss) private var dismiss

    let session: AccountSession
    let services: AppServices
    let folderStateID: StateID
    let request: NodeRelocationRequest
    let isRoot: Bool
    let onSelect: (StateID) -> Void

    @StateObject private var viewModel: RemoteFolderPickerViewModel

    init(
        session: AccountSession,
        services: AppServices,
        folderStateID: StateID,
        request: NodeRelocationRequest,
        isRoot: Bool,
        onSelect: @escaping (StateID) -> Void
    ) {
        self.session = session
        self.services = services
        self.folderStateID = folderStateID
        self.request = request
        self.isRoot = isRoot
        self.onSelect = onSelect
        _viewModel = StateObject(
            wrappedValue: RemoteFolderPickerViewModel(
                session: session,
                folderStateID: folderStateID,
                request: request,
                nodeRepository: services.nodeRepository,
                logger: services.logger
            )
        )
    }

    var body: some View {
        List {
            Section("Destination") {
                Button {
                    onSelect(folderStateID)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(
                            request.operation.destinationPrompt,
                            systemImage: request.operation == .move ? "arrow.right.circle.fill" : "plus.square.on.square"
                        )
                        .font(.body.weight(.semibold))
                        Text(folderStateID.path ?? "/")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            switch viewModel.loadState {
            case .idle, .loading:
                Section("Folders") {
                    HStack {
                        ProgressView()
                        Text("Loading available folders...")
                            .foregroundStyle(.secondary)
                    }
                }
            case .failed(let message):
                Section("Folders") {
                    InlineMessageBanner(
                        title: "Folder List Unavailable",
                        message: message
                    )
                }
            case .loaded:
                Section("Subfolders") {
                    if viewModel.folders.isEmpty {
                        Text("This location has no visible subfolders.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.folders) { folder in
                            NavigationLink {
                                RemoteFolderPickerView(
                                    session: session,
                                    services: services,
                                    folderStateID: folder.stateID,
                                    request: request,
                                    isRoot: false,
                                    onSelect: onSelect
                                )
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "folder.fill")
                                        .foregroundStyle(.accentColor)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(folder.name)
                                            .font(.body.weight(.medium))
                                        Text(folder.stateID.path ?? "/")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if isRoot {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
        .task {
            await viewModel.load()
        }
    }

    private var navigationTitle: String {
        if isRoot {
            return "\(request.operation.title) \(request.node.name)"
        }
        return folderStateID.fileName ?? folderStateID.workspaceSlug ?? "Folder"
    }
}
