// SPDX-License-Identifier: MIT
import Foundation

// Shared plumbing for "sign in with your subscription" providers.
//
// Sign in with ChatGPT (authorization code + PKCE + loopback) is wired up in
// `ChatGPTOAuthCodec` / `ChatGPTAccountService`. A device-code provider such as
// Grok plugs into the same token set, refresh classification, and API-key
// fallback policy below; only its client registration is still missing.

// MARK: - Token response and rotation

/// OAuth token-endpoint response (authorization code, refresh, or device grant).
public struct OAuthTokenResponse: Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var idToken: String?
    public var tokenType: String
    public var expiresIn: Int
    public var scope: String?

    public init(
        accessToken: String,
        refreshToken: String? = nil,
        idToken: String? = nil,
        tokenType: String = "Bearer",
        expiresIn: Int = 3600,
        scope: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.tokenType = tokenType
        self.expiresIn = expiresIn
        self.scope = scope
    }
}

/// Tokens for one signed-in subscription account. Stored in the Keychain.
public struct OAuthTokenSet: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var idToken: String?
    public var tokenType: String
    public var expiresAt: Date
    public var scopes: [String]
    public var savedAt: Date

    /// Refresh this long before expiry so a request never carries a dying token.
    public static let refreshMargin: TimeInterval = 60

    public init(
        accessToken: String,
        refreshToken: String?,
        idToken: String?,
        tokenType: String,
        expiresAt: Date,
        scopes: [String],
        savedAt: Date
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.tokenType = tokenType
        self.expiresAt = expiresAt
        self.scopes = scopes
        self.savedAt = savedAt
    }

    public init(response: OAuthTokenResponse, now: Date) {
        self.init(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken,
            idToken: response.idToken,
            tokenType: response.tokenType,
            expiresAt: now.addingTimeInterval(TimeInterval(response.expiresIn)),
            scopes: OAuthTokenCodec.parseScopeString(response.scope),
            savedAt: now
        )
    }

    public func needsRefresh(now: Date) -> Bool {
        expiresAt.timeIntervalSince(now) <= Self.refreshMargin
    }

    /// Replaces access token, rotating refresh token, expiry, and scopes together.
    public func applyingRefresh(_ response: OAuthTokenResponse, now: Date) -> OAuthTokenSet {
        var updated = self
        updated.accessToken = response.accessToken
        if let rotated = response.refreshToken, !rotated.isEmpty {
            updated.refreshToken = rotated
        }
        if let idToken = response.idToken, !idToken.isEmpty {
            updated.idToken = idToken
        }
        updated.tokenType = response.tokenType
        updated.expiresAt = now.addingTimeInterval(TimeInterval(response.expiresIn))
        if let scope = response.scope {
            updated.scopes = OAuthTokenCodec.parseScopeString(scope)
        }
        updated.savedAt = now
        return updated
    }
}

/// What to do after a refresh-token grant fails.
public enum OAuthRefreshFailureKind: Equatable, Sendable {
    /// The refresh token is unusable. Clear tokens and sign in again.
    case reauthenticate(String)
    /// Client registration is wrong; signing in again will not help.
    case invalidClient
    /// Network or server trouble. Keep credentials and retry later.
    case transient
}

public enum OAuthTokenCodec {
    /// Refresh error codes that mean the stored refresh token can never work again.
    public static let unusableRefreshTokenCodes: Set<String> = [
        "invalid_grant",
        "invalid_refresh_token",
        "token_expired",
        "refresh_token_expired",
        "refresh_token_invalidated",
        "refresh_token_reused",
    ]

