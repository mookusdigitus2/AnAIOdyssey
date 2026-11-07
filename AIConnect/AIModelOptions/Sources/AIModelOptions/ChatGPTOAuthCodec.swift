// SPDX-License-Identifier: MIT
import Foundation

/// Open-source Sign in with ChatGPT (OAuth 2.0 Authorization Code + PKCE + OIDC).
///
/// Encoding and eligibility live here so Linux tests can cover the request
/// contract without a browser, Keychain, or Apple frameworks. Interactive
/// sign-in, loopback, and JWKS verification stay in `ChatGPTAccountService`.
public enum ChatGPTOAuthCodec {
    public static let authorizationEndpoint = URL(string: "https://auth.openai.com/api/accounts/authorize")!
    public static let tokenEndpoint = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
    public static let revocationEndpoint = URL(string: "https://auth.openai.com/api/accounts/oauth/revoke")!
    public static let jwksURL = URL(string: "https://auth.openai.com/.well-known/jwks.json")!
    public static let issuer = "https://auth.openai.com"
    public static let resource = "https://api.openai.com/v1"
    public static let dynamicClientID = "dynamic_agent_client"
    public static let agentNameHint = "An AI Odyssey"
    public static let callbackPath = "/auth/callback"
    public static let planUsageScope = "chatgpt.tokens.use.direct"
    public static let requestedScope = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"

    /// Shown when identity succeeded but `chatgpt.tokens.use.direct` was not granted.
    public static let ineligibleUserMessage =
        "This ChatGPT account isn’t eligible for plan usage. ChatGPT Plus or Pro is required. Add an API key, or use a local model where this device supports one."

    public static let iOSUnsupportedMessage =
        "Continue with ChatGPT couldn’t start its sign-in page on this device. Add an API key or another provider below."

    /// UI/UX guidelines: settings offer copy.
    public static let planOfferTitle = "Use your ChatGPT plan"
    public static let planCaption =
        "Complete eligible AI requests in this app with usage included in your ChatGPT plan or credits balance."
    public static let planInUseLabel = "Using ChatGPT plan"
    public static let planNoticeTitle = "You’re using your ChatGPT plan"
    public static let planNoticeMessage =
        "Eligible usage in this app uses your ChatGPT plan. Manage usage in your ChatGPT settings."
    public static let manageUsageURL = URL(string: "https://chatgpt.com/settings/usage")!

    public static func redirectURI(port: UInt16) -> String {
        "http://127.0.0.1:\(port)\(callbackPath)"
    }

    /// PKCE S256 challenge: base64url(SHA-256(verifier)) with no padding.
    public static func pkceChallenge(
        verifier: String,
        sha256: (Data) -> Data = { PortableSHA256.hash($0) }
    ) -> String {
        base64URLEncode(sha256(Data(verifier.utf8)))
    }

    public static func makePKCEVerifier(randomBytes: [UInt8]? = nil) -> String {
        let bytes: [UInt8]
        if let randomBytes {
            bytes = randomBytes
        } else {
            var generated = [UInt8](repeating: 0, count: 32)
            for index in generated.indices {
                generated[index] = UInt8.random(in: 0...255)
            }
            bytes = generated
        }
        return base64URLEncode(Data(bytes))
    }

    public static func makeRandomState(randomBytes: [UInt8]? = nil) -> String {
        makePKCEVerifier(randomBytes: randomBytes)
    }

    public static func authorizationURL(
        clientID: String,
        redirectURI: String,
        state: String,
        nonce: String,
        codeChallenge: String,
        extAgentHostID: String,
        agentNameHint: String? = Self.agentNameHint,
        loginHint: String? = nil,
        idTokenHint: String? = nil,
        prompt: String? = nil
    ) -> URL {
        var items: [(String, String)] = [
            ("client_id", clientID),
            ("response_type", "code"),
            ("redirect_uri", redirectURI),
            ("scope", requestedScope),
            ("resource", resource),
            ("state", state),
            ("nonce", nonce),
            ("code_challenge_method", "S256"),
            ("code_challenge", codeChallenge),
            ("ext_agent_host_id", extAgentHostID),
        ]
        let isFirstRegistration = clientID == dynamicClientID
        if isFirstRegistration, let agentNameHint, !agentNameHint.isEmpty {
            items.append(("agent_name_hint", agentNameHint))
        }
        if let loginHint, !loginHint.isEmpty {
            items.append(("login_hint", loginHint))
        }
        if let idTokenHint, !idTokenHint.isEmpty {
            items.append(("id_token_hint", idTokenHint))
        }
        // `prompt=consent` re-asks for plan permission after an earlier decline.
        // Never sent on ordinary sign-ins.
        if let prompt, !prompt.isEmpty {
            items.append(("prompt", prompt))
        }

        var encoded: [String] = []
        encoded.reserveCapacity(items.count)
        for (key, value) in items {
            encoded.append("\(percentEncode(key))=\(percentEncode(value))")
        }
        let urlString = authorizationEndpoint.absoluteString + "?" + encoded.joined(separator: "&")
        return URL(string: urlString)!
    }

