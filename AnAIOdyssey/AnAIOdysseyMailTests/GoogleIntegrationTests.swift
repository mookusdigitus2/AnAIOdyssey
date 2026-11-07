// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import XCTest
@testable import AnAIOdysseyMail
// Scoped so AIConnect's keychain types don't clash with Mail's own.
import class AIConnect.ProviderSettings
import enum AIConnect.OpenAICompatibleAPI
import enum AIConnect.RemoteAPIProvider

@MainActor
final class GoogleIntegrationTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "GoogleIntegrationTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testGoogleSettingsApplyGeminiPreset() {
        let settings = GoogleSettings(defaults: defaults)
        settings.geminiAPIKey = "test-gemini-key"
        settings.geminiModel = "gemini-2.0-flash"

        let providerSettings = ProviderSettings(defaults: defaults)
        settings.applyGeminiToProviderSettings(providerSettings)

        XCTAssertEqual(providerSettings.apiBaseURL, GoogleSettings.defaultGeminiBaseURL)
        XCTAssertEqual(providerSettings.apiKey, "test-gemini-key")
        XCTAssertEqual(providerSettings.remoteModel, "gemini-2.0-flash")
    }

    func testGoogleSettingsSignedInDefaultsFalse() {
        let settings = GoogleSettings(defaults: defaults)
        XCTAssertFalse(settings.isSignedIn)
    }

    func testUnifiedReaderWithoutAccountsIsNotConfigured() {
        let store = MailAccountStore(defaults: defaults, session: .shared, secureStore: InMemoryTokenSecureStore())
        let reader = UnifiedMailReaderService(accountStore: store, includeAppleMail: false)
        reader.refreshAccessStatus()
        XCTAssertEqual(reader.accessStatus, .mailNotConfigured)
        XCTAssertEqual(reader.childCount, 0)
    }

    func testMailAccountLabels() {
        let withName = MailAccount(provider: .gmail, email: "a@example.com", displayName: "Work")
        XCTAssertEqual(withName.label, "Work")
        XCTAssertEqual(withName.detailedLabel, "Gmail · a@example.com")

        let noName = MailAccount(provider: .gmail, email: "b@example.com")
        XCTAssertEqual(noName.label, "b@example.com")
    }

    func testReversedClientSchemeDerivation() {
        XCTAssertEqual(
            GoogleAuthSession.reversedClientScheme(for: "1234-abc.apps.googleusercontent.com"),
            "com.googleusercontent.apps.1234-abc"
        )
        // A non-Google client id has no reversed custom scheme.
        XCTAssertNil(GoogleAuthSession.reversedClientScheme(for: "not-a-google-client"))
    }

    func testOAuthScopesIncludeGmailAndCalendar() {
        XCTAssertTrue(GoogleOAuthService.scopes.contains { $0.contains("gmail.readonly") })
        XCTAssertTrue(GoogleOAuthService.scopes.contains { $0.contains("calendar") })
    }

    func testFormURLEncodedEscapesPlusAndSlash() {
        let data = GoogleOAuthService.formURLEncoded([
            "refresh_token": "1//abc+def/ghi",
            "grant_type": "refresh_token",
        ])
        let body = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(body.contains("+"), "Unescaped + would be decoded as a space")
        XCTAssertTrue(body.contains("1%2F%2Fabc%2Bdef%2Fghi"))
        XCTAssertTrue(body.contains("grant_type=refresh_token"))
    }

    func testInvalidGrantExplainsTestingExpiry() {
        let message = GoogleOAuthError.refreshFailureDescription(#"{"error":"invalid_grant"}"#)
        XCTAssertTrue(message.contains("Testing"))
        XCTAssertTrue(message.contains("7 days"))
    }

    func testDeletedGoogleProjectExplainsHowToReconnect() {
        let error = GoogleAPIError.requestFailure(
            status: 403,
            body: #"{"error":{"message":"Project #143165873899 has been deleted."}}"#
        )
        let message = error.localizedDescription
        XCTAssertTrue(message.contains("OAuth Client ID"))
        XCTAssertTrue(message.contains("Gmail"))
        XCTAssertTrue(message.contains("Calendar"))
        XCTAssertTrue(message.contains("sign in again"))
    }

    func testTokenStorePersistsRefreshToken() throws {
        // Use a shared in-memory secret store so two store instances see the same data
        // without relying on the Keychain (unavailable in unsigned test binaries).
        let secrets = InMemoryTokenSecureStore()
        let store = GoogleTokenStore(accountID: "acct-1", defaults: defaults, secureStore: secrets)
        try store.save(
            GoogleOAuthTokens(
                accessToken: "access",
                refreshToken: "refresh",
                expiresAt: Date().addingTimeInterval(3600)
            )
        )

        let reloaded = GoogleTokenStore(accountID: "acct-1", defaults: defaults, secureStore: secrets)
        XCTAssertEqual(reloaded.refreshTokenValue(), "refresh")
        XCTAssertTrue(reloaded.hasValidAccessToken)
        try reloaded.requirePersistedRefreshToken()
    }

    func testTokenStoreFallsBackToDefaultsWhenSecureStoreRejectsWrite() throws {
        let store = GoogleTokenStore(
            accountID: "acct-fail",
            defaults: defaults,
            secureStore: FailingTokenSecureStore()
        )
        try store.save(
            GoogleOAuthTokens(accessToken: "access", refreshToken: "refresh")
        )
        XCTAssertEqual(store.tokens?.accessToken, "access")
        XCTAssertNoThrow(try store.requirePersistedRefreshToken())

        let reloaded = GoogleTokenStore(
            accountID: "acct-fail",
            defaults: defaults,
            secureStore: FailingTokenSecureStore()
        )
        XCTAssertEqual(reloaded.refreshTokenValue(), "refresh")
        XCTAssertTrue(reloaded.hasValidAccessToken)
    }

    func testTokenStoreAccessTokenOnlySessionIsUsable() throws {
        let secrets = InMemoryTokenSecureStore()
        let store = GoogleTokenStore(accountID: "acct-2", defaults: defaults, secureStore: secrets)
        try store.save(GoogleOAuthTokens(accessToken: "access", refreshToken: nil))
        XCTAssertNoThrow(try store.requirePersistedRefreshToken())
    }

    func testIsSignedInSeesTokensWhenKeychainWriteFails() throws {
        let account = MailAccount(id: "g1", provider: .gmail, email: "me@example.com")
        let store = MailAccountStore(
            defaults: defaults,
            session: .shared,
            secureStore: FailingTokenSecureStore()
        )
        try store.tokenStore(for: account).save(
            GoogleOAuthTokens(accessToken: "access", refreshToken: "refresh")
        )
        XCTAssertTrue(store.isSignedIn(account))

        defaults.set(try JSONEncoder().encode([account]), forKey: "anaiodyssey.mail.accounts")
        let reloaded = MailAccountStore(
            defaults: defaults,
            session: .shared,
            secureStore: FailingTokenSecureStore()
        )
        XCTAssertTrue(reloaded.isSignedIn(account))
        let reader = UnifiedMailReaderService(accountStore: reloaded, includeAppleMail: false)
        XCTAssertEqual(reader.childCount, 1)
        XCTAssertEqual(reader.accessStatus, .available)
    }

    func testSaveWithoutRefreshTokenPreservesExistingRefreshToken() throws {
        let secrets = InMemoryTokenSecureStore()
        let store = GoogleTokenStore(accountID: "acct-keep", defaults: defaults, secureStore: secrets)
        try store.save(GoogleOAuthTokens(accessToken: "a1", refreshToken: "r1"))
        // A repeat grant that omits refresh_token must not erase the stored one.
        try store.save(GoogleOAuthTokens(accessToken: "a2", refreshToken: nil))

        XCTAssertEqual(store.tokens?.accessToken, "a2")
        XCTAssertEqual(store.refreshTokenValue(), "r1")

        let reloaded = GoogleTokenStore(accountID: "acct-keep", defaults: defaults, secureStore: secrets)
        XCTAssertEqual(reloaded.refreshTokenValue(), "r1")
    }

    func testGmail401ForcesTokenRefreshAndRetries() async throws {
        let secrets = InMemoryTokenSecureStore()
        let store = GoogleTokenStore(accountID: "acct-401", defaults: defaults, secureStore: secrets)
        // A token that still looks valid locally but that Google now rejects.
        try store.save(
            GoogleOAuthTokens(
                accessToken: "stale",
                refreshToken: "refresh-1",
                expiresAt: Date().addingTimeInterval(3600)
            )
        )

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockGoogleURLProtocol.self]
        let session = URLSession(configuration: config)

        MockGoogleURLProtocol.handler = { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("oauth2.googleapis.com/token") {
                return (200, Data(#"{"access_token":"fresh","expires_in":3600,"token_type":"Bearer"}"#.utf8))
            }
            let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
            if auth == "Bearer fresh" {
                return (200, Data(#"{"labels":[{"id":"INBOX","name":"INBOX","type":"system"}]}"#.utf8))
            }
            return (401, Data(#"{"error":{"code":401,"message":"Invalid Credentials"}}"#.utf8))
        }
        defer { MockGoogleURLProtocol.handler = nil }

        let oauth = GoogleOAuthService(
            tokenStore: store,
            clientID: "client-id.apps.googleusercontent.com",
            defaults: defaults,
            session: session
        )
        let client = GmailAPIClient(oauth: oauth, session: session)

        // Before the fix this threw GoogleAPIError.unauthorized on the first 401
        // and every mail read stayed wedged until a manual re-sign-in.
        let labels = try await client.listLabels()
        XCTAssertEqual(labels.map(\.id), ["INBOX"])
        XCTAssertEqual(store.tokens?.accessToken, "fresh")
        XCTAssertEqual(store.refreshTokenValue(), "refresh-1", "Refresh token must survive the refresh grant")
    }

    func testGoogleIDMapperSnapshotRoundTrip() {
        let mapper = GoogleIDMapper()
        let inboxID = mapper.id(for: "INBOX")
        let messageID = mapper.id(for: "gmail-msg-42")

        let restored = GoogleIDMapper()
        restored.restore(mapper.snapshot())
        XCTAssertEqual(restored.string(for: inboxID), "INBOX")
        XCTAssertEqual(restored.string(for: messageID), "gmail-msg-42")
        // New keys must keep allocating past the restored range, not collide with it.
        let newID = restored.id(for: "gmail-msg-43")
        XCTAssertNotEqual(newID, inboxID)
        XCTAssertNotEqual(newID, messageID)
    }

    func testRestoredCacheSeedsGmailIDMappers() throws {
        // Regression test: after a relaunch, tapping a cached message row must
        // resolve to the same Gmail message it was listed as — previously the
        // rebuilt reader's empty id mapper made every cached row unopenable.
        let account = MailAccount(id: "acct-map", provider: .gmail, email: "me@example.com")
        let secrets = InMemoryTokenSecureStore()
        // The account list must be in defaults before the store loads it at init.
        defaults.set(try JSONEncoder().encode([account]), forKey: "anaiodyssey.mail.accounts")
        let store = MailAccountStore(defaults: defaults, session: .shared, secureStore: secrets)
        try store.tokenStore(for: account).save(
            GoogleOAuthTokens(accessToken: "access", refreshToken: "refresh")
        )

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let snapshot = UnifiedMailCacheSnapshot(
            accountFingerprint: account.id,
            mailboxes: [],
            messagesByMailbox: [:],
            nextMailboxGlobalID: 1,
            nextMessageGlobalID: 6,
            mailboxKeyToGlobal: [:],
            globalToMailbox: [:],
            messageKeyToGlobal: ["0|3": 5],
            globalToMessage: ["5": .init(childIndex: 0, childMessageID: 3)],
            gmailMappersByAccountID: [
                account.id: GmailIDMapperState(
                    labels: .init(stringToID: ["INBOX": 1], nextID: 2),
                    messages: .init(stringToID: ["gmail-msg-3": 3], nextID: 4)
                ),
            ]
        )
        EmailCachePersistence.save(snapshot, appSupportDirectory: tempDir)

        let reader = UnifiedMailReaderService(
            accountStore: store,
            includeAppleMail: false,
            cacheAppSupportDirectory: tempDir
        )
        let context = reader.gmailSendContext(forGlobalMessageRowID: 5)
        XCTAssertEqual(context?.gmailMessageID, "gmail-msg-3")
        XCTAssertEqual(context?.accountID, account.id)
    }

    func testCacheSnapshotDecodesWithoutMapperField() throws {
        // Cache files written before the mapper field existed must still decode.
        let legacyJSON = """
        {
            "accountFingerprint": "acct-old",
            "mailboxes": [],
            "messagesByMailbox": {},
            "nextMailboxGlobalID": 1,
            "nextMessageGlobalID": 1,
            "mailboxKeyToGlobal": {},
            "globalToMailbox": {},
            "messageKeyToGlobal": {},
            "globalToMessage": {}
        }
        """
        let snapshot = try JSONDecoder().decode(
            UnifiedMailCacheSnapshot.self,
            from: Data(legacyJSON.utf8)
        )
        XCTAssertEqual(snapshot.accountFingerprint, "acct-old")
        XCTAssertNil(snapshot.gmailMappersByAccountID)
    }

    func testMergingIncomingAccountsKeepsSignedInLocalAccount() throws {
        let secrets = InMemoryTokenSecureStore()
        let store = MailAccountStore(defaults: defaults, session: .shared, secureStore: secrets)
        store.oauthClientID = "test-client"
        let local = MailAccount(id: "local-id", provider: .gmail, email: "me@example.com")
        try store.tokenStore(for: local).save(
            GoogleOAuthTokens(accessToken: "access", refreshToken: "refresh")
        )
        defaults.set(
            try JSONEncoder().encode([local]),
            forKey: "anaiodyssey.mail.accounts"
        )
        let reloaded = MailAccountStore(defaults: defaults, session: .shared, secureStore: secrets)
        let incoming = [
            MailAccount(id: "cloud-id", provider: .gmail, email: "me@example.com"),
            MailAccount(id: "other-id", provider: .gmail, email: "other@example.com"),
        ]
        let merged = reloaded.mergingIncomingAccounts(incoming)
        XCTAssertEqual(merged.map(\.id), ["local-id", "other-id"])
        XCTAssertTrue(reloaded.isSignedIn(merged[0]))
    }

    func testConnectionManagerOwnsGoogleAuthAdapter() throws {
        let secrets = InMemoryTokenSecureStore()
        let store = MailAccountStore(defaults: defaults, session: .shared, secureStore: secrets)
        let account = MailAccount(id: "g-conn", provider: .gmail, email: "me@example.com")
        try store.tokenStore(for: account).save(
            GoogleOAuthTokens(accessToken: "access", refreshToken: "refresh")
        )
        defaults.set(try JSONEncoder().encode([account]), forKey: "anaiodyssey.mail.accounts")
        let reloaded = MailAccountStore(defaults: defaults, session: .shared, secureStore: secrets)
        let manager = WorkspaceConnectionManager(
            accountStore: reloaded,
            includeAppleMail: false
        )

        XCTAssertTrue(manager.connections.contains { $0.kind == .eventKit })
        XCTAssertFalse(manager.connections.contains { $0.kind == .appleMail })
        let google = manager.connections.filter { $0.kind == .google }
        XCTAssertEqual(google.count, 1)
        XCTAssertEqual(google.first?.displayName, "me@example.com")
        XCTAssertTrue(google.first?.isConnected ?? false)
        XCTAssertTrue(google.first?.capabilities.contains(.email) ?? false)
        XCTAssertTrue(google.first?.capabilities.contains(.calendar) ?? false)

        let email = manager.emailAdapters()
        XCTAssertEqual(email.count, 1)
        XCTAssertTrue(email[0] is GoogleAuthAdapter)
        XCTAssertTrue(email[0].isAvailable)

        let calendar = manager.calendarAdapters()
        XCTAssertEqual(calendar.count, 1)
        XCTAssertEqual(calendar[0].connectionID, GoogleAuthAdapter.connectionID(for: account.id))
    }

    func testConnectionManagerDisconnectRemovesGoogleAccount() throws {
        let secrets = InMemoryTokenSecureStore()
        let store = MailAccountStore(defaults: defaults, session: .shared, secureStore: secrets)
        let account = MailAccount(id: "g-drop", provider: .gmail, email: "gone@example.com")
        try store.tokenStore(for: account).save(
            GoogleOAuthTokens(accessToken: "access", refreshToken: "refresh")
        )
        defaults.set(try JSONEncoder().encode([account]), forKey: "anaiodyssey.mail.accounts")
        let reloaded = MailAccountStore(defaults: defaults, session: .shared, secureStore: secrets)
        let manager = WorkspaceConnectionManager(
            accountStore: reloaded,
            includeAppleMail: false
        )
        XCTAssertEqual(manager.googleConnections.count, 1)
        manager.disconnect(id: GoogleAuthAdapter.connectionID(for: account.id))
        XCTAssertTrue(manager.googleConnections.isEmpty)
        XCTAssertTrue(reloaded.accounts.isEmpty)
    }

    func testConnectionManagerFakeInboxSurfacesInUnifiedReader() async throws {
        let secrets = InMemoryTokenSecureStore()
        let store = MailAccountStore(defaults: defaults, session: .shared, secureStore: secrets)
        let manager = WorkspaceConnectionManager(accountStore: store, includeAppleMail: false)
        manager.seedFakeInboxForTesting()

        XCTAssertTrue(manager.connections.contains { $0.id == FakeEmailProviderAdapter.connectionID })
        XCTAssertEqual(manager.installedEmailAdapters.count, 1)
        XCTAssertTrue(manager.emailAdapters().contains { $0.connectionID == FakeEmailProviderAdapter.connectionID })

        let reader = UnifiedMailReaderService(
            accountStore: store,
            includeAppleMail: false,
            extraEmailAdapters: manager.installedEmailAdapters
        )
        XCTAssertEqual(reader.childCount, 1)
        XCTAssertEqual(reader.accessStatus, .available)

        let mailboxes = try await reader.refreshMailboxes()
        XCTAssertTrue(mailboxes.contains { $0.displayName == "Inbox" })

        let messages = try await reader.refreshMessages(
            mailboxID: UnifiedMailReaderService.unifiedInboxID,
            limit: 10
        )
        XCTAssertEqual(Set(messages.map(\.subject)), Set(FakeEmailProviderAdapter.sampleSubjects))
        XCTAssertEqual(messages.first?.subject, FakeEmailProviderAdapter.sampleSubjects[0])

        let detail = try reader.loadMessageDetail(messageRowID: messages[0].id)
        XCTAssertTrue(detail.bodyText?.contains("Goals") == true)
    }

    func testPostAuthReloadFetchesGmailInbox() async throws {
        let secrets = InMemoryTokenSecureStore()
        let account = MailAccount(id: "g-auth", provider: .gmail, email: "me@example.com")
        defaults.set(try JSONEncoder().encode([account]), forKey: "anaiodyssey.mail.accounts")

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockGoogleURLProtocol.self]
        let session = URLSession(configuration: config)
        MockGoogleURLProtocol.handler = { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("/labels") {
                return (200, Data(#"{"labels":[{"id":"INBOX","name":"INBOX","type":"system","messagesTotal":1,"messagesUnread":1}]}"#.utf8))
            }
            if url.contains("/messages/") {
                return (200, Data(#"{"id":"m1","threadId":"t1","internalDate":"1700000000000","snippet":"Hello body","labelIds":["INBOX","UNREAD"],"payload":{"headers":[{"name":"From","value":"Ada <ada@example.com>"},{"name":"Subject","value":"Hello from Gmail"}]}}"#.utf8))
            }
            if url.contains("/messages") {
                return (200, Data(#"{"messages":[{"id":"m1","threadId":"t1"}]}"#.utf8))
            }
            return (404, Data(#"{"error":"unhandled"}"#.utf8))
        }
        defer { MockGoogleURLProtocol.handler = nil }

        let store = MailAccountStore(defaults: defaults, session: session, secureStore: secrets)
        try store.tokenStore(for: account).save(
            GoogleOAuthTokens(
                accessToken: "access",
                refreshToken: "refresh",
                expiresAt: Date().addingTimeInterval(3600)
            )
        )

        let reader = UnifiedMailReaderService(
            accountStore: store,
            includeAppleMail: false,
            session: session
        )
        XCTAssertEqual(reader.childCount, 1, "Signed-in Gmail must produce a reader after auth")
        XCTAssertEqual(reader.accessStatus, .available)

        let mailboxes = try await reader.refreshMailboxes()
        XCTAssertTrue(mailboxes.contains { $0.id == UnifiedMailReaderService.unifiedInboxID })

        let messages = try await reader.refreshMessages(
            mailboxID: UnifiedMailReaderService.unifiedInboxID,
            limit: 10
        )
        XCTAssertEqual(messages.map(\.subject), ["Hello from Gmail"])
        XCTAssertTrue(reader.hasCachedData)

        // EmailView reloads again after GoogleWorkspaceConnector.warmUp(); cache
        // is cleared, so the second fetch must still populate the inbox.
        reader.reload()
        reader.refreshAccessStatus()
        XCTAssertEqual(reader.accessStatus, .available)
        let messagesAgain = try await reader.refreshMessages(
            mailboxID: UnifiedMailReaderService.unifiedInboxID,
            limit: 10
        )
        XCTAssertEqual(messagesAgain.map(\.subject), ["Hello from Gmail"])
    }
}

/// Secret backend that always fails writes, used to prove sign-in still
/// keeps tokens in memory and the local UserDefaults fallback.
private final class FailingTokenSecureStore: TokenSecureStore {
    func read(account: String) -> Data? { nil }
    func write(_ data: Data, account: String) -> Bool { false }
    func remove(account: String) {}
}

/// Stubs Google HTTP endpoints (token + API) for auth-flow tests.
final class MockGoogleURLProtocol: URLProtocol {
    /// Returns (status, body) for a request. Set per test; reset in a defer.
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let (status, data) = handler(request)
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.invalid")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class GeminiProviderDetectionTests: XCTestCase {
    func testDetectGeminiProvider() {
        XCTAssertEqual(
            OpenAICompatibleAPI.detectProvider(
                baseURL: "https://generativelanguage.googleapis.com/v1beta/openai"
            ),
            .gemini
        )
    }

    func testBuildGeminiChatURL() {
        XCTAssertEqual(
            OpenAICompatibleAPI.buildChatCompletionsURL(
                baseURL: "https://generativelanguage.googleapis.com/v1beta/openai"
            )?.absoluteString,
            "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"
        )
    }

    func testGeminiRequiresAPIKey() {
        XCTAssertFalse(
            OpenAICompatibleAPI.isConfigured(
                baseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
                apiKey: ""
            )
        )
        XCTAssertTrue(
            OpenAICompatibleAPI.isConfigured(
                baseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
                apiKey: "secret"
            )
        )
    }
}
