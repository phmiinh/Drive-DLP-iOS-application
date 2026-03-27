import SwiftUI

@MainActor
final class OnboardingViewModel: ObservableObject {
    @Published var serverAddress = ""
    @Published var skipTLSVerification = false
    @Published private(set) var inspectionState: LoadState<ServerDescriptor> = .idle
    @Published private(set) var discoveredServer: ServerDescriptor?
    @Published var username = ""
    @Published var password = ""
    @Published var errorMessage: String?
    @Published private(set) var isAuthenticating = false

    private let services: AppServices
    private let settings: AppSettings

    init(services: AppServices, settings: AppSettings) {
        self.services = services
        self.settings = settings
    }

    func inspectServer() async {
        let trimmed = serverAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Enter the server URL before inspecting it."
            return
        }

        inspectionState = .loading
        discoveredServer = nil
        errorMessage = nil

        do {
            let descriptor = try await services.apiClient.inspectServer(
                address: trimmed,
                skipTLSVerification: skipTLSVerification
            )
            discoveredServer = descriptor
            inspectionState = .loaded(descriptor)
        } catch {
            inspectionState = .failed(error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    func authenticate() async -> AccountSession? {
        guard let discoveredServer else {
            errorMessage = "Inspect a server before trying to sign in."
            return nil
        }

        isAuthenticating = true
        errorMessage = nil
        defer { isAuthenticating = false }

        do {
            if discoveredServer.type == .cells {
                return try await services.authSessionService.authenticateCells(
                    server: discoveredServer,
                    settings: settings
                )
            }

            guard !username.isEmpty, !password.isEmpty else {
                errorMessage = "Legacy servers still require a username and password."
                return nil
            }

            return try await services.authSessionService.loginLegacy(
                server: discoveredServer,
                username: username,
                password: password
            )
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func resetInspection() {
        inspectionState = .idle
        discoveredServer = nil
        errorMessage = nil
        username = ""
        password = ""
    }
}

struct OnboardingFlowView: View {
    @ObservedObject var coordinator: AppCoordinator
    let dismissAction: (() -> Void)?

    @StateObject private var viewModel: OnboardingViewModel

    init(coordinator: AppCoordinator, dismissAction: (() -> Void)? = nil) {
        self.coordinator = coordinator
        self.dismissAction = dismissAction
        _viewModel = StateObject(
            wrappedValue: OnboardingViewModel(
                services: coordinator.services,
                settings: coordinator.settings
            )
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                BrandHeader(
                    title: coordinator.settings.appDisplayName,
                    subtitle: "Server bootstrap and sign-in reconstructed from the local Android implementation"
                )

                SectionCard(
                    title: "Server Connection",
                    subtitle: "Equivalent to Android pre-launch inspection and server factory detection"
                ) {
                    TextField("https://cloud.example.com", text: $viewModel.serverAddress)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .padding(12)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    Toggle("Skip TLS validation for this server", isOn: $viewModel.skipTLSVerification)
                        .font(.subheadline)

                    Button {
                        Task {
                            await viewModel.inspectServer()
                        }
                    } label: {
                        Label("Inspect Server", systemImage: "network")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.serverAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if let errorMessage = viewModel.errorMessage {
                    InlineMessageBanner(
                        title: "Action Failed",
                        message: errorMessage,
                        tint: .red
                    )
                }

                switch viewModel.inspectionState {
                case .idle:
                    SectionCard(
                        title: "Next Step",
                        subtitle: "Point this app to a Cells or legacy Pydio server."
                    ) {
                        Text("The iOS bootstrap layer checks the URL, identifies the server family, then opens the matching authentication flow.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                case .loading:
                    LoadingCard(title: "Inspecting server capabilities...")
                        .frame(height: 180)
                case .failed:
                    EmptyStateCard(
                        title: "Server Inspection Failed",
                        message: "Check the address, connectivity, and TLS settings, then retry.",
                        systemImage: "wifi.exclamationmark"
                    )
                    .frame(height: 220)
                case .loaded(let server):
                    serverSection(server)
                }
            }
            .padding(20)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Connect")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let dismissAction {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") {
                        dismissAction()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func serverSection(_ server: ServerDescriptor) -> some View {
        SectionCard(
            title: server.label,
            subtitle: server.hostDisplayName
        ) {
            MetadataRow(label: "Server Type", value: server.type == .cells ? "Pydio Cells" : "Legacy P8")
            MetadataRow(label: "Version", value: server.version ?? "Unknown")
            if let welcomeMessage = server.welcomeMessage, !welcomeMessage.isEmpty {
                Text(welcomeMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Divider()

            if server.type == .cells {
                Text("Cells uses the same OAuth client id and callback scheme found in the local Android app.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Button {
                    Task {
                        if let session = await viewModel.authenticate() {
                            await coordinator.completeAuthentication(session)
                            dismissAction?()
                        }
                    }
                } label: {
                    Label("Continue with Browser Sign-In", systemImage: "lock.open.display")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isAuthenticating)
            } else {
                TextField("Username", text: $viewModel.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(12)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                SecureField("Password", text: $viewModel.password)
                    .padding(12)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                Button {
                    Task {
                        if let session = await viewModel.authenticate() {
                            await coordinator.completeAuthentication(session)
                            dismissAction?()
                        }
                    }
                } label: {
                    Label("Sign In", systemImage: "person.badge.key")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isAuthenticating)
            }

            Button("Inspect Another Server") {
                viewModel.resetInspection()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

