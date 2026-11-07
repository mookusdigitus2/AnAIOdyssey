// SPDX-License-Identifier: MIT
import Foundation
import AIModelOptions
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif
#if canImport(Security)
import Security
#endif

public enum ChatGPTAccountError: Error, LocalizedError, Equatable {
    case iOSNotSupported
    case cancelled
    case missingCallback
    case missingRefreshToken
    case keychainFailed
    case jwksVerificationFailed
    case notSignedIn
    case ineligible
    case stateMismatch
    /// The refresh token is unusable (expired, revoked, or reused). Sign in again.
    case signInRequired
    /// The issued client id was rejected; signing in again with it will not help.
    case invalidClient
    /// Refresh failed for a network or server reason; credentials were kept.
    case refreshFailed(String)

    public var errorDescription: String? {
        switch self {
        case .iOSNotSupported:
            ChatGPTOAuthCodec.iOSUnsupportedMessage
        case .cancelled:
            "ChatGPT sign-in was cancelled."
        case .missingCallback:
            "ChatGPT did not return to the app."
        case .missingRefreshToken:
            "ChatGPT did not return a refresh token. Sign in again."
        case .keychainFailed:
            "Could not store ChatGPT tokens in the Keychain."
        case .jwksVerificationFailed:
            "Could not verify the ChatGPT ID token signature."
        case .notSignedIn:
            "Sign in with ChatGPT to use this connection."
        case .ineligible:
            ChatGPTOAuthCodec.ineligibleUserMessage
        case .stateMismatch:
            "ChatGPT sign-in state did not match. Try again."
        case .signInRequired:
            "Your ChatGPT sign-in expired. Choose Continue with ChatGPT in Settings → AI Models to sign in again."
        case .invalidClient:
            "ChatGPT no longer recognizes this app registration. Sign out of ChatGPT in Settings and sign in again."
        case .refreshFailed(let detail):
            "Couldn’t refresh your ChatGPT sign-in (\(detail)). Your sign-in is kept; try again shortly."
        }
    }
}

/// Keychain-backed Sign in with ChatGPT session for one remote connection.
public struct ChatGPTStoredCredentials: Codable, Equatable, Sendable {
    public var email: String?
    public var issuer: String
    public var subject: String
    public var clientID: String
    public var extAgentHostID: String
    public var idToken: String
    public var accessToken: String
    public var refreshToken: String?
    public var tokenType: String
    public var expiresAt: Date
    public var scopes: [String]
    public var savedAt: Date

    public init(
        email: String?,
        issuer: String,
        subject: String,
        clientID: String,
        extAgentHostID: String,
        idToken: String,
        accessToken: String,
        refreshToken: String?,
        tokenType: String,
        expiresAt: Date,
        scopes: [String],
        savedAt: Date
    ) {
        self.email = email
        self.issuer = issuer
        self.subject = subject
        self.clientID = clientID
        self.extAgentHostID = extAgentHostID
        self.idToken = idToken
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.tokenType = tokenType
        self.expiresAt = expiresAt
        self.scopes = scopes
        self.savedAt = savedAt
    }

    public var isPlanEligible: Bool {
        ChatGPTOAuthCodec.isPlanEligible(grantedScopes: scopes)
    }

    /// Provider-neutral token view shared with other subscription sign-ins.
    public var tokens: OAuthTokenSet {
        get {
            OAuthTokenSet(
                accessToken: accessToken,
                refreshToken: refreshToken,
                idToken: idToken,
                tokenType: tokenType,
                expiresAt: expiresAt,
                scopes: scopes,
                savedAt: savedAt
            )
        }
        set {
            accessToken = newValue.accessToken
            refreshToken = newValue.refreshToken
            idToken = newValue.idToken ?? idToken
            tokenType = newValue.tokenType
            expiresAt = newValue.expiresAt
            scopes = newValue.scopes
            savedAt = newValue.savedAt
        }
    }
}

