import SwiftUI

@MainActor
final class BrowseRootViewModel: ObservableObject {
    @Published private(set) var workspaces: [Workspace] = []
    @Published private(set) var loadState: LoadState<[Workspace]> = .idle
    @Published var errorMessage: String?

    let session: AccountSession

    private let nodeRepository: NodeRepository

    init(session: AccountSession, nodeRepository: NodeRepository) {
        self.session = session
        self.nodeRepository = nodeRepository
    }

    func load() async {
        loadState = .loading
        errorMessage = nil

        do {
            let workspaces = try await nodeRepository.loadWorkspaces(for: session)
            self.workspaces = workspaces
            loadState = .loaded(workspaces)
        } catch {
            self.workspaces = []
            loadState = .failed(error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }
}

struct BrowseHomeView: View {
    let session: AccountSession
    let services: AppServices

    @StateObject private var viewModel: BrowseRootViewModel

    init(session: AccountSession, services: AppServices) {
        self.session = session
        self.services = services
        _viewModel = StateObject(
            wrappedValue: BrowseRootViewModel(
                session: session,
                nodeRepository: services.nodeRepository
            )
        )
    }

    var body: some View {
        Group {
            switch viewModel.loadState {
            case .idle:
                LoadingCard(title: "Loading workspaces...")
            case .loading where viewModel.workspaces.isEmpty:
                LoadingCard(title: "Loading workspaces...")
            case .failed(let message) where viewModel.workspaces.isEmpty:
                EmptyStateCard(
                    title: "Cannot Load Workspaces",
                    message: message,
                    systemImage: "externaldrive.badge.questionmark"
                )
            default:
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        SectionCard(
                            title: session.serverLabel,
                            subtitle: session.serverURL.host ?? session.serverURL.absoluteString
                        ) {
                            MetadataRow(label: "Account", value: session.username)
                            MetadataRow(label: "Reachability", value: session.isReachable ? "Reachable" : "Offline")
                            if let welcomeMessage = session.welcomeMessage, !welcomeMessage.isEmpty {
                                Text(welcomeMessage)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if let errorMessage = viewModel.errorMessage {
                            InlineMessageBanner(
                                title: "Workspace Refresh Failed",
                                message: errorMessage,
                                tint: .orange
                            )
                        }

                        SectionCard(
                            title: "Workspaces",
                            subtitle: "Equivalent to the Android root browser entry"
                        ) {
                            ForEach(viewModel.workspaces) { workspace in
                                NavigationLink {
                                    FolderBrowserView(
                                        session: session,
                                        services: services,
                                        folderStateID: workspaceStateID(workspace),
                                        title: workspace.label
                                    )
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(workspace.label)
                                            .font(.headline)
                                        Text(workspace.rootPath)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 4)
                                }
                                if workspace.id != viewModel.workspaces.last?.id {
                                    Divider()
                                }
                            }
                        }
                    }
                    .padding(20)
                }
                .background(Color(.systemGroupedBackground))
            }
        }
        .navigationTitle("Files")
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
        .task {
            await viewModel.load()
        }
    }

    private func workspaceStateID(_ workspace: Workspace) -> StateID {
        StateID(
            username: session.username,
            serverURL: session.serverURL.absoluteString,
            path: workspace.rootPath
        )
    }
}

