import Foundation

@MainActor
final class AppCoordinator: ObservableObject {
    @Published private(set) var phase: AppPhase = .launching
    @Published var settings = AppSettings()
    @Published var startupError: String?

    let services: AppServices

    private var didBootstrap = false

    init(services: AppServices = AppServices()) {
        self.services = services
    }

    var currentSession: AccountSession? {
        guard case .authenticated(let session) = phase else {
            return nil
        }
        return session
    }

    func bootstrapIfNeeded() async {
        guard !didBootstrap else {
            return
        }
        didBootstrap = true

        await reloadSettings()
        await services.transferQueueService.reload()
        phase = await services.bootstrapService.initialPhase()
    }

    func reloadSettings() async {
        do {
            settings = try await services.bootstrapService.settings()
        } catch {
            startupError = error.localizedDescription
        }
    }

    func persistSettings(_ newValue: AppSettings) async {
        do {
            try await services.database.settings.save(newValue)
            settings = newValue
        } catch {
            startupError = error.localizedDescription
        }
    }

    func completeAuthentication(_ session: AccountSession) async {
        do {
            try await services.accountRepository.setActive(accountID: session.accountID)
            phase = .authenticated(session)
            await services.transferQueueService.reload()
        } catch {
            startupError = error.localizedDescription
            phase = .accounts
        }
    }

    func activate(_ session: AccountSession) async {
        do {
            try await services.accountRepository.setActive(accountID: session.accountID)
            await services.transferQueueService.reload()
            phase = await services.bootstrapService.initialPhase()
        } catch {
            startupError = error.localizedDescription
        }
    }

    func showAccounts() {
        phase = .accounts
    }

    func showOnboarding() {
        phase = .onboarding
    }

    func logout(_ session: AccountSession) async {
        do {
            try await services.authSessionService.logout(session: session)
        } catch {
            startupError = error.localizedDescription
        }
        await reconcilePhase()
    }

    func delete(_ session: AccountSession) async {
        do {
            try await services.accountRepository.delete(accountID: session.accountID)
        } catch {
            startupError = error.localizedDescription
        }
        await reconcilePhase()
    }

    func dismissStartupError() {
        startupError = nil
    }

    private func reconcilePhase() async {
        phase = await services.bootstrapService.initialPhase()
    }
}
