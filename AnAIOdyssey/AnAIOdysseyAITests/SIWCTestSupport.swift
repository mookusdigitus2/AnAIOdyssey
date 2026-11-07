// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import XCTest
import AnAIOdysseyAI
import AnAIOdysseyCore
import AIModelOptions

/// URLProtocol stub for Sign in with ChatGPT tests. Records every request
/// (with its body) and answers from `handler`.
final class SIWCMockURLProtocol: URLProtocol {
    struct Reply {
        var status: Int
        var headers: [String: String] = [:]
        var body: Data
    }

    nonisolated(unsafe) static var handler: ((URLRequest, Data) -> Reply)?
    nonisolated(unsafe) private static var recorded: [(URLRequest, Data)] = []
    private static let lock = NSLock()

    static var requests: [(request: URLRequest, body: Data)] {
        lock.lock(); defer { lock.unlock() }
        return recorded.map { (request: $0.0, body: $0.1) }
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        recorded = []
        handler = nil
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SIWCMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.readBody(request)
        Self.lock.lock()
        Self.recorded.append((request, body))
        Self.lock.unlock()
        let reply = Self.handler?(request, body) ?? Reply(status: 404, body: Data(#"{"error":"unhandled"}"#.utf8))
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: reply.status,
            httpVersion: "HTTP/1.1",
            headerFields: reply.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

enum SIWCFixtures {
    static let issuedClientID = "oaiapp_test_client"
    static let fullScope = "chatgpt.tokens.use.direct email offline_access openid profile resource.invoke"

    static func unsignedJWT(_ claims: [String: Any]) -> String {
        func encode(_ object: [String: Any]) -> String {
            let data = try! JSONSerialization.data(withJSONObject: object)
            return ChatGPTOAuthCodec.base64URLEncode(data)
        }
        return encode(["alg": "RS256", "kid": "test"]) + "." + encode(claims) + ".sig"
    }

    static func idToken(nonce: String, audience: String = issuedClientID, subject: String = "user-sub-1", now: Date) -> String {
        unsignedJWT([
            "iss": "https://auth.openai.com",
            "aud": audience,
            "nonce": nonce,
            "exp": Int(now.timeIntervalSince1970) + 3600,
            "sub": subject,
            "email": "user@example.com",
        ])
    }

    static func tokenJSON(access: String, refresh: String?, idToken: String? = nil, scope: String? = fullScope) -> Data {
        var object: [String: Any] = [
            "access_token": access,
            "token_type": "Bearer",
            "expires_in": 3600,
        ]
        if let refresh { object["refresh_token"] = refresh }
        if let idToken { object["id_token"] = idToken }
        if let scope { object["scope"] = scope }
        return try! JSONSerialization.data(withJSONObject: object)
    }

    static func form(_ body: Data) -> [String: String] {
        let text = String(data: body, encoding: .utf8) ?? ""
        var fields: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            fields[parts[0].removingPercentEncoding ?? parts[0]] = parts[1].removingPercentEncoding ?? parts[1]
        }
        return fields
    }

    static func json(_ body: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
    }

    static func sse(_ events: [String]) -> Data {
        Data(events.map { "data: \($0)\n\n" }.joined().utf8)
    }

    static let helloStream = sse([
        #"{"type":"response.created","response":{"id":"resp_1"}}"#,
        #"{"type":"response.output_text.delta","delta":"Hel"}"#,
        #"{"type":"response.output_text.delta","delta":"lo"}"#,
        #"{"type":"response.completed","response":{"id":"resp_1","output":[]}}"#,
    ])

    static func credentials(
        access: String = "plan-token",
        refresh: String = "refresh-1",
        expiresAt: Date,
        scopes: [String] = ChatGPTOAuthCodec.parseScopeString(fullScope)
    ) -> ChatGPTStoredCredentials {
        ChatGPTStoredCredentials(
            email: "user@example.com",
            issuer: "https://auth.openai.com",
            subject: "user-sub-1",
            clientID: issuedClientID,
            extAgentHostID: "urn:uuid:00000000-0000-4000-8000-000000000000",
            idToken: "old-id-token",
            accessToken: access,
            refreshToken: refresh,
            tokenType: "Bearer",
            expiresAt: expiresAt,
            scopes: scopes,
            savedAt: expiresAt.addingTimeInterval(-3600)
        )
    }

    static func chatGPTConnection(id: String, model: String = "gpt-6.1-sol") -> RemoteConnection {
        var connection = RemoteConnection.chatGPTPreset()
        connection.id = id
        connection.defaultModel = model
        connection.availableModels = [model]
        connection.chatgptIssuedClientID = issuedClientID
        connection.chatgptEmail = "user@example.com"
        connection.chatgptSubject = "user-sub-1"
        connection.chatgptPlanEligible = true
        connection.isEnabled = true
        return connection
    }
}

/// Mutable clock for refresh tests.
final class SIWCClock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}
