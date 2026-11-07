// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation

/// Errors that can arise during Google OAuth sign-in, token exchange, and refresh.
public enum GoogleOAuthError: Error, LocalizedError {
    case notConfigured
    case cancelled
    case missingAuthorizationCode
    case tokenExchangeFailed(String)
    case tokenPersistFailed(String)
    case refreshFailed(String)
    case interactiveSignInUnavailable

    /// Human-readable description for each failure case.
    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Enter a Google OAuth Client ID (iOS/Desktop) in Settings."
        case .cancelled:
            "Google sign-in was cancelled."
        case .missingAuthorizationCode:
            "Google did not return an authorization code."
        case .tokenExchangeFailed(let detail):
            "Google token exchange failed: \(detail)"
        case .tokenPersistFailed(let detail):
            detail
        case .refreshFailed(let detail):
            Self.refreshFailureDescription(detail)
        case .interactiveSignInUnavailable:
            "Google sign-in is unavailable on this platform."
        }
    }

    /// Maps Google's `invalid_grant` (expired testing tokens) to a clear next step.
    static func refreshFailureDescription(_ detail: String) -> String {
        if detail.localizedCaseInsensitiveContains("invalid_grant") {
            return "Google expired this login. If the OAuth consent screen is still in Testing, refresh tokens last 7 days — publish the app in Google Cloud Console (APIs & Services → OAuth consent screen), then sign in again."
        }
        return "Google token refresh failed: \(detail)"
    }
}

/// Implements the Google OAuth 2.0 authorization-code flow with PKCE.
///
/// Sign-in is interactive via `ASWebAuthenticationSession` (cross-platform: iPadOS and
/// macOS) and captures the redirect to the app's reversed-client-id custom scheme — no
/// client secret or loopback server required. Tokens are persisted via the injected,
/// account-scoped `GoogleTokenStore` and transparently refreshed before use. A legacy
/// loopback-based code exchange is retained for the manual "paste authorization code"
/// fallback. Requests Gmail (read + modify), Calendar, and userinfo.email scopes.
public final class GoogleOAuthService {
    /// Legacy loopback redirect URI used only by the manual code-paste fallback.
    public static let redirectURI = "http://127.0.0.1:8765/oauth2callback"
    /// `UserDefaults` key holding the configured OAuth client id.
    public static let oauthClientIDKey = "anaiodyssey.google.oauthClientID"
    /// OAuth scopes requested at consent: Gmail read/modify, Calendar, and account email.
    public static let scopes = [
        "https://www.googleapis.com/auth/gmail.readonly",
        "https://www.googleapis.com/auth/gmail.modify",
        "https://www.googleapis.com/auth/calendar",
        "https://www.googleapis.com/auth/userinfo.email",
    ]

    private let tokenStore: GoogleTokenStore
    private let session: URLSession
    private let defaults: UserDefaults
    private let explicitClientID: String?
    private let accountEmailKey = "anaiodyssey.google.accountEmail"

    public init(
        tokenStore: GoogleTokenStore,
        clientID: String? = nil,
        defaults: UserDefaults = .standard,
        session: URLSession = .shared
    ) {
        self.tokenStore = tokenStore
        self.explicitClientID = clientID
        self.defaults = defaults
        self.session = session
    }

