import AuthenticationServices
import Foundation
import UIKit

@MainActor
private final class OAuthPresentationContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
        return window ?? ASPresentationAnchor()
    }
}

@MainActor
private final class OAuthWebAuthenticator {
    private let presentationProvider = OAuthPresentationContextProvider()
    private var activeSession: ASWebAuthenticationSession?

    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackScheme
            ) { callbackURL, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let callbackURL else {
                    continuation.resume(throwing: AppError.authentication("OAuth callback is missing."))
                    return
                }
                continuation.resume(returning: callbackURL)
            }
            session.prefersEphemeralWebBrowserSession = true
            session.presentationContextProvider = presentationProvider
            activeSession = session
            session.start()
        }
    }
}

@MainActor
final class AuthSessionService {
    private let apiClient: PydioAPIClient
    private let legacyP8Client: LegacyP8Client
    private let accountRepository: AccountRepository
    private let authenticator = OAuthWebAuthenticator()
    private let logger: Logger

    init(
        apiClient: PydioAPIClient,
        legacyP8Client: LegacyP8Client,
        accountRepository: AccountRepository,
        logger: Logger
    ) {
        self.apiClient = apiClient
        self.legacyP8Client = legacyP8Client
        self.accountRepository = accountRepository
        self.logger = logger
    }

    func authenticateCells(server: ServerDescriptor, settings: AppSettings) async throws -> AccountSession {
        guard server.type == .cells, let oauth = server.oauthConfiguration else {
            throw AppError.authentication("Cells OAuth is not available for this server.")
        }

        let state = randomState()
        var components = URLComponents(url: oauth.authorizeEndpoint, resolvingAgainstBaseURL: false)
        var queryItems = components?.queryItems ?? []
        queryItems.append(URLQueryItem(name: "state", value: state))
        queryItems.append(URLQueryItem(name: "scope", value: oauth.scope))
        queryItems.append(URLQueryItem(name: "client_id", value: settings.oauthClientID))
        queryItems.append(URLQueryItem(name: "response_type", value: "code"))
        queryItems.append(URLQueryItem(name: "redirect_uri", value: settings.oauthRedirectURI))
        if let audience = oauth.audience, !audience.isEmpty {
            queryItems.append(URLQueryItem(name: "audience_id", value: audience))
        }
        components?.queryItems = queryItems
        guard let authorizationURL = components?.url else {
            throw AppError.authentication("Could not build the OAuth authorization URL.")
        }

        let callbackURL = try await authenticator.authenticate(
            url: authorizationURL,
            callbackScheme: callbackScheme(from: settings.oauthRedirectURI)
        )
        let returnedItems = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let returnedState = returnedItems.first(where: { $0.name == "state" })?.value
        let code = returnedItems.first(where: { $0.name == "code" })?.value
        guard returnedState == state, let code, !code.isEmpty else {
            throw AppError.authentication("The OAuth callback state is invalid.")
        }

        let token = try await apiClient.exchangeAuthorizationCode(
            server: server,
            code: code,
            clientID: settings.oauthClientID,
            redirectURI: settings.oauthRedirectURI
        )

        let username = try decodeUsername(from: token)
        let accountID = StateID(username: username, serverURL: server.baseURL.absoluteString).accountID
        let now = Date()
        let session = AccountSession(
            accountID: accountID,
            username: username,
            serverID: server.id,
            serverURL: server.baseURL,
            authStatus: .connected,
            lifecycleState: .foreground,
            isReachable: true,
            isLegacy: false,
            skipTLSVerification: server.skipTLSVerification,
            serverLabel: server.label,
            welcomeMessage: server.welcomeMessage,
            customPrimaryColor: server.customPrimaryColor,
            createdAt: now,
            updatedAt: now
        )

        try await accountRepository.upsert(server: server)
        try await accountRepository.upsert(session: session)
        try await accountRepository.setActive(accountID: accountID)
        try await accountRepository.saveToken(token, for: accountID)
        logger.info("Authenticated \(accountID)")
        return session
    }

    func loginLegacy(
        server: ServerDescriptor,
        username: String,
        password: String
    ) async throws -> AccountSession {
        guard server.type == .legacyP8 else {
            throw AppError.authentication("Legacy credentials can only be used with a P8 server.")
        }

        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUsername.isEmpty, !password.isEmpty else {
            throw AppError.authentication("Legacy username and password are required.")
        }

        try await legacyP8Client.authenticate(
            server: server,
            username: trimmedUsername,
            password: password
        )

        let accountID = StateID(
            username: trimmedUsername,
            serverURL: server.baseURL.absoluteString
        ).accountID
        let now = Date()
        let session = AccountSession(
            accountID: accountID,
            username: trimmedUsername,
            serverID: server.id,
            serverURL: server.baseURL,
            authStatus: .connected,
            lifecycleState: .foreground,
            isReachable: true,
            isLegacy: true,
            skipTLSVerification: server.skipTLSVerification,
            serverLabel: server.label,
            welcomeMessage: server.welcomeMessage,
            customPrimaryColor: server.customPrimaryColor,
            createdAt: now,
            updatedAt: now
        )

        try await accountRepository.upsert(server: server)
        try await accountRepository.upsert(session: session)
        try await accountRepository.setActive(accountID: accountID)
        try await accountRepository.saveLegacyCredentials(
            LegacyP8Credentials(username: trimmedUsername, password: password),
            for: accountID
        )
        logger.info("Authenticated legacy account \(accountID)")
        return session
    }

    func logout(session: AccountSession) async throws {
        try await accountRepository.logout(accountID: session.accountID)
    }

    private func decodeUsername(from token: OAuthToken) throws -> String {
        guard
            let idToken = token.idToken,
            let claims = decodeJWTPayload(idToken),
            let username = resolvedUsername(from: claims),
            !username.isEmpty
        else {
            throw AppError.authentication("Could not extract the account name from the id token.")
        }
        return username
    }

    private func decodeJWTPayload(_ jwt: String) -> [String: Any]? {
        let segments = jwt.split(separator: ".")
        guard segments.count == 3 else { return nil }
        var base64 = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 {
            base64.append("=")
        }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func randomState() -> String {
        let characters = Array("abcdef1234567890")
        return String((0 ..< 13).compactMap { _ in characters.randomElement() })
    }

    private func callbackScheme(from redirectURI: String) -> String {
        URLComponents(string: redirectURI)?.scheme ?? "cellsauth"
    }

    private func resolvedUsername(from claims: [String: Any]) -> String? {
        let candidates = ["preferred_username", "name", "email", "sub"]
        for key in candidates {
            if let value = claims[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }
}