    public static func tokenExchangeBody(
        code: String,
        clientID: String,
        codeVerifier: String,
        redirectURI: String
    ) -> Data {
        formURLEncoded([
            ("grant_type", "authorization_code"),
            ("client_id", clientID),
            ("code", code),
            ("code_verifier", codeVerifier),
            ("redirect_uri", redirectURI),
            ("resource", resource),
        ])
    }

    /// Refresh omits `scope` (OpenAI rotates refresh tokens). No client secret.
    public static func refreshTokenBody(refreshToken: String, clientID: String) -> Data {
        formURLEncoded([
            ("grant_type", "refresh_token"),
            ("client_id", clientID),
            ("refresh_token", refreshToken),
            ("resource", resource),
        ])
    }

    public static func revokeBody(token: String, clientID: String) -> Data {
        formURLEncoded([
            ("token", token),
            ("client_id", clientID),
        ])
    }

    public static func formURLEncoded(_ pairs: [(String, String)]) -> Data {
        let query = pairs.map { key, value in
            "\(percentEncode(key))=\(percentEncode(value))"
        }.joined(separator: "&")
        return Data(query.utf8)
    }

    public static func percentEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    public static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func parseCallbackQuery(_ queryItems: [URLQueryItem]) throws -> ChatGPTAuthorizationCallback {
        if let error = queryItems.first(where: { $0.name == "error" })?.value, !error.isEmpty {
            let description = queryItems.first(where: { $0.name == "error_description" })?.value
            throw ChatGPTOAuthCodecError.authorization(error, description)
        }
        guard let state = queryItems.first(where: { $0.name == "state" })?.value, !state.isEmpty else {
            throw ChatGPTOAuthCodecError.missingCallbackField("state")
        }
        guard let code = queryItems.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw ChatGPTOAuthCodecError.missingCallbackField("code")
        }
        let clientID = queryItems.first(where: { $0.name == "client_id" })?.value
        let scope = queryItems.first(where: { $0.name == "scope" })?.value
        return ChatGPTAuthorizationCallback(
            code: code,
            state: state,
            issuedClientID: clientID,
            scope: scope
        )
    }

    public static func parseCallbackURL(_ url: URL) throws -> ChatGPTAuthorizationCallback {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            ?? URLComponents(string: url.absoluteString)?.queryItems
            ?? []
        return try parseCallbackQuery(items)
    }

    /// Issued `oaiapp_…` client id. Never persist `dynamic_agent_client`.
    public static func resolvedIssuedClientID(
        callbackClientID: String?,
        pendingClientID: String
    ) throws -> String {
        let callback = callbackClientID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !callback.isEmpty {
            if callback == dynamicClientID {
                throw ChatGPTOAuthCodecError.incompleteRegistration
            }
            if pendingClientID != dynamicClientID, pendingClientID != callback {
                throw ChatGPTOAuthCodecError.clientIDMismatch
            }
            return callback
        }
        if pendingClientID == dynamicClientID || pendingClientID.isEmpty {
            throw ChatGPTOAuthCodecError.incompleteRegistration
        }
        return pendingClientID
    }

    public static func parseScopeString(_ scope: String?) -> [String] {
        OAuthTokenCodec.parseScopeString(scope)
    }

    public static func isPlanEligible(grantedScopes: [String]) -> Bool {
        grantedScopes.contains(planUsageScope)
    }

    public static func parseTokenResponse(_ data: Data) throws -> ChatGPTTokenResponse {
        try OAuthTokenCodec.parseTokenResponse(data)
    }

    public static func decodeJWTPayload(_ jwt: String) throws -> [String: Any] {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { throw ChatGPTOAuthCodecError.invalidIDToken }
        guard let data = base64URLDecode(String(parts[1])),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ChatGPTOAuthCodecError.invalidIDToken
        }
        return object
    }

    public static func decodeJWTHeader(_ jwt: String) throws -> [String: Any] {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { throw ChatGPTOAuthCodecError.invalidIDToken }
        guard let data = base64URLDecode(String(parts[0])),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ChatGPTOAuthCodecError.invalidIDToken
        }
        return object
    }

    public static func validateIDTokenClaims(
        _ jwt: String,
        issuedClientID: String,
        nonce: String,
        now: Date = Date()
    ) throws -> ChatGPTIdentity {
        let claims = try decodeJWTPayload(jwt)
        let iss = claims["iss"] as? String ?? ""
        guard iss == issuer || iss == issuer + "/" else {
            throw ChatGPTOAuthCodecError.invalidIDTokenClaims("issuer")
        }
        let audienceMatches: Bool
        if let aud = claims["aud"] as? String {
            audienceMatches = aud == issuedClientID
        } else if let aud = claims["aud"] as? [String] {
            audienceMatches = aud.contains(issuedClientID)
        } else {
            audienceMatches = false
        }
        guard audienceMatches else {
            throw ChatGPTOAuthCodecError.invalidIDTokenClaims("audience")
        }
        let tokenNonce = claims["nonce"] as? String ?? ""
        guard tokenNonce == nonce else {
            throw ChatGPTOAuthCodecError.invalidIDTokenClaims("nonce")
        }
        let exp: TimeInterval
        if let value = claims["exp"] as? TimeInterval {
            exp = value
        } else if let value = claims["exp"] as? Int {
            exp = TimeInterval(value)
        } else {
            throw ChatGPTOAuthCodecError.invalidIDTokenClaims("exp")
        }
        guard Date(timeIntervalSince1970: exp) > now else {
            throw ChatGPTOAuthCodecError.invalidIDTokenClaims("expired")
        }
        guard let sub = claims["sub"] as? String, !sub.isEmpty else {
            throw ChatGPTOAuthCodecError.invalidIDTokenClaims("sub")
        }
        return ChatGPTIdentity(
            subject: sub,
            email: claims["email"] as? String,
            name: claims["name"] as? String,
            issuer: iss
        )
    }

    public static func makeHostID(uuid: UUID = UUID()) -> String {
        "urn:uuid:\(uuid.uuidString.lowercased())"
    }

    public static func base64URLDecode(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: base64)
    }
}