/// One authorization attempt: fresh state, nonce, and PKCE verifier, plus the
/// exact redirect URI that must be repeated in the code exchange.
public struct ChatGPTPendingAuthorization: Equatable, Sendable {
    public let clientID: String
    public let state: String
    public let nonce: String
    public let codeVerifier: String
    public let redirectURI: String
    public let authorizationURL: URL
    public let existingConnectionID: String?
}

/// Sign in with ChatGPT: PKCE + 127.0.0.1 loopback, Keychain tokens with
/// rotating refresh, and the Bearer token for Responses requests.
///
/// macOS opens the system browser. iPhone and iPad show an
/// `ASWebAuthenticationSession` while an in-app listener on 127.0.0.1 waits
/// for the redirect, then dismiss the sheet themselves.
@MainActor
public final class ChatGPTAccountService: ObservableObject {
    public static let shared = ChatGPTAccountService()

    public static let hostIDDefaultsKey = "anaiodyssey.chatgpt.extAgentHostID"
    public static let planNoticeShownKey = "anaiodyssey.chatgpt.planNoticeShown"
    nonisolated public static let keychainService = "com.example.anaiodyssey.chatgpt.tokens"
    public static let signInTimeout: UInt64 = 300_000_000_000

    @Published public var lastError: String?
    @Published public var isSigningIn = false
    /// One-time “You’re using your ChatGPT plan” notice after the first plan sign-in.
    @Published public private(set) var showsPlanNotice = false

    private let defaults: UserDefaults
    private let secureStore: TokenSecureStore
    private let session: URLSession
    private let now: () -> Date
    private let verifySignatures: Bool
    /// Single-flight refresh per connection: two concurrent refreshes with the
    /// same rotating token would trip `refresh_token_reused` and sign the user out.
    private var refreshTasks: [String: Task<ChatGPTStoredCredentials, Error>] = [:]
    #if os(iOS) && canImport(AuthenticationServices)
    private var webAuthSession: ASWebAuthenticationSession?
    private let presentationProvider = ChatGPTWebAuthPresentationProvider()
    #endif

    public init(
        defaults: UserDefaults = .standard,
        secureStore: TokenSecureStore = KeychainTokenSecureStore(service: ChatGPTAccountService.keychainService),
        session: URLSession = .shared,
        now: @escaping () -> Date = Date.init,
        verifySignatures: Bool = true
    ) {
        self.defaults = defaults
        self.secureStore = secureStore
        self.session = session
        self.now = now
        self.verifySignatures = verifySignatures
    }

    /// Mac uses the system browser; iPhone/iPad use ASWebAuthenticationSession.
    public var isInteractiveSignInSupported: Bool {
        #if os(macOS) || os(iOS)
        true
        #else
        false
        #endif
    }

    public func hostID() -> String {
        if let existing = defaults.string(forKey: Self.hostIDDefaultsKey),
           !existing.isEmpty {
            return existing
        }
        let generated = ChatGPTOAuthCodec.makeHostID()
        defaults.set(generated, forKey: Self.hostIDDefaultsKey)
        return generated
    }

    public func credentials(for connectionID: String) -> ChatGPTStoredCredentials? {
        guard let data = secureStore.read(account: connectionID) else { return nil }
        return try? JSONDecoder().decode(ChatGPTStoredCredentials.self, from: data)
    }

    public func hasCredentials(for connectionID: String) -> Bool {
        credentials(for: connectionID) != nil
    }

    public func acknowledgePlanNotice() {
        defaults.set(true, forKey: Self.planNoticeShownKey)
        showsPlanNotice = false
    }

    // MARK: Interactive sign-in