    public static func parseTokenResponse(_ data: Data) throws -> OAuthTokenResponse {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ChatGPTOAuthCodecError.invalidTokenResponse
        }
        if let error = object["error"] as? String, !error.isEmpty {
            let description = object["error_description"] as? String
            throw ChatGPTOAuthCodecError.tokenEndpoint(error, description)
        }
        guard let accessToken = object["access_token"] as? String, !accessToken.isEmpty else {
            throw ChatGPTOAuthCodecError.invalidTokenResponse
        }
        let expiresIn: Int
        if let value = object["expires_in"] as? Int {
            expiresIn = value
        } else if let value = object["expires_in"] as? Double {
            expiresIn = Int(value)
        } else if let value = object["expires_in"] as? String, let parsed = Int(value) {
            expiresIn = parsed
        } else {
            expiresIn = 3600
        }
        return OAuthTokenResponse(
            accessToken: accessToken,
            refreshToken: object["refresh_token"] as? String,
            idToken: object["id_token"] as? String,
            tokenType: (object["token_type"] as? String) ?? "Bearer",
            expiresIn: expiresIn,
            scope: object["scope"] as? String
        )
    }

    /// Classifies a failed refresh. `statusCode == nil` means no HTTP response.
    public static func classifyRefreshFailure(statusCode: Int?, body: Data) -> OAuthRefreshFailureKind {
        guard let statusCode else { return .transient }
        let code = errorCode(in: body)
        if let code {
            if unusableRefreshTokenCodes.contains(code) { return .reauthenticate(code) }
            if code == "invalid_client" { return .invalidClient }
        }
        if statusCode >= 500 || statusCode == 429 { return .transient }
        if statusCode == 400 || statusCode == 401 {
            // An OAuth error without a known code still means the grant was refused.
            return code.map { .reauthenticate($0) } ?? .transient
        }
        return .transient
    }

    /// OAuth `error` (string) or nested `error.code`.
    public static func errorCode(in body: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return nil
        }
        if let error = object["error"] as? String, !error.isEmpty { return error }
        if let error = object["error"] as? [String: Any],
           let code = error["code"] as? String, !code.isEmpty {
            return code
        }
        return nil
    }

    public static func parseScopeString(_ scope: String?) -> [String] {
        guard let scope, !scope.isEmpty else { return [] }
        return scope
            .replacingOccurrences(of: "+", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }
    }
}

// MARK: - RFC 8628 device authorization

public struct DeviceAuthorization: Equatable, Sendable {
    public var deviceCode: String
    public var userCode: String
    public var verificationURI: URL
    public var verificationURIComplete: URL?
    public var interval: Int
    public var expiresAt: Date
}

public enum DevicePollOutcome: Equatable, Sendable {
    /// Keep polling after `interval` seconds.
    case pending(interval: Int)
    case tokens(OAuthTokenResponse)
    case expired
    case denied
    case failed(String)
}

public enum DeviceAuthorizationCodec {
    public static let grantType = "urn:ietf:params:oauth:grant-type:device_code"
    public static let defaultInterval = 5

    public static func deviceAuthorizationBody(clientID: String, scope: String) -> Data {
        ChatGPTOAuthCodec.formURLEncoded([
            ("client_id", clientID),
            ("scope", scope),
        ])
    }

    public static func parseDeviceAuthorization(_ data: Data, now: Date = Date()) throws -> DeviceAuthorization {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let deviceCode = object["device_code"] as? String, !deviceCode.isEmpty,
              let userCode = object["user_code"] as? String, !userCode.isEmpty,
              let verification = (object["verification_uri"] as? String) ?? (object["verification_url"] as? String),
              let verificationURI = URL(string: verification) else {
            throw ChatGPTOAuthCodecError.invalidTokenResponse
        }
        let complete = (object["verification_uri_complete"] as? String).flatMap(URL.init(string:))
        let interval = (object["interval"] as? Int) ?? defaultInterval
        let expiresIn = (object["expires_in"] as? Int) ?? 600
        return DeviceAuthorization(
            deviceCode: deviceCode,
            userCode: userCode,
            verificationURI: verificationURI,
            verificationURIComplete: complete,
            interval: max(interval, 1),
            expiresAt: now.addingTimeInterval(TimeInterval(expiresIn))
        )
    }

    public static func tokenPollBody(deviceCode: String, clientID: String) -> Data {
        ChatGPTOAuthCodec.formURLEncoded([
            ("grant_type", grantType),
            ("device_code", deviceCode),
            ("client_id", clientID),
        ])
    }

    public static func classifyPoll(statusCode: Int, body: Data, currentInterval: Int) -> DevicePollOutcome {
        if (200...299).contains(statusCode) {
            do {
                return .tokens(try OAuthTokenCodec.parseTokenResponse(body))
            } catch {
                return .failed(error.localizedDescription)
            }
        }
        switch OAuthTokenCodec.errorCode(in: body) {
        case "authorization_pending":
            return .pending(interval: currentInterval)
        case "slow_down":
            return .pending(interval: currentInterval + 5)
        case "expired_token":
            return .expired
        case "access_denied":
            return .denied
        case let code?:
            return .failed(code)
        case nil:
            return .failed("HTTP \(statusCode)")
        }
    }
}

