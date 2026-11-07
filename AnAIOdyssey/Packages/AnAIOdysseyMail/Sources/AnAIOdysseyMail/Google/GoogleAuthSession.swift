// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import AuthenticationServices
import CryptoKit
import Foundation
import Security

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// PKCE parameters for a single authorization-code exchange.
///
/// The `verifier` is a high-entropy random string kept on-device; the
/// `challenge` (its SHA-256, base64url-encoded) is sent on the authorization
/// request. Google ties the two together so the code can only be redeemed by the
/// client that started the flow — no client secret required for installed apps.
struct PKCE {
    let verifier: String
    let challenge: String
    let method = "S256"

    /// Generates a fresh verifier/challenge pair.
    init() {
        verifier = Self.randomURLSafeString(byteCount: 64)
        let digest = SHA256.hash(data: Data(verifier.utf8))
        challenge = Data(digest).base64URLEncodedString()
    }

    /// Produces a URL-safe random string from `byteCount` random bytes.
    private static func randomURLSafeString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return Data(bytes).base64URLEncodedString()
    }
}

/// Drives the interactive Google OAuth consent flow via `ASWebAuthenticationSession`.
///
/// Cross-platform (iOS/iPadOS and macOS): opens Google's consent page in a secure
/// in-app browser session and captures the redirect to the app's reversed-client-id
/// custom scheme. Uses PKCE (no client secret), which is the supported pattern for
/// installed apps. Returns the captured authorization code plus the PKCE verifier
/// the caller needs to redeem it.
@MainActor
public final class GoogleAuthSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    /// Result of a successful interactive authorization: the one-time code and the
    /// PKCE verifier + redirect URI required to exchange it for tokens.
    public struct AuthorizationResult: Sendable {
        public let code: String
        public let codeVerifier: String
        public let redirectURI: String
    }

    private var session: ASWebAuthenticationSession?

    public override init() {
        super.init()
    }

    /// Derives Google's reversed-client-id custom URL scheme from a client id.
    ///
    /// `1234-abc.apps.googleusercontent.com` → `com.googleusercontent.apps.1234-abc`.
    /// Returns `nil` for client ids that don't match the expected suffix (e.g. a
    /// web client id), since those can't use the custom-scheme redirect.
    public static func reversedClientScheme(for clientID: String) -> String? {
        let suffix = ".apps.googleusercontent.com"
        let trimmed = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix(suffix) else { return nil }
        let prefix = String(trimmed.dropLast(suffix.count))
        guard !prefix.isEmpty else { return nil }
        return "com.googleusercontent.apps.\(prefix)"
    }

    /// Runs the full consent flow and returns the captured authorization code.
    ///
    /// Builds the authorization URL (PKCE + offline access), presents the secure
    /// web session, and parses `code` from the redirect. Throws
    /// `GoogleOAuthError.notConfigured` for an unusable client id and
    /// `.cancelled` / `.missingAuthorizationCode` for user cancellation or a
    /// malformed callback.
    public func authorize(
        clientID: String,
        scopes: [String],
        loginHint: String? = nil
    ) async throws -> AuthorizationResult {
        guard let scheme = Self.reversedClientScheme(for: clientID) else {
            throw GoogleOAuthError.notConfigured
        }
        let redirectURI = "\(scheme):/oauth2redirect"
        let pkce = PKCE()

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        var query: [URLQueryItem] = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: pkce.method),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        if let loginHint, !loginHint.isEmpty {
            query.append(URLQueryItem(name: "login_hint", value: loginHint))
        }
        components.queryItems = query
        guard let authURL = components.url else {
            throw GoogleOAuthError.notConfigured
        }

        let callbackURL = try await present(authURL: authURL, callbackScheme: scheme)
        guard let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value else {
            throw GoogleOAuthError.missingAuthorizationCode
        }
        return AuthorizationResult(code: code, codeVerifier: pkce.verifier, redirectURI: redirectURI)
    }

    /// Presents the web authentication session and resumes with the callback URL.
    private func present(authURL: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: callbackScheme
            ) { callbackURL, error in
                if let error {
                    // Map the user dismissing the sheet to a clean cancellation.
                    if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                        continuation.resume(throwing: GoogleOAuthError.cancelled)
                    } else {
                        continuation.resume(throwing: error)
                    }
                    return
                }
                guard let callbackURL else {
                    continuation.resume(throwing: GoogleOAuthError.missingAuthorizationCode)
                    return
                }
                continuation.resume(returning: callbackURL)
            }
            session.presentationContextProvider = self
            // Use an ephemeral session is undesirable here (we want the user's
            // Google login), so keep the default shared cookie behavior.
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() {
                continuation.resume(throwing: GoogleOAuthError.tokenExchangeFailed("Could not start sign-in session."))
            }
        }
    }

    /// Supplies the window the system uses to anchor the auth sheet.
    public nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { Self.makePresentationAnchor() }
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated { Self.makePresentationAnchor() }
        }
    }

    @MainActor
    private static func makePresentationAnchor() -> ASPresentationAnchor {
        #if canImport(UIKit)
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        let window = scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
        return window ?? ASPresentationAnchor()
        #elseif canImport(AppKit)
        return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
        #else
        return ASPresentationAnchor()
        #endif
    }
}

extension Data {
    /// Base64url encoding (RFC 4648 §5): `+/` → `-_`, padding stripped.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
