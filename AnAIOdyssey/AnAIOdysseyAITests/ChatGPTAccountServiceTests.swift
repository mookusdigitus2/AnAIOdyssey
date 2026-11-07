// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import XCTest
import AnAIOdysseyAI
import AnAIOdysseyCore
import AIModelOptions

/// Sign in with ChatGPT: authorization request, code exchange, scope check,
/// Keychain-style storage, and refresh-token rotation (mocked URLProtocol).
@MainActor
final class ChatGPTAccountServiceTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var store: InMemoryTokenSecureStore!
    private var providerSettings: ProviderSettings!
    private var clock: SIWCClock!

    override func setUp() async throws {
        suiteName = "siwc-account-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = InMemoryTokenSecureStore()
        providerSettings = ProviderSettings(
            defaults: defaults,
            apiKeyStore: RemoteAPIKeyStore(defaults: defaults, secureStore: InMemoryTokenSecureStore())
        )
        providerSettings.remoteConnections = []
        clock = SIWCClock(Date(timeIntervalSince1970: 1_800_000_000))
        SIWCMockURLProtocol.reset()
    }

    override func tearDown() async throws {
        SIWCMockURLProtocol.reset()
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeService() -> ChatGPTAccountService {
        let clock = self.clock!
        return ChatGPTAccountService(
            defaults: defaults,
            secureStore: store,
            session: SIWCMockURLProtocol.makeSession(),
            now: { clock.now },
            verifySignatures: false
        )
    }

    // MARK: Authorization request

    func testFirstAuthorizationUsesDynamicClientAndStableHostID() throws {
        let service = makeService()
        let pending = service.beginAuthorization(
            redirectURI: ChatGPTOAuthCodec.redirectURI(port: 1455),
            existingConnectionID: nil,
            providerSettings: providerSettings
        )
        XCTAssertEqual(pending.clientID, ChatGPTOAuthCodec.dynamicClientID)
        let items = Dictionary(
            uniqueKeysWithValues: (URLComponents(url: pending.authorizationURL, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                .map { ($0.name, $0.value ?? "") }
        )
        XCTAssertEqual(items["client_id"], "dynamic_agent_client")
        XCTAssertEqual(items["agent_name_hint"], "An AI Odyssey")
        XCTAssertEqual(items["redirect_uri"], "http://127.0.0.1:1455/auth/callback")
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["code_challenge"], ChatGPTOAuthCodec.pkceChallenge(verifier: pending.codeVerifier))
        XCTAssertEqual(items["state"], pending.state)
        XCTAssertEqual(items["nonce"], pending.nonce)
        XCTAssertEqual(items["resource"], "https://api.openai.com/v1")
        XCTAssertEqual(items["scope"], "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct")
        let hostID = try XCTUnwrap(items["ext_agent_host_id"])
        XCTAssertTrue(hostID.hasPrefix("urn:uuid:"))
        XCTAssertNil(items["prompt"])

        let second = service.beginAuthorization(
            redirectURI: ChatGPTOAuthCodec.redirectURI(port: 1456),
            existingConnectionID: nil,
            providerSettings: providerSettings
        )
        XCTAssertNotEqual(second.state, pending.state, "Fresh state per attempt")
        XCTAssertNotEqual(second.codeVerifier, pending.codeVerifier, "Fresh PKCE per attempt")
        XCTAssertTrue(second.authorizationURL.absoluteString.contains(ChatGPTOAuthCodec.percentEncode(hostID)), "Same host id")
    }

    func testReauthorizationUsesSavedClientIDAndCanRequestConsent() throws {
        let service = makeService()
        let connection = SIWCFixtures.chatGPTConnection(id: "cg-reauth")
        providerSettings.updateConnection(connection)
        let pending = service.beginAuthorization(
            redirectURI: ChatGPTOAuthCodec.redirectURI(port: 1455),
            existingConnectionID: connection.id,
            providerSettings: providerSettings,
            requestPlanConsent: true
        )
        XCTAssertEqual(pending.clientID, SIWCFixtures.issuedClientID)
        let url = pending.authorizationURL.absoluteString
        XCTAssertFalse(url.contains("agent_name_hint"))
        XCTAssertTrue(url.contains("prompt=consent"))
        XCTAssertTrue(url.contains("login_hint=user%40example.com"))
    }

    // MARK: Code exchange

    func testCompleteAuthorizationExchangesCodeAndPersistsIssuedClient() async throws {
        let service = makeService()
        let pending = service.beginAuthorization(
            redirectURI: ChatGPTOAuthCodec.redirectURI(port: 1455),
            existingConnectionID: nil,
            providerSettings: providerSettings
        )
        let now = clock.now
        SIWCMockURLProtocol.handler = { request, _ in
            XCTAssertEqual(request.url?.absoluteString, "https://auth.openai.com/api/accounts/oauth/token")
            return .init(status: 200, body: SIWCFixtures.tokenJSON(
                access: "access-1",
                refresh: "refresh-1",
                idToken: SIWCFixtures.idToken(nonce: pending.nonce, now: now)
            ))
        }
        let callback = ChatGPTAuthorizationCallback(
            code: "auth-code",
            state: pending.state,
            issuedClientID: SIWCFixtures.issuedClientID,
            scope: SIWCFixtures.fullScope
        )
        let connection = try await service.completeAuthorization(callback, pending: pending, into: providerSettings)

        XCTAssertEqual(connection.chatgptIssuedClientID, SIWCFixtures.issuedClientID)
        XCTAssertEqual(connection.chatgptPlanEligible, true)
        XCTAssertEqual(connection.chatgptEmail, "user@example.com")
        XCTAssertTrue(connection.apiKey.isEmpty)
        XCTAssertNotNil(providerSettings.connection(id: connection.id))

        let stored = try XCTUnwrap(service.credentials(for: connection.id))
        XCTAssertEqual(stored.accessToken, "access-1")
        XCTAssertEqual(stored.refreshToken, "refresh-1")
        XCTAssertEqual(stored.clientID, SIWCFixtures.issuedClientID)
        XCTAssertTrue(stored.isPlanEligible)
        XCTAssertEqual(stored.expiresAt, now.addingTimeInterval(3600))

        let exchange = try XCTUnwrap(SIWCMockURLProtocol.requests.first)
        XCTAssertEqual(exchange.request.httpMethod, "POST")
        XCTAssertEqual(exchange.request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        let form = SIWCFixtures.form(exchange.body)
        XCTAssertEqual(form["grant_type"], "authorization_code")
        XCTAssertEqual(form["client_id"], SIWCFixtures.issuedClientID, "Exchange uses the issued id, not dynamic_agent_client")
        XCTAssertEqual(form["code"], "auth-code")
        XCTAssertEqual(form["code_verifier"], pending.codeVerifier)
        XCTAssertEqual(form["redirect_uri"], pending.redirectURI)
        XCTAssertEqual(form["resource"], "https://api.openai.com/v1")
        XCTAssertNil(form["client_secret"])

        XCTAssertTrue(service.showsPlanNotice, "First plan sign-in shows the one-time notice")
        service.acknowledgePlanNotice()
        XCTAssertFalse(service.showsPlanNotice)
    }

    func testPlanNoticeIsShownOnlyOnce() async throws {
        let service = makeService()
        service.acknowledgePlanNotice()
        let pending = service.beginAuthorization(
            redirectURI: ChatGPTOAuthCodec.redirectURI(port: 1455),
            existingConnectionID: nil,
            providerSettings: providerSettings
        )
        let now = clock.now
        SIWCMockURLProtocol.handler = { _, _ in
            .init(status: 200, body: SIWCFixtures.tokenJSON(
                access: "a", refresh: "r", idToken: SIWCFixtures.idToken(nonce: pending.nonce, now: now)
            ))
        }
        _ = try await service.completeAuthorization(
            ChatGPTAuthorizationCallback(code: "c", state: pending.state, issuedClientID: SIWCFixtures.issuedClientID),
            pending: pending,
            into: providerSettings
        )
        XCTAssertFalse(service.showsPlanNotice)
    }

    func testMissingPlanScopeKeepsSignInButDisablesPlanUsage() async throws {
        let service = makeService()
        let pending = service.beginAuthorization(
            redirectURI: ChatGPTOAuthCodec.redirectURI(port: 1455),
            existingConnectionID: nil,
            providerSettings: providerSettings
        )
        let now = clock.now
        SIWCMockURLProtocol.handler = { _, _ in
            .init(status: 200, body: SIWCFixtures.tokenJSON(
                access: "a", refresh: "r",
                idToken: SIWCFixtures.idToken(nonce: pending.nonce, now: now),
                scope: "openid profile email offline_access"
            ))
        }
        do {
            _ = try await service.completeAuthorization(
                ChatGPTAuthorizationCallback(code: "c", state: pending.state, issuedClientID: SIWCFixtures.issuedClientID),
                pending: pending,
                into: providerSettings
            )
            XCTFail("Expected ineligible")
        } catch ChatGPTAccountError.ineligible {
            // expected
        }
        let connection = try XCTUnwrap(providerSettings.remoteConnections.first)
        XCTAssertEqual(connection.chatgptPlanEligible, false)
        XCTAssertFalse(providerSettings.adapter(for: connection).isConfigured(connection: connection))
        XCTAssertNotNil(service.credentials(for: connection.id), "Sign-in is retained so plan use can be enabled later")
        XCTAssertFalse(service.showsPlanNotice)
    }

    func testStateMismatchStopsBeforeExchange() async {
        let service = makeService()
        let pending = service.beginAuthorization(
            redirectURI: ChatGPTOAuthCodec.redirectURI(port: 1455),
            existingConnectionID: nil,
            providerSettings: providerSettings
        )
        do {
            _ = try await service.completeAuthorization(
                ChatGPTAuthorizationCallback(code: "c", state: "forged", issuedClientID: SIWCFixtures.issuedClientID),
                pending: pending,
                into: providerSettings
            )
            XCTFail("Expected state mismatch")
        } catch {
            XCTAssertEqual(error as? ChatGPTAccountError, .stateMismatch)
        }
        XCTAssertTrue(SIWCMockURLProtocol.requests.isEmpty)
        XCTAssertTrue(providerSettings.remoteConnections.isEmpty)
    }

    func testWrongNonceIsRejected() async {
        let service = makeService()
        let pending = service.beginAuthorization(
            redirectURI: ChatGPTOAuthCodec.redirectURI(port: 1455),
            existingConnectionID: nil,
            providerSettings: providerSettings
        )
        let now = clock.now
        SIWCMockURLProtocol.handler = { _, _ in
            .init(status: 200, body: SIWCFixtures.tokenJSON(
                access: "a", refresh: "r", idToken: SIWCFixtures.idToken(nonce: "other", now: now)
            ))
        }
        do {
            _ = try await service.completeAuthorization(
                ChatGPTAuthorizationCallback(code: "c", state: pending.state, issuedClientID: SIWCFixtures.issuedClientID),
                pending: pending,
                into: providerSettings
            )
            XCTFail("Expected nonce failure")
        } catch {
            XCTAssertEqual(error as? ChatGPTOAuthCodecError, .invalidIDTokenClaims("nonce"))
        }
        XCTAssertTrue(providerSettings.remoteConnections.isEmpty)
    }

    // MARK: Refresh rotation

    func testRefreshRotatesAndSavesEveryNewRefreshToken() async throws {
        let service = makeService()
        let connection = SIWCFixtures.chatGPTConnection(id: "cg-refresh")
        providerSettings.updateConnection(connection)
        try service.saveCredentials(
            SIWCFixtures.credentials(access: "expired", refresh: "refresh-1", expiresAt: clock.now.addingTimeInterval(-10)),
            connectionID: connection.id
        )
        var counter = 1
        SIWCMockURLProtocol.handler = { _, _ in
            counter += 1
            return .init(status: 200, body: SIWCFixtures.tokenJSON(access: "access-\(counter)", refresh: "refresh-\(counter)"))
        }

        let first = try await service.validAccessToken(for: connection)
        XCTAssertEqual(first, "access-2")
        XCTAssertEqual(service.credentials(for: connection.id)?.refreshToken, "refresh-2")

        // Still valid: no network.
        _ = try await service.validAccessToken(for: connection)
        XCTAssertEqual(SIWCMockURLProtocol.requests.count, 1)

        clock.now = clock.now.addingTimeInterval(7200)
        let second = try await service.validAccessToken(for: connection)
        XCTAssertEqual(second, "access-3")
        XCTAssertEqual(service.credentials(for: connection.id)?.refreshToken, "refresh-3")

        let bodies = SIWCMockURLProtocol.requests.map { SIWCFixtures.form($0.body) }
        XCTAssertEqual(bodies.map { $0["refresh_token"] }, ["refresh-1", "refresh-2"], "Each refresh uses the rotated token")
        XCTAssertEqual(bodies.first?["grant_type"], "refresh_token")
        XCTAssertEqual(bodies.first?["client_id"], SIWCFixtures.issuedClientID)
        XCTAssertNil(bodies.first?["client_secret"])
    }

    func testUnusableRefreshTokenClearsTokensButKeepsRegistration() async throws {
        let service = makeService()
        let connection = SIWCFixtures.chatGPTConnection(id: "cg-invalid")
        providerSettings.updateConnection(connection)
        try service.saveCredentials(
            SIWCFixtures.credentials(expiresAt: clock.now.addingTimeInterval(-10)),
            connectionID: connection.id
        )
        SIWCMockURLProtocol.handler = { _, _ in
            .init(status: 400, body: Data(#"{"error":"refresh_token_reused"}"#.utf8))
        }
        do {
            _ = try await service.validAccessToken(for: connection)
            XCTFail("Expected sign-in required")
        } catch {
            XCTAssertEqual(error as? ChatGPTAccountError, .signInRequired)
        }
        XCTAssertNil(service.credentials(for: connection.id))
        XCTAssertEqual(providerSettings.connection(id: connection.id)?.chatgptIssuedClientID, SIWCFixtures.issuedClientID)
    }

    func testTransientRefreshFailureKeepsCredentials() async throws {
        let service = makeService()
        let connection = SIWCFixtures.chatGPTConnection(id: "cg-transient")
        providerSettings.updateConnection(connection)
        try service.saveCredentials(
            SIWCFixtures.credentials(expiresAt: clock.now.addingTimeInterval(-10)),
            connectionID: connection.id
        )
        SIWCMockURLProtocol.handler = { _, _ in .init(status: 503, body: Data("busy".utf8)) }
        do {
            _ = try await service.validAccessToken(for: connection)
            XCTFail("Expected failure")
        } catch {
            XCTAssertNotEqual(error as? ChatGPTAccountError, .signInRequired)
        }
        XCTAssertEqual(service.credentials(for: connection.id)?.refreshToken, "refresh-1")
    }

    func testMarkPlanUnavailableDisablesPlanButKeepsAccount() throws {
        let service = makeService()
        let connection = SIWCFixtures.chatGPTConnection(id: "cg-mark")
        providerSettings.updateConnection(connection)
        try service.saveCredentials(SIWCFixtures.credentials(expiresAt: clock.now.addingTimeInterval(3600)), connectionID: connection.id)
        service.markPlanUnavailable(connectionID: connection.id, providerSettings: providerSettings, message: "nope")
        XCTAssertEqual(providerSettings.connection(id: connection.id)?.chatgptPlanEligible, false)
        XCTAssertNotNil(service.credentials(for: connection.id))
        XCTAssertEqual(service.lastError, "nope")
    }

    // MARK: Loopback listener

    func testLoopbackListenerBindsToLoopbackAndParsesCallback() async throws {
        let listener = try await ChatGPTOAuthLoopback.start()
        defer { listener.stop() }
        XCTAssertTrue(listener.redirectURI.hasPrefix("http://127.0.0.1:"))
        XCTAssertTrue(listener.redirectURI.hasSuffix("/auth/callback"))
        let url = URL(string: "\(listener.redirectURI)?code=abc&state=xyz&client_id=oaiapp_1&scope=openid+chatgpt.tokens.use.direct")!
        let fetch = Task.detached {
            let (data, response) = try await URLSession(configuration: .ephemeral).data(from: url)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(data: data, encoding: .utf8) ?? "")
        }
        let callback = try await listener.result()
        XCTAssertEqual(callback.code, "abc")
        XCTAssertEqual(callback.state, "xyz")
        XCTAssertEqual(callback.issuedClientID, "oaiapp_1")
        let (status, page) = try await fetch.value
        XCTAssertEqual(status, 200)
        XCTAssertTrue(page.contains(AIConnectBranding.appName))
    }
}
