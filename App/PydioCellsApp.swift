import SwiftUI

@main
struct PydioCellsApp: App {
    @StateObject private var coordinator = AppCoordinator()

    var body: some Scene {
        WindowGroup {
            RootView(coordinator: coordinator)
                .task {
                    await coordinator.bootstrapIfNeeded()
                }
        }
    }
}

private struct RootView: View {
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        Group {
            switch coordinator.phase {
            case .launching:
                LaunchingView(settings: coordinator.settings)
            case .onboarding:
                NavigationStack {
                    OnboardingFlowView(coordinator: coordinator)
                }
            case .accounts:
                NavigationStack {
                    AccountsView(coordinator: coordinator)
                }
            case .authenticated(let session):
                MainShellView(coordinator: coordinator, session: session)
            }
        }
        .tint(themeColor)
        .alert(
            "Runtime Issue",
            isPresented: Binding(
                get: { coordinator.startupError != nil },
                set: { if !$0 { coordinator.dismissStartupError() } }
            )
        ) {
            Button("Close", role: .cancel) {
                coordinator.dismissStartupError()
            }
        } message: {
            Text(coordinator.startupError ?? "Unknown error")
        }
    }

    private var themeColor: Color {
        guard
            coordinator.settings.useDynamicServerColors,
            let color = coordinator.currentSession?.customPrimaryColor.flatMap(Color.init(hex:))
        else {
            return Color.accentColor
        }
        return color
    }
}

private struct LaunchingView: View {
    let settings: AppSettings

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.black.opacity(0.85), Color.blue.opacity(0.55)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 20) {
                BrandHeader(
                    title: settings.appDisplayName,
                    subtitle: "Reconstructed from the local Android app and transport stack"
                )
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
            }
            .padding(24)
        }
    }
}

private enum MainTab: Hashable {
    case browse
    case bookmarks
    case transfers
    case accounts
    case settings
}

private struct MainShellView: View {
    @ObservedObject var coordinator: AppCoordinator
    let session: AccountSession

    @State private var selection: MainTab = .browse

    var body: some View {
        TabView(selection: $selection) {
            NavigationStack {
                BrowseHomeView(session: session, services: coordinator.services)
            }
            .tabItem {
                Label("Files", systemImage: "folder")
            }
            .tag(MainTab.browse)

            NavigationStack {
                BookmarksView(session: session, services: coordinator.services)
            }
            .tabItem {
                Label("Bookmarks", systemImage: "bookmark")
            }
            .tag(MainTab.bookmarks)

            NavigationStack {
                TransfersView(queueService: coordinator.services.transferQueueService)
            }
            .tabItem {
                Label("Transfers", systemImage: "arrow.up.arrow.down.circle")
            }
            .tag(MainTab.transfers)

            NavigationStack {
                AccountsView(coordinator: coordinator, embeddedInAuthenticatedShell: true)
            }
            .tabItem {
                Label("Accounts", systemImage: "person.crop.circle")
            }
            .tag(MainTab.accounts)

            NavigationStack {
                SettingsView(coordinator: coordinator)
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape")
            }
            .tag(MainTab.settings)
        }
    }
}