    /// Runs the whole sign-in: listener, browser, callback, exchange, validation.
    /// `requestPlanConsent` re-asks for plan permission after an earlier decline.
    public func signIn(
        into providerSettings: ProviderSettings,
        existingConnectionID: String? = nil,
        requestPlanConsent: Bool = false
    ) async throws {
        isSigningIn = true
        lastError = nil
        defer { isSigningIn = false }
        do {
            let listener = try await ChatGPTOAuthLoopback.start()
            let pending = beginAuthorization(
                redirectURI: listener.redirectURI,
                existingConnectionID: existingConnectionID,
                providerSettings: providerSettings,
                requestPlanConsent: requestPlanConsent
            )
            let callback: ChatGPTAuthorizationCallback
            do {
                try openBrowser(pending.authorizationURL, onUserCancel: { listener.stop() })
                callback = try await withThrowingTaskGroup(of: ChatGPTAuthorizationCallback.self) { group in
                    group.addTask { try await listener.result() }
                    group.addTask {
                        try await Task.sleep(nanoseconds: Self.signInTimeout)
                        throw ChatGPTAccountError.cancelled
                    }
                    let value = try await group.next()!
                    group.cancelAll()
                    return value
                }
            } catch {
                listener.stop()
                dismissBrowser()
                throw error
            }
            dismissBrowser()
            _ = try await completeAuthorization(callback, pending: pending, into: providerSettings)
        } catch {
            if (error as? ChatGPTAccountError) != .ineligible {
                lastError = error.localizedDescription
            }
            throw error
        }
    }

    /// Builds one authorization attempt with fresh state, nonce, and PKCE.
    public func beginAuthorization(
        redirectURI: String,
        existingConnectionID: String?,
        providerSettings: ProviderSettings,
        requestPlanConsent: Bool = false
    ) -> ChatGPTPendingAuthorization {
        let existing = existingConnectionID.flatMap { providerSettings.connection(id: $0) }
        let saved = existing?.chatgptIssuedClientID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let clientID = (!saved.isEmpty && saved != ChatGPTOAuthCodec.dynamicClientID)
            ? saved
            : ChatGPTOAuthCodec.dynamicClientID
        let state = ChatGPTOAuthCodec.makeRandomState()
        let nonce = ChatGPTOAuthCodec.makeRandomState()
        let verifier = ChatGPTOAuthCodec.makePKCEVerifier()
        let url = ChatGPTOAuthCodec.authorizationURL(
            clientID: clientID,
            redirectURI: redirectURI,
            state: state,
            nonce: nonce,
            codeChallenge: ChatGPTOAuthCodec.pkceChallenge(verifier: verifier),
            extAgentHostID: hostID(),
            agentNameHint: clientID == ChatGPTOAuthCodec.dynamicClientID ? ChatGPTOAuthCodec.agentNameHint : nil,
            loginHint: existing?.chatgptEmail,
            idTokenHint: existing.flatMap { credentials(for: $0.id)?.idToken },
            prompt: requestPlanConsent ? "consent" : nil
        )
        return ChatGPTPendingAuthorization(
            clientID: clientID,
            state: state,
            nonce: nonce,
            codeVerifier: verifier,
            redirectURI: redirectURI,
            authorizationURL: url,
            existingConnectionID: existing?.id
        )
    }