public struct ChatGPTAuthorizationCallback: Equatable, Sendable {
    public var code: String
    public var state: String
    public var issuedClientID: String?
    public var scope: String?

    public init(code: String, state: String, issuedClientID: String? = nil, scope: String? = nil) {
        self.code = code
        self.state = state
        self.issuedClientID = issuedClientID
        self.scope = scope
    }
}

/// Kept for existing call sites; the shape is shared with every OAuth provider.
public typealias ChatGPTTokenResponse = OAuthTokenResponse

public struct ChatGPTIdentity: Equatable, Sendable {
    public var subject: String
    public var email: String?
    public var name: String?
    public var issuer: String

    public init(subject: String, email: String? = nil, name: String? = nil, issuer: String = ChatGPTOAuthCodec.issuer) {
        self.subject = subject
        self.email = email
        self.name = name
        self.issuer = issuer
    }
}

public enum ChatGPTOAuthCodecError: Error, Equatable, LocalizedError {
    case authorization(String, String?)
    case missingCallbackField(String)
    case incompleteRegistration
    case clientIDMismatch
    case invalidTokenResponse
    case tokenEndpoint(String, String?)
    case invalidIDToken
    case invalidIDTokenClaims(String)

    public var errorDescription: String? {
        switch self {
        case .authorization("access_denied", _):
            return ChatGPTOAuthCodec.ineligibleUserMessage
        case .authorization(let error, let description):
            return description ?? "ChatGPT authorization failed (\(error))."
        case .missingCallbackField(let field):
            return "ChatGPT callback was missing \(field)."
        case .incompleteRegistration:
            return "ChatGPT did not issue a client ID. Sign in again to finish registration."
        case .clientIDMismatch:
            return "ChatGPT returned a different client ID than this saved account."
        case .invalidTokenResponse:
            return "ChatGPT token response was invalid."
        case .tokenEndpoint(let error, let description):
            return description ?? "ChatGPT token exchange failed (\(error))."
        case .invalidIDToken:
            return "ChatGPT ID token was invalid."
        case .invalidIDTokenClaims(let field):
            return "ChatGPT ID token failed \(field) validation."
        }
    }
}

