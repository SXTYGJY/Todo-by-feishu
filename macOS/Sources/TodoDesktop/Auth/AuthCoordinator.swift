import AppKit
import CryptoKit
import Foundation
import Security

@MainActor
final class AuthCoordinator {
    private let configuration: FeishuOAuthConfiguration
    private let tokenStore: KeychainTokenStore
    private let appCredentialsStore: KeychainAppCredentialsStore
    private let workspaceRepository: WorkspaceRepository
    private let identityDefaultsKey = "TodoDesktop.auth.identity"
    private let displayNameDefaultsKey = "TodoDesktop.auth.displayName"
    private var authorizationTask: Task<Void, Never>?

    var onAuthorizationStarted: (() -> Void)?
    var onAuthorizationCompleted: ((FeishuIdentity, String?) -> Void)?
    var onAuthorizationFailed: ((String) -> Void)?

    init(configuration: FeishuOAuthConfiguration = .standard,
         tokenStore: KeychainTokenStore = KeychainTokenStore(),
         appCredentialsStore: KeychainAppCredentialsStore = KeychainAppCredentialsStore(),
         workspaceRepository: WorkspaceRepository = WorkspaceRepository()) {
        self.configuration = configuration
        self.tokenStore = tokenStore
        self.appCredentialsStore = appCredentialsStore
        self.workspaceRepository = workspaceRepository
    }

    func loadAppCredentials() throws -> FeishuAppCredentials? {
        try appCredentialsStore.load()
    }

    @discardableResult
    func saveAppCredentials(_ credentials: FeishuAppCredentials) throws -> Bool {
        let changed = try appCredentialsStore.load() != credentials
        try appCredentialsStore.save(credentials)
        if changed { signOut() }
        return changed
    }

    var currentIdentity: FeishuIdentity? {
        guard let data = UserDefaults.standard.data(forKey: identityDefaultsKey) else { return nil }
        return try? JSONDecoder().decode(FeishuIdentity.self, from: data)
    }

    var currentDisplayName: String? {
        UserDefaults.standard.string(forKey: displayNameDefaultsKey)
    }

    var isAuthenticated: Bool { currentIdentity != nil }
    var isAuthorizationInProgress: Bool { authorizationTask != nil }

    func startAuthorization() {
        guard authorizationTask == nil else { return }
        onAuthorizationStarted?()
        authorizationTask = Task { [weak self] in
            guard let self else { return }
            defer { authorizationTask = nil }
            do {
                let result = try await authorize()
                onAuthorizationCompleted?(result.identity, result.displayName)
            } catch is CancellationError {
                onAuthorizationFailed?("已取消飞书授权。")
            } catch {
                onAuthorizationFailed?(error.localizedDescription)
            }
        }
    }

    func cancelAuthorization() {
        authorizationTask?.cancel()
        authorizationTask = nil
    }

    func signOut() {
        if let identity = currentIdentity {
            try? tokenStore.delete(for: identity.storageKey)
        }
        UserDefaults.standard.removeObject(forKey: identityDefaultsKey)
        UserDefaults.standard.removeObject(forKey: displayNameDefaultsKey)
    }

    func validAccessToken() async throws -> String {
        guard let identity = currentIdentity,
              var tokens = try tokenStore.load(for: identity.storageKey) else {
            throw OAuthError.identityLookupFailed("尚未连接飞书账号。")
        }
        if tokens.expiresAt.timeIntervalSinceNow > 120 { return tokens.accessToken }
        guard let credentials = try appCredentialsStore.load() else {
            throw OAuthError.invalidAppCredentials("请先配置飞书自建应用凭证。")
        }
        let raw = try await FeishuTokenClient(appID: credentials.appID,
                                              appSecret: credentials.appSecret).refresh(tokens.refreshToken)
        tokens.accessToken = raw.accessToken
        tokens.refreshToken = raw.refreshToken
        tokens.expiresAt = Date().addingTimeInterval(raw.expiresIn)
        try tokenStore.save(tokens)
        return tokens.accessToken
    }

    private func authorize() async throws -> (identity: FeishuIdentity, displayName: String?) {
        guard let credentials = try appCredentialsStore.load() else {
            throw OAuthError.invalidAppCredentials("请先配置飞书自建应用凭证。")
        }
        let state = Self.randomURLSafeString(byteCount: 32)
        let verifier = Self.randomURLSafeString(byteCount: 48)
        let challenge = Self.codeChallenge(for: verifier)
        let callbackServer = LoopbackOAuthCallbackServer(host: configuration.callbackHost,
                                                          port: configuration.callbackPort,
                                                          path: configuration.callbackPath)
        try await callbackServer.start()
        try await callbackServer.arm(expectedState: state)
        let url = try configuration.authorizationURL(appID: credentials.appID,
                                                     state: state,
                                                     codeChallenge: challenge)
        guard NSWorkspace.shared.open(url) else {
            callbackServer.cancel()
            throw OAuthError.invalidAuthorizationURL
        }
        let callback = try await callbackServer.waitForCallback()
        guard callback.state == state else { throw OAuthError.stateMismatch }
        let tokenClient = FeishuTokenClient(appID: credentials.appID, appSecret: credentials.appSecret)
        let raw = try await tokenClient.exchange(
            code: callback.code,
            redirectURI: configuration.redirectURI,
            codeVerifier: verifier
        )
        let profile = try await tokenClient.userInfo(accessToken: raw.accessToken)
        let identity = FeishuIdentity(userID: profile.openID, tenantID: profile.tenantKey)
        let tokenSet = FeishuTokenSet(accessToken: raw.accessToken,
                                      refreshToken: raw.refreshToken,
                                      expiresAt: Date().addingTimeInterval(raw.expiresIn),
                                      identity: identity,
                                      displayName: profile.name)
        try tokenStore.save(tokenSet)
        let identityData = try JSONEncoder().encode(identity)
        UserDefaults.standard.set(identityData, forKey: identityDefaultsKey)
        UserDefaults.standard.set(profile.name, forKey: displayNameDefaultsKey)
        _ = try workspaceRepository.load(for: identity)
        return (identity, profile.name)
    }

    private static func randomURLSafeString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