    /// Validates the callback, exchanges the code, checks the ID token and the
    /// `chatgpt.tokens.use.direct` grant, and saves the account. Throws
    /// `.ineligible` (after saving) when plan usage was not granted.
    @discardableResult
    public func completeAuthorization(
        _ callback: ChatGPTAuthorizationCallback,
        pending: ChatGPTPendingAuthorization,
        into providerSettings: ProviderSettings
    ) async throws -> RemoteConnection {
        guard callback.state == pending.state else {
            throw ChatGPTAccountError.stateMismatch
        }
        let existing = pending.existingConnectionID.flatMap { providerSettings.connection(id: $0) }
        let issuedClientID = try ChatGPTOAuthCodec.resolvedIssuedClientID(
            callbackClientID: callback.issuedClientID,
            pendingClientID: pending.clientID
        )
        let tokens = try await exchangeCode(
            callback.code,
            clientID: issuedClientID,
            verifier: pending.codeVerifier,
            redirectURI: pending.redirectURI
        )
        let idToken = tokens.idToken ?? ""
        guard !idToken.isEmpty else {
            throw ChatGPTOAuthCodecError.invalidIDToken
        }
        if verifySignatures {
            try await verifyIDTokenSignature(idToken)
        }
        let identity = try ChatGPTOAuthCodec.validateIDTokenClaims(
            idToken,
            issuedClientID: issuedClientID,
            nonce: pending.nonce,
            now: now()
        )
        if let existingSubject = existing?.chatgptSubject,
           !existingSubject.isEmpty,
           existingSubject != identity.subject {
            throw ChatGPTOAuthCodecError.invalidIDTokenClaims("subject")
        }
        // Granted scopes come from the token response; the callback is a fallback.
        let scopes = ChatGPTOAuthCodec.parseScopeString(tokens.scope ?? callback.scope)
        let eligible = ChatGPTOAuthCodec.isPlanEligible(grantedScopes: scopes)
        let savedAt = now()
        let stored = ChatGPTStoredCredentials(
            email: identity.email,
            issuer: identity.issuer,
            subject: identity.subject,
            clientID: issuedClientID,
            extAgentHostID: hostID(),
            idToken: idToken,
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            tokenType: tokens.tokenType,
            expiresAt: savedAt.addingTimeInterval(TimeInterval(tokens.expiresIn)),
            scopes: scopes,
            savedAt: savedAt
        )
        let connectionID = existing?.id ?? UUID().uuidString
        try saveCredentials(stored, connectionID: connectionID)
        var connection = existing ?? RemoteConnection.chatGPTPreset()
        connection.id = connectionID
        connection.name = identity.email.map { "ChatGPT (\($0))" } ?? "ChatGPT"
        connection.apiBaseURL = RemoteConnection.defaultOpenAIBaseURL
        connection.apiKey = ""
        connection.chatgptIssuedClientID = issuedClientID
        connection.chatgptEmail = identity.email
        connection.chatgptSubject = identity.subject
        connection.chatgptPlanEligible = eligible
        connection.encoding = .openAIChatCompletions
        connection.isEnabled = eligible
        providerSettings.updateConnection(connection)
        objectWillChange.send()
        guard eligible else {
            throw ChatGPTAccountError.ineligible
        }
        if !defaults.bool(forKey: Self.planNoticeShownKey) {
            showsPlanNotice = true
        }
        return connection
    }

    public func signOut(
        connection: RemoteConnection,
        providerSettings: ProviderSettings
    ) async {
        if let credentials = credentials(for: connection.id) {
            await revoke(credentials: credentials)
        }
        secureStore.remove(account: connection.id)
        providerSettings.removeConnection(id: connection.id)
        objectWillChange.send()
    }

    /// Turns plan usage off after a `subscription_sharing_user_not_eligible`
    /// response. The sign-in is kept so the user can re-enable it later.
    public func markPlanUnavailable(
        connectionID: String,
        providerSettings: ProviderSettings,
        message: String
    ) {
        if var connection = providerSettings.connection(id: connectionID) {
            connection.chatgptPlanEligible = false
            providerSettings.updateConnection(connection)
        }
        lastError = message
        objectWillChange.send()
    }

    // MARK: Tokens

    public func validAccessToken(for connection: RemoteConnection) async throws -> String {
        guard connection.usesChatGPTAccount else {
            throw ChatGPTAccountError.notSignedIn
        }
        guard connection.chatgptPlanEligible == true else {
            throw ChatGPTAccountError.ineligible
        }
        guard let credentials = credentials(for: connection.id) else {
            throw ChatGPTAccountError.signInRequired
        }
        if !credentials.tokens.needsRefresh(now: now()) {
            return credentials.accessToken
        }
        let refreshed = try await refreshSingleFlight(credentials, connectionID: connection.id)
        if !refreshed.isPlanEligible {
            throw ChatGPTAccountError.ineligible
        }
        return refreshed.accessToken
    }