/// SHA-256 used for PKCE on every platform, including Linux (no CryptoKit).
public enum PortableSHA256 {
    public static func hash(_ data: Data) -> Data {
        var bytes = [UInt8](data)
        let bitLength = UInt64(bytes.count) * 8
        bytes.append(0x80)
        while (bytes.count % 64) != 56 {
            bytes.append(0)
        }
        var lengthBytes = [UInt8](repeating: 0, count: 8)
        for index in 0..<8 {
            lengthBytes[7 - index] = UInt8((bitLength >> (UInt64(index) * 8)) & 0xff)
        }
        bytes.append(contentsOf: lengthBytes)

        var h0: UInt32 = 0x6a09e667
        var h1: UInt32 = 0xbb67ae85
        var h2: UInt32 = 0x3c6ef372
        var h3: UInt32 = 0xa54ff53a
        var h4: UInt32 = 0x510e527f
        var h5: UInt32 = 0x9b05688c
        var h6: UInt32 = 0x1f83d9ab
        var h7: UInt32 = 0x5be0cd19
        let k: [UInt32] = [
            0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
            0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
            0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
            0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
            0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
            0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
            0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
            0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
        ]

        var offset = 0
        while offset < bytes.count {
            var w = [UInt32](repeating: 0, count: 64)
            for i in 0..<16 {
                let base = offset + i * 4
                w[i] = (UInt32(bytes[base]) << 24)
                    | (UInt32(bytes[base + 1]) << 16)
                    | (UInt32(bytes[base + 2]) << 8)
                    | UInt32(bytes[base + 3])
            }
            for i in 16..<64 {
                let s0 = rotateRight(w[i - 15], 7) ^ rotateRight(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotateRight(w[i - 2], 17) ^ rotateRight(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }

            var a = h0, b = h1, c = h2, d = h3, e = h4, f = h5, g = h6, h = h7
            for i in 0..<64 {
                let s1 = rotateRight(e, 6) ^ rotateRight(e, 11) ^ rotateRight(e, 25)
                let ch = (e & f) ^ (~e & g)
                let temp1 = h &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotateRight(a, 2) ^ rotateRight(a, 13) ^ rotateRight(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ maj
                h = g
                g = f
                f = e
                e = d &+ temp1
                d = c
                c = b
                b = a
                a = temp1 &+ temp2
            }
            h0 = h0 &+ a
            h1 = h1 &+ b
            h2 = h2 &+ c
            h3 = h3 &+ d
            h4 = h4 &+ e
            h5 = h5 &+ f
            h6 = h6 &+ g
            h7 = h7 &+ h
            offset += 64
        }

        var digest = Data(count: 32)
        digest.withUnsafeMutableBytes { raw in
            let buffer = raw.bindMemory(to: UInt8.self)
            writeUInt32(h0, into: buffer, at: 0)
            writeUInt32(h1, into: buffer, at: 4)
            writeUInt32(h2, into: buffer, at: 8)
            writeUInt32(h3, into: buffer, at: 12)
            writeUInt32(h4, into: buffer, at: 16)
            writeUInt32(h5, into: buffer, at: 20)
            writeUInt32(h6, into: buffer, at: 24)
            writeUInt32(h7, into: buffer, at: 28)
        }
        return digest
    }

    private static func rotateRight(_ value: UInt32, _ amount: UInt32) -> UInt32 {
        (value >> amount) | (value << (32 - amount))
    }

    private static func writeUInt32(_ value: UInt32, into buffer: UnsafeMutableBufferPointer<UInt8>, at offset: Int) {
        buffer[offset] = UInt8((value >> 24) & 0xff)
        buffer[offset + 1] = UInt8((value >> 16) & 0xff)
        buffer[offset + 2] = UInt8((value >> 8) & 0xff)
        buffer[offset + 3] = UInt8(value & 0xff)
    }
}
