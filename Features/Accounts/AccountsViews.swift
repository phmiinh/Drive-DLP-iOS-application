import SwiftUI

@MainActor
final class AccountsViewModel: ObservableObject {
    @Published private(set) var sessions: [AccountSession] = []
    @Published private(set) var serversByID: [String: ServerDescriptor] = [:]
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let accountRepository: AccountRepository

    init(accountRepository: AccountRepository) {
        self.accountRepository = accountRepository
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let sessions = try await accountRepository.sessions()
            let servers = try await accountRepository.servers()

            self.sessions = sessions.sorted { lhs, rhs in
                if lhs.lifecycleState != rhs.lifecycleState {
                    return lhs.lifecycleState == .foreground
                }
                return lhs.updatedAt > rhs.updatedAt
            }
            self.serversByID = Dictionary(uniqueKeysWithValues: servers.map { ($0.id, $0) })
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func server(for session: AccountSession) -> ServerDescriptor? {
        serversByID[session.serverID]
    }
}

struct AccountsView: View {
    @ObservedObject var coordinator: AppCoordinator
    let embeddedInAuthenticatedShell: Bool

    @StateObject private var viewModel: AccountsViewModel
    @State private var isPresentingAddAccount = false

    init(coordinator: AppCoordinator, embeddedInAuthenticatedShell: Bool = false) {
        self.coordinator = coordinator
        self.embeddedInAuthenticatedShell = embeddedInAuthenticatedShell
        _viewModel = StateObject(
            wrappedValue: AccountsViewModel(accountRepository: coordinator.services.accountRepository)
        )
    }

    var body: some View {
        Group {
            if viewModel.isLoading && viewModel.sessions.isEmpty {
                LoadingCard(title: "Loading accounts...")
            } else if viewModel.sessions.isEmpty {
                VStack(spacing: 20) {
                    EmptyStateCard(
                        title: "No Accounts",
                        message: "Add a server to create the first persisted session.",
                        systemImage: "person.crop.circle.badge.plus"
                    )
                    Button("Add Server") {
                        isPresentingAddAccount = true
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            } else {
                List {
                    if let errorMessage = viewModel.errorMessage {
                        InlineMessageBanner(
                            title: "Account Error",
                            message: errorMessage,
                            tint: .red
                        )
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowBackground(Color.clear)
                    }

                    Section("Stored Sessions") {
                        ForEach(viewModel.sessions) { session in
                            Button {
                                Task {
                                    await coordinator.activate(session)
                                    await viewModel.load()
                                }
                            } label: {
                                AccountSessionRow(
                                    session: session,
                                    server: viewModel.server(for: session)
                                )
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Open") {
                                    Task {
                                        await coordinator.activate(session)
                                        await viewModel.load()
                                    }
                                }
                                Button("Sign Out", role: .destructive) {
                                    Task {
                                        await coordinator.logout(session)
                                        await viewModel.load()
                                    }
                                }
                                Button("Forget Account", role: .destructive) {
                                    Task {
                                        await coordinator.delete(session)
                                        await viewModel.load()
                                    }
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button("Forget", role: .destructive) {
                                    Task {
                                        await coordinator.delete(session)
                                        await viewModel.load()
                                    }
                                }
                                Button("Logout") {
                                    Task {
                                        await coordinator.logout(session)
                                        await viewModel.load()
                                    }
                                }
                                .tint(.orange)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle(embeddedInAuthenticatedShell ? "Accounts" : "Sessions")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isPresentingAddAccount = true
                } label: {
                    Label("Add Server", systemImage: "plus")
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    Task {
                        await viewModel.load()
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
        .sheet(isPresented: $isPresentingAddAccount) {
            NavigationStack {
                OnboardingFlowView(coordinator: coordinator) {
                    isPresentingAddAccount = false
                }
            }
        }
        .task {
            await viewModel.load()
        }
    }
}

private struct AccountSessionRow: View {
    let session: AccountSession
    let server: ServerDescriptor?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ServerBadgeView(server: server, session: session)
            HStack {
                Label(session.username, systemImage: "person")
                Spacer()
                Text(session.authStatus.rawValue.capitalized)
                    .foregroundStyle(session.authStatus == .connected ? .green : .orange)
            }
            .font(.subheadline)

            HStack {
                Text(session.lifecycleState == .foreground ? "Active" : "Stored")
                Spacer()
                Text(formattedDate(session.updatedAt))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }
}