    public func refreshAndApplyEligibility(
        connection: RemoteConnection,
        providerSettings: ProviderSettings
    ) async throws -> ChatGPTStoredCredentials {
        guard let credentials = credentials(for: connection.id) else {
            throw ChatGPTAccountError.signInRequired
        }
        let refreshed = try await refreshSingleFlight(credentials, connectionID: connection.id)
        var updated = connection
        updated.chatgptPlanEligible = refreshed.isPlanEligible
        updated.chatgptEmail = refreshed.email ?? updated.chatgptEmail
        providerSettings.updateConnection(updated)
        if !refreshed.isPlanEligible {
            throw ChatGPTAccountError.ineligible
        }
        return refreshed
    }

    /// Writes one credential record (atomically replaces the previous one).
    #if DEBUG
    /// UI tests only (`UITEST_CHATGPT_PLAN`): adds a fake signed-in plan account
    /// so screenshots can show the in-use label and one-time notice. The token is
    /// fake, so no request ever reaches OpenAI with it. Not compiled into Release.
    public func seedUITestPlanAccount(into providerSettings: ProviderSettings) {
        let connectionID = "uitest-chatgpt-plan"
        let now = Date()
        let stored = ChatGPTStoredCredentials(
            email: "user@example.com",
            issuer: ChatGPTOAuthCodec.issuer,
            subject: "uitest-subject",
            clientID: "oaiapp_uitest",
            extAgentHostID: hostID(),
            idToken: "uitest",
            accessToken: "uitest",
            refreshToken: "uitest",
            tokenType: "Bearer",
            expiresAt: now.addingTimeInterval(3600),
            scopes: ChatGPTOAuthCodec.parseScopeString(ChatGPTOAuthCodec.requestedScope),
            savedAt: now
        )
        try? saveCredentials(stored, connectionID: connectionID)
        var connection = providerSettings.connection(id: connectionID) ?? RemoteConnection.chatGPTPreset()
        connection.id = connectionID
        connection.name = "ChatGPT (user@example.com)"
        connection.apiBaseURL = RemoteConnection.defaultOpenAIBaseURL
        connection.apiKey = ""
        connection.chatgptIssuedClientID = "oaiapp_uitest"
        connection.chatgptEmail = "user@example.com"
        connection.chatgptSubject = "uitest-subject"
        connection.chatgptPlanEligible = true
        connection.isEnabled = true
        providerSettings.updateConnection(connection)
        defaults.removeObject(forKey: Self.planNoticeShownKey)
        showsPlanNotice = true
        objectWillChange.send()
    }
    #endif

    public func saveCredentials(_ credentials: ChatGPTStoredCredentials, connectionID: String) throws {
        let data = try JSONEncoder().encode(credentials)
        secureStore.write(data, account: connectionID)
        if secureStore.read(account: connectionID) == nil {
            throw ChatGPTAccountError.keychainFailed
        }
    }

    // MARK: Browser