/// Minimal OIDC discovery (`/.well-known/openid-configuration`).
public struct OIDCDiscoveryDocument: Equatable, Sendable {
    public var issuer: String
    public var tokenEndpoint: URL
    public var deviceAuthorizationEndpoint: URL?
    public var authorizationEndpoint: URL?

    public static func parse(_ data: Data) throws -> OIDCDiscoveryDocument {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let issuer = object["issuer"] as? String,
              let token = (object["token_endpoint"] as? String).flatMap(URL.init(string:)) else {
            throw ChatGPTOAuthCodecError.invalidTokenResponse
        }
        return OIDCDiscoveryDocument(
            issuer: issuer,
            tokenEndpoint: token,
            deviceAuthorizationEndpoint: (object["device_authorization_endpoint"] as? String).flatMap(URL.init(string:)),
            authorizationEndpoint: (object["authorization_endpoint"] as? String).flatMap(URL.init(string:))
        )
    }
}

/// xAI subscription sign-in (device code). Endpoints only: no client id ships
/// until the maintainer confirms using one. Construct with an explicit `clientID`.
public struct XAISubscriptionConfig: Equatable, Sendable {
    /// Intentionally nil. The only working id today is the Grok CLI's own.
    public static let bundledClientID: String? = nil

    public var clientID: String
    public var discoveryURL = URL(string: "https://auth.x.ai/.well-known/openid-configuration")!
    public var deviceAuthorizationEndpoint = URL(string: "https://auth.x.ai/oauth2/device/code")!
    public var scope = "openid profile email offline_access grok-cli:access api:access"
    public var apiBaseURL = "https://api.x.ai/v1"

    public init(clientID: String) {
        self.clientID = clientID
    }

    public func deviceAuthorizationBody() -> Data {
        DeviceAuthorizationCodec.deviceAuthorizationBody(clientID: clientID, scope: scope)
    }

    public func tokenPollBody(deviceCode: String) -> Data {
        DeviceAuthorizationCodec.tokenPollBody(deviceCode: deviceCode, clientID: clientID)
    }
}

// MARK: - Billing errors and API-key fallback

public enum SubscriptionBillingErrorKind: Equatable, Sendable {
    /// Plan usage is not available for this account. Use the API key instead.
    case notEligible
    /// Plan or app usage limit reached. Point to Manage usage; do not switch billing.
    case usageLimit
    /// Retry later with backoff; keep credentials.
    case temporarilyUnavailable
    /// The request used a field, tool, or model the plan route does not support.
    case unsupportedCapability(String?)
    /// Signed identity was not accepted. Sign in again after confirming.
    case reauthenticate
    /// Policy, region, or route restriction.
    case permission
    case other
}

public struct SubscriptionBillingError: Error, Equatable, Sendable, LocalizedError {
    public var kind: SubscriptionBillingErrorKind
    public var statusCode: Int
    public var code: String?
    public var message: String?
    public var requestID: String?
    public var providerName: String

    public var fallsBackToAPIKey: Bool { kind == .notEligible }

    public var userMessage: String {
        let manage = "Manage usage: \(SubscriptionBillingPolicy.chatGPTManageUsageURL.absoluteString)"
        let detail = message.map { " (\($0))" } ?? ""
        switch kind {
        case .notEligible:
            return providerName == "ChatGPT"
                ? "Your ChatGPT account can’t use its plan in \(ChatGPTOAuthCodec.agentNameHint). ChatGPT Plus or Pro is required."
                : "Your \(providerName) subscription doesn’t include API access for \(ChatGPTOAuthCodec.agentNameHint)."
        case .usageLimit:
            return "\(providerName) usage limit reached. Review your plan or this app’s limit in ChatGPT settings. \(manage)"
        case .temporarilyUnavailable:
            return "\(providerName) plan usage is temporarily unavailable. Try again in a moment."
        case .unsupportedCapability(let param):
            let what = param.map { "“\($0)”" } ?? "part of this request"
            return "\(providerName) plan usage doesn’t support \(what). Choose another model or turn that option off."
        case .reauthenticate:
            return "\(providerName) didn’t accept this sign-in. Sign in again.\(detail)"
        case .permission:
            return "\(providerName) refused this request\(detail). Check your account’s region and settings."
        case .other:
            return "\(providerName) request failed (HTTP \(statusCode))\(detail)."
        }
    }

    public var errorDescription: String? {
        if let requestID, !requestID.isEmpty {
            return "\(userMessage) Request ID: \(requestID)."
        }
        return userMessage
    }
}