    /// The configured OAuth client id, trimmed; empty when not set up.
    ///
    /// Prefers an explicitly-injected id, falling back to the shared one in `UserDefaults`.
    private var clientID: String {
        if let explicitClientID, !explicitClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return explicitClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return defaults.string(forKey: Self.oauthClientIDKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// True when an OAuth client id has been configured.
    public var isConfigured: Bool {
        !clientID.isEmpty
    }

    /// Runs the interactive PKCE sign-in and persists the resulting tokens.
    ///
    /// Presents Google's consent UI, captures the authorization code, and exchanges
    /// it (with the PKCE verifier) for access/refresh tokens. `loginHint` can prefill
    /// the account chooser when adding a known address.
    @MainActor
    public func signInInteractively(loginHint: String? = nil) async throws -> GoogleOAuthTokens {
        guard isConfigured else { throw GoogleOAuthError.notConfigured }
        ConnectionDebug.log(
            "OAuth",
            "interactive sign-in start account=\(ConnectionDebug.account(tokenStore.accountID)) loginHint=\(loginHint == nil ? "none" : "present") scopes=\(Self.scopes.count)"
        )
        let authSession = GoogleAuthSession()
        let result = try await authSession.authorize(
            clientID: clientID,
            scopes: Self.scopes,
            loginHint: loginHint
        )
        ConnectionDebug.log("OAuth", "authorization callback received account=\(ConnectionDebug.account(tokenStore.accountID))")
        return try await exchangeCode(
            result.code,
            codeVerifier: result.codeVerifier,
            redirectURI: result.redirectURI
        )
    }

    /// Exchanges an authorization code (with PKCE verifier) for tokens and persists them.
    public func exchangeCode(
        _ code: String,
        codeVerifier: String,
        redirectURI: String
    ) async throws -> GoogleOAuthTokens {
        guard isConfigured else { throw GoogleOAuthError.notConfigured }
        ConnectionDebug.log("OAuth", "authorization-code exchange start account=\(ConnectionDebug.account(tokenStore.accountID))")
        let body = [
            "code": code,
            "client_id": clientID,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": codeVerifier,
        ]
        let tokens = try await tokenRequest(body: body)
        try await persistFreshSession(tokens)
        ConnectionDebug.log("OAuth", "authorization-code exchange complete account=\(ConnectionDebug.account(tokenStore.accountID))")
        return tokens
    }

    /// Legacy loopback code exchange (no PKCE), used by the manual "paste code" fallback.
    public func exchangeCode(_ code: String) async throws -> GoogleOAuthTokens {
        guard isConfigured else { throw GoogleOAuthError.notConfigured }
        let body = [
            "code": code,
            "client_id": clientID,
            "redirect_uri": Self.redirectURI,
            "grant_type": "authorization_code",
        ]
        let tokens = try await tokenRequest(body: body)
        try await persistFreshSession(tokens)
        return tokens
    }

    /// Writes a newly issued session (Keychain, with local fallback) and records
    /// the account email. A missing refresh token does not abort sign-in.
    private func persistFreshSession(_ tokens: GoogleOAuthTokens) async throws {
        try tokenStore.save(tokens)
        try tokenStore.requirePersistedRefreshToken()
        ConnectionDebug.log(
            "OAuth",
            "fresh session persisted account=\(ConnectionDebug.account(tokenStore.accountID)) hasRefresh=\(tokens.refreshToken?.isEmpty == false)"
        )
        if let email = try? await fetchAccountEmail(accessToken: tokens.accessToken) {
            defaults.set(email, forKey: accountEmailKey)
            ConnectionDebug.log("OAuth", "userinfo succeeded account=\(ConnectionDebug.account(tokenStore.accountID))")
        } else {
            ConnectionDebug.log("OAuth", "userinfo failed account=\(ConnectionDebug.account(tokenStore.accountID))")
        }
    }

    /// Returns current tokens, refreshing them via the refresh token when expired.
    ///
    /// If the cached access token is still valid it's returned as-is — unless it equals
    /// `rejectedAccessToken`, which callers pass after Google answered a request with
    /// HTTP 401 even though the token looked valid locally (revoked token, clock skew,
    /// or a stale cached expiry). Otherwise a refresh-token grant is performed; the
    /// refresh token is carried forward when Google doesn't return a new one. Refreshes
    /// are single-flighted per token store so concurrent Gmail/Calendar calls share one
    /// grant. Throws `.refreshFailed` when no refresh token is available.
    public func refreshAccessTokenIfNeeded(
        rejecting rejectedAccessToken: String? = nil
    ) async throws -> GoogleOAuthTokens {
        // Fast path: the existing access token hasn't expired (incl. 60s margin)
        // and wasn't just rejected by a Google API.
        if let tokens = tokenStore.tokens, !tokens.isExpired, tokens.accessToken != rejectedAccessToken {
            ConnectionDebug.log(
                "OAuth",
                "using cached access token account=\(ConnectionDebug.account(tokenStore.accountID)) forced=\(rejectedAccessToken != nil)"
            )
            return tokens
        }
        ConnectionDebug.log(
            "OAuth",
            "access token refresh required account=\(ConnectionDebug.account(tokenStore.accountID)) forced=\(rejectedAccessToken != nil)"
        )
        return try await tokenStore.coordinateRefresh { [self] in
            // Re-check inside the gate: a concurrent caller may have just refreshed.
            if let tokens = tokenStore.tokens, !tokens.isExpired, tokens.accessToken != rejectedAccessToken {
                ConnectionDebug.log("OAuth", "joined completed token refresh account=\(ConnectionDebug.account(tokenStore.accountID))")
                return tokens
            }
            // We need a refresh token to mint a new access token.
            guard let refreshToken = tokenStore.refreshTokenValue() else {
                ConnectionDebug.log("OAuth", "refresh unavailable: no refresh token account=\(ConnectionDebug.account(tokenStore.accountID))")
                throw GoogleOAuthError.refreshFailed("No refresh token. Sign in again.")
            }
            // Refresh-token grant parameters.
            let body = [
                "refresh_token": refreshToken,
                "client_id": clientID,
                "grant_type": "refresh_token",
            ]
            do {
                ConnectionDebug.log("OAuth", "refresh grant start account=\(ConnectionDebug.account(tokenStore.accountID))")
                var tokens = try await tokenRequest(body: body, isRefresh: true)
                // Google omits the refresh token on refresh responses; preserve the existing one.
                if tokens.refreshToken == nil {
                    tokens.refreshToken = refreshToken
                }
                try tokenStore.save(tokens)
                ConnectionDebug.log("OAuth", "refresh grant complete account=\(ConnectionDebug.account(tokenStore.accountID))")
                return tokens
            } catch GoogleOAuthError.refreshFailed(let detail) {
                ConnectionDebug.log(
                    "OAuth",
                    "refresh grant failed account=\(ConnectionDebug.account(tokenStore.accountID)) invalidGrant=\(detail.localizedCaseInsensitiveContains("invalid_grant"))"
                )
                // Google says this refresh token is dead (expired testing-mode token,
                // revoked access). Sign the slot out so the reconnect UI appears —
                // but only if the failed token is still current, so a fresh
                // interactive sign-in that landed mid-flight is never wiped out.
                if detail.localizedCaseInsensitiveContains("invalid_grant"),
                   tokenStore.refreshTokenValue() == refreshToken {
                    tokenStore.clear()
                }
                throw GoogleOAuthError.refreshFailed(detail)
            }
        }
    }

    /// Convenience returning a guaranteed-valid access token string for API authorization.
    ///
    /// Pass the token Google just rejected with a 401 as `rejecting` to force a refresh
    /// even when the cached token still looks unexpired locally.
    public func validAccessToken(rejecting rejectedAccessToken: String? = nil) async throws -> String {
        let tokens = try await refreshAccessTokenIfNeeded(rejecting: rejectedAccessToken)
        return tokens.accessToken
    }

    /// Fetches the signed-in account email using the current (refreshed) access token.
    public func currentAccountEmail() async throws -> String {
        let token = try await validAccessToken()
        return try await fetchAccountEmail(accessToken: token)
    }

    /// Percent-encodes a token POST body. `CharacterSet.urlQueryAllowed` leaves
    /// `+` unescaped, which Google would treat as a space and reject on refresh.
    static func formURLEncoded(_ body: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return body
            .map { key, value in
                let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(encodedKey)=\(encodedValue)"
            }
            .joined(separator: "&")
            .data(using: .utf8) ?? Data()
    }

    /// Posts a form-encoded token request and decodes the token response.
    ///
    /// Shared by the code-exchange and refresh grants. Maps non-2xx responses and
    /// missing `access_token` to `.tokenExchangeFailed`, and computes `expiresAt` from the
    /// `expires_in` seconds returned by Google.
    private func tokenRequest(body: [String: String], isRefresh: Bool = false) async throws -> GoogleOAuthTokens {
        // Build the application/x-www-form-urlencoded POST to Google's token endpoint.
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formURLEncoded(body)

        ConnectionDebug.log(
            "OAuth",
            "token endpoint request account=\(ConnectionDebug.account(tokenStore.accountID)) grant=\(isRefresh ? "refresh" : "authorization_code")"
        )
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            ConnectionDebug.log("OAuth", "token endpoint invalid response account=\(ConnectionDebug.account(tokenStore.accountID))")
            throw GoogleOAuthError.tokenExchangeFailed("Invalid response")
        }
        ConnectionDebug.log(
            "OAuth",
            "token endpoint response account=\(ConnectionDebug.account(tokenStore.accountID)) grant=\(isRefresh ? "refresh" : "authorization_code") status=\(http.statusCode) bytes=\(data.count)"
        )
        // Surface the error body text on any non-success status.
        guard (200...299).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            if isRefresh {
                throw GoogleOAuthError.refreshFailed(bodyText)
            }
            throw GoogleOAuthError.tokenExchangeFailed(bodyText)
        }

        // An access token is mandatory in the response.
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = object["access_token"] as? String else {
            throw GoogleOAuthError.tokenExchangeFailed("Missing access_token")
        }

        // Convert the relative expires_in (seconds) into an absolute expiry date.
        let expiresIn = object["expires_in"] as? Double
        let expiresAt = expiresIn.map { Date().addingTimeInterval($0) }
        return GoogleOAuthTokens(
            accessToken: accessToken,
            refreshToken: object["refresh_token"] as? String,
            expiresAt: expiresAt,
            tokenType: object["token_type"] as? String ?? "Bearer"
        )
    }

    /// Fetches the signed-in user's email from the Google userinfo endpoint.
    ///
    /// Used after sign-in to display which account is connected; throws
    /// `.tokenExchangeFailed` if the request fails or no email is present.
    private func fetchAccountEmail(accessToken: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/oauth2/v2/userinfo")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        // Require a successful response containing an `email` field.
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let email = object["email"] as? String else {
            throw GoogleOAuthError.tokenExchangeFailed("Could not load Google account email.")
        }
        return email
    }
}