    private func openBrowser(_ url: URL, onUserCancel: @escaping @Sendable () -> Void) throws {
        #if os(macOS)
        guard NSWorkspace.shared.open(url) else {
            throw ChatGPTAccountError.missingCallback
        }
        #elseif os(iOS) && canImport(AuthenticationServices)
        // No custom scheme: OpenAI only redirects to http://127.0.0.1. The
        // in-app listener receives the redirect and `dismissBrowser` closes
        // the sheet. The completion handler only fires on user cancel.
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: nil) { _, error in
            if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                onUserCancel()
            }
        }
        session.presentationContextProvider = presentationProvider
        session.prefersEphemeralWebBrowserSession = false
        webAuthSession = session
        guard session.start() else {
            webAuthSession = nil
            throw ChatGPTAccountError.iOSNotSupported
        }
        #else
        throw ChatGPTAccountError.iOSNotSupported
        #endif
    }

    private func dismissBrowser() {
        #if os(iOS) && canImport(AuthenticationServices)
        webAuthSession?.cancel()
        webAuthSession = nil
        #elseif os(macOS)
        NSApp.activate(ignoringOtherApps: true)
        #endif
    }

    // MARK: Token endpoint

    private func exchangeCode(
        _ code: String,
        clientID: String,
        verifier: String,
        redirectURI: String
    ) async throws -> ChatGPTTokenResponse {
        var request = URLRequest(url: ChatGPTOAuthCodec.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = ChatGPTOAuthCodec.tokenExchangeBody(
            code: code,
            clientID: clientID,
            codeVerifier: verifier,
            redirectURI: redirectURI
        )
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            if let code = OAuthTokenCodec.errorCode(in: data) {
                let description = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error_description"] as? String
                throw ChatGPTOAuthCodecError.tokenEndpoint(code, description)
            }
            throw ChatGPTOAuthCodecError.tokenEndpoint(
                "http_\(http.statusCode)",
                String(data: data, encoding: .utf8)
            )
        }
        return try ChatGPTOAuthCodec.parseTokenResponse(data)
    }

    private func refreshSingleFlight(
        _ credentials: ChatGPTStoredCredentials,
        connectionID: String
    ) async throws -> ChatGPTStoredCredentials {
        if let running = refreshTasks[connectionID] {
            return try await running.value
        }
        let task = Task { @MainActor in
            try await self.refresh(credentials, connectionID: connectionID)
        }
        refreshTasks[connectionID] = task
        defer { refreshTasks[connectionID] = nil }
        return try await task.value
    }

    private func refresh(
        _ credentials: ChatGPTStoredCredentials,
        connectionID: String
    ) async throws -> ChatGPTStoredCredentials {
        guard let refreshToken = credentials.refreshToken, !refreshToken.isEmpty else {
            secureStore.remove(account: connectionID)
            objectWillChange.send()
            throw ChatGPTAccountError.signInRequired
        }
        var request = URLRequest(url: ChatGPTOAuthCodec.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = ChatGPTOAuthCodec.refreshTokenBody(
            refreshToken: refreshToken,
            clientID: credentials.clientID
        )
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ChatGPTAccountError.refreshFailed(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            switch OAuthTokenCodec.classifyRefreshFailure(statusCode: status, body: data) {
            case .reauthenticate:
                // Unusable refresh token: clear tokens, keep the issued client id
                // on the connection so the next sign-in reuses the registration.
                secureStore.remove(account: connectionID)
                objectWillChange.send()
                throw ChatGPTAccountError.signInRequired
            case .invalidClient:
                throw ChatGPTAccountError.invalidClient
            case .transient:
                throw ChatGPTAccountError.refreshFailed("HTTP \(status)")
            }
        }
        let tokens = try ChatGPTOAuthCodec.parseTokenResponse(data)
        var updated = credentials
        updated.tokens = credentials.tokens.applyingRefresh(tokens, now: now())
        // Save the rotated refresh token before anything else can fail.
        try saveCredentials(updated, connectionID: connectionID)
        objectWillChange.send()
        return updated
    }

    private func revoke(credentials: ChatGPTStoredCredentials) async {
        let token = credentials.refreshToken ?? credentials.accessToken
        var request = URLRequest(url: ChatGPTOAuthCodec.revocationEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = ChatGPTOAuthCodec.revokeBody(token: token, clientID: credentials.clientID)
        _ = try? await session.data(for: request)
    }

    private func verifyIDTokenSignature(_ jwt: String) async throws {
        #if canImport(Security)
        let header = try ChatGPTOAuthCodec.decodeJWTHeader(jwt)
        let kid = header["kid"] as? String
        let alg = header["alg"] as? String ?? "RS256"
        guard alg == "RS256" else {
            throw ChatGPTAccountError.jwksVerificationFailed
        }
        let (jwksData, _) = try await session.data(from: ChatGPTOAuthCodec.jwksURL)
        guard let object = try JSONSerialization.jsonObject(with: jwksData) as? [String: Any],
              let keys = object["keys"] as? [[String: Any]] else {
            throw ChatGPTAccountError.jwksVerificationFailed
        }
        let key = keys.first { row in
            if let kid { return row["kid"] as? String == kid }
            return row["kty"] as? String == "RSA"
        }
        guard let key,
              let n = key["n"] as? String,
              let e = key["e"] as? String,
              let secKey = rsaPublicKey(modulus: n, exponent: e) else {
            throw ChatGPTAccountError.jwksVerificationFailed
        }
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let signature = ChatGPTOAuthCodec.base64URLDecode(String(parts[2])) else {
            throw ChatGPTAccountError.jwksVerificationFailed
        }
        let signingInput = Data("\(parts[0]).\(parts[1])".utf8)
        var error: Unmanaged<CFError>?
        let ok = SecKeyVerifySignature(
            secKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            signingInput as CFData,
            signature as CFData,
            &error
        )
        if !ok {
            throw ChatGPTAccountError.jwksVerificationFailed
        }
        #else
        throw ChatGPTAccountError.jwksVerificationFailed
        #endif
    }

    #if canImport(Security)
    private func rsaPublicKey(modulus: String, exponent: String) -> SecKey? {
        guard let nData = ChatGPTOAuthCodec.base64URLDecode(modulus),
              let eData = ChatGPTOAuthCodec.base64URLDecode(exponent) else {
            return nil
        }
        var modulusBytes = [UInt8](nData)
        if modulusBytes.first != 0 {
            modulusBytes.insert(0, at: 0)
        }
        let encoded = rsaPublicKeyDER(modulus: Data(modulusBytes), exponent: eData)
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
        ]
        var error: Unmanaged<CFError>?
        return SecKeyCreateWithData(encoded as CFData, attributes as CFDictionary, &error)
    }

    private func rsaPublicKeyDER(modulus: Data, exponent: Data) -> Data {
        let modulusTLV = derInteger(modulus)
        let exponentTLV = derInteger(exponent)
        let sequence = derSequence(modulusTLV + exponentTLV)
        let algorithm = derSequence(
            derOID([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01]) + Data([0x05, 0x00])
        )
        let bitString = derBitString(sequence)
        return derSequence(algorithm + bitString)
    }

    private func derInteger(_ data: Data) -> Data {
        derTLV(0x02, data)
    }

    private func derBitString(_ data: Data) -> Data {
        derTLV(0x03, Data([0x00]) + data)
    }

    private func derSequence(_ data: Data) -> Data {
        derTLV(0x30, data)
    }

    private func derOID(_ bytes: [UInt8]) -> Data {
        derTLV(0x06, Data(bytes))
    }

    private func derTLV(_ tag: UInt8, _ value: Data) -> Data {
        Data([tag]) + derLength(value.count) + value
    }

    private func derLength(_ length: Int) -> Data {
        if length < 128 {
            return Data([UInt8(length)])
        }
        if length < 256 {
            return Data([0x81, UInt8(length)])
        }
        return Data([0x82, UInt8((length >> 8) & 0xff), UInt8(length & 0xff)])
    }
    #endif
}

#if os(iOS) && canImport(AuthenticationServices)
/// Anchors the ChatGPT sign-in sheet on the foreground key window.
final class ChatGPTWebAuthPresentationProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let active = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
            return active?.keyWindow ?? active?.windows.first ?? ASPresentationAnchor()
        }
    }
}
#endif