public enum SubscriptionBillingPolicy {
    public static let chatGPTManageUsageURL = URL(string: "https://chatgpt.com/settings/usage")!

    /// Message for the API-key fallback after a not-eligible response.
    public static func fallbackNotice(providerName: String = "ChatGPT", hasAPIKey: Bool) -> String {
        if hasAPIKey {
            return "\(providerName) plan usage isn’t available for this account (Plus or Pro required), so \(ChatGPTOAuthCodec.agentNameHint) is using your OpenAI API key instead."
        }
        return "\(providerName) plan usage isn’t available for this account (Plus or Pro required). Add an OpenAI API key in Settings → AI Models to keep chatting."
    }

    /// Classifies a ChatGPT plan HTTP error before or instead of a stream.
    public static func classifyChatGPT(statusCode: Int, body: Data, requestID: String? = nil) -> SubscriptionBillingError {
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let errorObject = (object["error"] as? [String: Any])
            ?? ((object["response"] as? [String: Any])?["error"] as? [String: Any])
        let code = errorObject?["code"] as? String
        let param = errorObject?["param"] as? String
        let message = (errorObject?["message"] as? String)
            ?? (object["detail"] as? String)
            ?? (object["error"] as? String)
        return SubscriptionBillingError(
            kind: chatGPTKind(statusCode: statusCode, code: code, param: param),
            statusCode: statusCode,
            code: code,
            message: message,
            requestID: requestID,
            providerName: "ChatGPT"
        )
    }

    /// `response.failed` / `error` stream events carrying a plan error code.
    public static func chatGPTStreamError(fromEventJSON json: String) -> SubscriptionBillingError? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let type = object["type"] as? String ?? ""
        guard type == "response.failed" || type == "error" || type == "response.error" else { return nil }
        let errorObject = (object["error"] as? [String: Any])
            ?? ((object["response"] as? [String: Any])?["error"] as? [String: Any])
            ?? (type == "error" ? object : nil)
        guard let code = errorObject?["code"] as? String, code.hasPrefix("subscription_sharing") || code.hasPrefix("chatpass") else {
            return nil
        }
        let status: Int
        switch code {
        case "subscription_sharing_usage_limit_exceeded": status = 429
        case "subscription_sharing_user_not_eligible": status = 403
        case "subscription_sharing_invalid_user": status = 401
        default: status = 503
        }
        return SubscriptionBillingError(
            kind: chatGPTKind(statusCode: status, code: code, param: errorObject?["param"] as? String),
            statusCode: status,
            code: code,
            message: errorObject?["message"] as? String,
            requestID: nil,
            providerName: "ChatGPT"
        )
    }

    /// Device-code subscriptions (Grok): 402/403 mean "no entitlement", so use the API key.
    public static func classifyEntitlement(
        statusCode: Int,
        body: Data,
        providerName: String = "Grok"
    ) -> SubscriptionBillingError {
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let message = ((object["error"] as? [String: Any])?["message"] as? String)
            ?? (object["error"] as? String)
            ?? (object["detail"] as? String)
        let kind: SubscriptionBillingErrorKind
        switch statusCode {
        case 402, 403: kind = .notEligible
        case 401: kind = .reauthenticate
        case 429: kind = .usageLimit
        case 500...599: kind = .temporarilyUnavailable
        default: kind = .other
        }
        return SubscriptionBillingError(
            kind: kind,
            statusCode: statusCode,
            code: nil,
            message: message,
            requestID: nil,
            providerName: providerName
        )
    }

    private static func chatGPTKind(statusCode: Int, code: String?, param: String?) -> SubscriptionBillingErrorKind {
        switch code {
        case "subscription_sharing_user_not_eligible":
            return .notEligible
        case "subscription_sharing_usage_limit_exceeded":
            return .usageLimit
        case "subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable":
            return .temporarilyUnavailable
        case "subscription_sharing_unsupported_capability":
            return .unsupportedCapability(param)
        case "subscription_sharing_invalid_user":
            return .reauthenticate
        case "subscription_sharing_route_not_supported",
             "chatpass_v2_scope_not_authorized",
             "chatpass_v2_invalid_authorization_context":
            return .permission
        default:
            switch statusCode {
            case 401: return .reauthenticate
            case 403: return .permission
            case 429: return .usageLimit
            case 503: return .temporarilyUnavailable
            default: return .other
            }
        }
    }
}
