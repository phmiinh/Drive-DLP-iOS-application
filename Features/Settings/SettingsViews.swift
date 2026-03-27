import SwiftUI

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var draft: AppSettings
    @Published var statusMessage: String?

    private let services: AppServices

    init(initialSettings: AppSettings, services: AppServices) {
        self.draft = initialSettings
        self.services = services
    }

    func clearCache() async {
        do {
            try await services.nodeRepository.clearCache()
            statusMessage = "Cleared cached folder listings."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func clearCompletedTransfers() async {
        await services.transferQueueService.clearCompleted()
        statusMessage = "Removed finished queue entries and retained downloaded files as local cache."
    }

    func clearDownloadedFiles() async {
        await services.transferQueueService.purgeDownloadedFiles()
        statusMessage = "Removed locally downloaded files and cleared their cached transfer entries."
    }
}

struct SettingsView: View {
    @ObservedObject var coordinator: AppCoordinator

    @StateObject private var viewModel: SettingsViewModel

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        _viewModel = StateObject(
            wrappedValue: SettingsViewModel(
                initialSettings: coordinator.settings,
                services: coordinator.services
            )
        )
    }

    var body: some View {
        Form {
            if let statusMessage = viewModel.statusMessage {
                Section {
                    InlineMessageBanner(
                        title: "Settings Status",
                        message: statusMessage,
                        tint: .green
                    )
                }
            }

            Section("General") {
                TextField("App Name", text: $viewModel.draft.appDisplayName)
                Toggle("Use dynamic server colors", isOn: $viewModel.draft.useDynamicServerColors)
            }

            Section("Network Policy") {
                Toggle("Apply metered network limits", isOn: $viewModel.draft.applyMeteredNetworkLimits)
                Toggle("Download thumbnails on metered networks", isOn: $viewModel.draft.downloadThumbnailsOnMetered)
            }

            Section("OAuth") {
                TextField("Client ID", text: $viewModel.draft.oauthClientID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Redirect URI", text: $viewModel.draft.oauthRedirectURI)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Section("Maintenance") {
                Button("Save Settings") {
                    Task {
                        await coordinator.persistSettings(viewModel.draft)
                        viewModel.statusMessage = "Saved local app settings."
                    }
                }

                Button("Clear Cached Browsing Data") {
                    Task {
                        await viewModel.clearCache()
                    }
                }

                Button("Clear Finished Transfers") {
                    Task {
                        await viewModel.clearCompletedTransfers()
                    }
                }

                Button("Clear Download Cache") {
                    Task {
                        await viewModel.clearDownloadedFiles()
                    }
                }
            }

            Section("System") {
                if let session = coordinator.currentSession {
                    NavigationLink {
                        OfflineRootsView(session: session, services: coordinator.services)
                    } label: {
                        Label("Offline Roots", systemImage: "arrow.down.circle")
                    }
                }

                NavigationLink {
                    JobsView(services: coordinator.services)
                } label: {
                    Label("Jobs", systemImage: "tray.full")
                }

                NavigationLink {
                    LogsView(services: coordinator.services)
                } label: {
                    Label("Logs", systemImage: "doc.text")
                }
            }

            Section("About") {
                if let websiteURL = viewModel.draft.websiteURL {
                    Link(destination: websiteURL) {
                        Label("Bitcare Website", systemImage: "globe")
                    }
                }
                MetadataRow(label: "Bundle", value: "com.bitcare.bithub.ios")
                MetadataRow(label: "OAuth Scheme", value: "cellsauth://callback")
                MetadataRow(label: "Evidence", value: "Local Android app + local Java SDK")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}

