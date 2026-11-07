// SPDX-License-Identifier: MIT
import Foundation
import XCTest
@testable import AIModelOptions

/// Shared subscription sign-in plumbing: token rotation, refresh failures,
/// RFC 8628 device authorization, and the API-key fallback policy.
final class SubscriptionOAuthTests: XCTestCase {
    // MARK: Token rotation

    func testRefreshReplacesAccessRefreshExpiryAndScopesTogether() {
        let saved = Date(timeIntervalSince1970: 1_000)
        let original = OAuthTokenSet(
            accessToken: "access-1",
            refreshToken: "refresh-1",
            idToken: "id-1",
            tokenType: "Bearer",
            expiresAt: saved.addingTimeInterval(3600),
            scopes: ["openid"],
            savedAt: saved
        )
        let now = Date(timeIntervalSince1970: 5_000)
        let response = OAuthTokenResponse(
            accessToken: "access-2",
            refreshToken: "refresh-2",
            idToken: nil,
            tokenType: "Bearer",
            expiresIn: 3600,
            scope: "openid chatgpt.tokens.use.direct"
        )
        let rotated = original.applyingRefresh(response, now: now)
        XCTAssertEqual(rotated.accessToken, "access-2")
        XCTAssertEqual(rotated.refreshToken, "refresh-2", "Rotated refresh token must be saved")
        XCTAssertEqual(rotated.idToken, "id-1", "Keep the last ID token for id_token_hint")
        XCTAssertEqual(rotated.expiresAt, now.addingTimeInterval(3600))
        XCTAssertEqual(rotated.scopes, ["openid", "chatgpt.tokens.use.direct"])
        XCTAssertEqual(rotated.savedAt, now)
    }

    func testRefreshWithoutNewRefreshTokenKeepsPrevious() {
        let original = OAuthTokenSet(
            accessToken: "a", refreshToken: "keep-me", idToken: nil,
            tokenType: "Bearer", expiresAt: Date(), scopes: ["x"], savedAt: Date()
        )
        let rotated = original.applyingRefresh(
            OAuthTokenResponse(accessToken: "b", expiresIn: 60),
            now: Date()
        )
        XCTAssertEqual(rotated.refreshToken, "keep-me")
        XCTAssertEqual(rotated.scopes, ["x"], "Missing scope keeps the previous grant")
    }

    func testNeedsRefreshUsesSafetyMargin() {
        let now = Date(timeIntervalSince1970: 10_000)
        var tokens = OAuthTokenSet(
            accessToken: "a", refreshToken: "r", idToken: nil, tokenType: "Bearer",
            expiresAt: now.addingTimeInterval(30), scopes: [], savedAt: now
        )
        XCTAssertTrue(tokens.needsRefresh(now: now))
        tokens.expiresAt = now.addingTimeInterval(600)
        XCTAssertFalse(tokens.needsRefresh(now: now))
    }

    func testGenericTokenResponseParsesRefreshAndScope() throws {
        let data = Data(#"{"access_token":"at","refresh_token":"rt","id_token":"it","token_type":"Bearer","expires_in":3600,"scope":"openid email","earliest_refresh_at":123}"#.utf8)
        let parsed = try OAuthTokenCodec.parseTokenResponse(data)
        XCTAssertEqual(parsed.accessToken, "at")
        XCTAssertEqual(parsed.refreshToken, "rt")
        XCTAssertEqual(parsed.idToken, "it")
        XCTAssertEqual(parsed.expiresIn, 3600)
        XCTAssertEqual(parsed.scope, "openid email")
    }

    // MARK: Refresh failures

    func testUnusableRefreshTokenCodesRequireSignIn() {
        for code in [
            "invalid_grant", "invalid_refresh_token", "token_expired",
            "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused",
        ] {
            let body = Data(#"{"error":"\#(code)"}"#.utf8)
            XCTAssertEqual(
                OAuthTokenCodec.classifyRefreshFailure(statusCode: 400, body: body),
                .reauthenticate(code),
                code
            )
        }
    }

    func testInvalidClientIsAConfigurationError() {
        let body = Data(#"{"error":"invalid_client","error_description":"bad"}"#.utf8)
        XCTAssertEqual(OAuthTokenCodec.classifyRefreshFailure(statusCode: 401, body: body), .invalidClient)
    }

    func testServerAndNetworkFailuresKeepCredentials() {
        XCTAssertEqual(OAuthTokenCodec.classifyRefreshFailure(statusCode: 503, body: Data()), .transient)
        XCTAssertEqual(OAuthTokenCodec.classifyRefreshFailure(statusCode: 500, body: Data("oops".utf8)), .transient)
        XCTAssertEqual(OAuthTokenCodec.classifyRefreshFailure(statusCode: nil, body: Data()), .transient)
    }

    // MARK: RFC 8628 device authorization (plumbing for Grok; no client id bundled)

    func testDeviceAuthorizationBody() {
        let body = DeviceAuthorizationCodec.deviceAuthorizationBody(
            clientID: "client-123",
            scope: "openid offline_access"
        )
        XCTAssertEqual(String(data: body, encoding: .utf8), "client_id=client-123&scope=openid%20offline_access")
    }

    func testParseDeviceAuthorizationResponse() throws {
        let data = Data(#"{"device_code":"dc","user_code":"ABCD-EFGH","verification_uri":"https://accounts.x.ai/device","verification_uri_complete":"https://accounts.x.ai/device?user_code=ABCD-EFGH","expires_in":900}"#.utf8)
        let parsed = try DeviceAuthorizationCodec.parseDeviceAuthorization(data, now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(parsed.deviceCode, "dc")
        XCTAssertEqual(parsed.userCode, "ABCD-EFGH")
        XCTAssertEqual(parsed.verificationURI.absoluteString, "https://accounts.x.ai/device")
        XCTAssertEqual(parsed.verificationURIComplete?.absoluteString, "https://accounts.x.ai/device?user_code=ABCD-EFGH")
        XCTAssertEqual(parsed.interval, 5, "RFC 8628 default polling interval")
        XCTAssertEqual(parsed.expiresAt, Date(timeIntervalSince1970: 900))
    }

    func testParseDeviceAuthorizationRejectsMissingFields() {
        XCTAssertThrowsError(try DeviceAuthorizationCodec.parseDeviceAuthorization(Data(#"{"user_code":"x"}"#.utf8)))
    }

    func testDeviceTokenPollBody() {
        let body = DeviceAuthorizationCodec.tokenPollBody(deviceCode: "dc", clientID: "client-123")
        XCTAssertEqual(
            String(data: body, encoding: .utf8),
            "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code&device_code=dc&client_id=client-123"
        )
    }

    func testDevicePollOutcomes() {
        func outcome(_ status: Int, _ json: String) -> DevicePollOutcome {
            DeviceAuthorizationCodec.classifyPoll(statusCode: status, body: Data(json.utf8), currentInterval: 5)
        }
        XCTAssertEqual(outcome(400, #"{"error":"authorization_pending"}"#), .pending(interval: 5))
        XCTAssertEqual(outcome(400, #"{"error":"slow_down"}"#), .pending(interval: 10))
        XCTAssertEqual(outcome(400, #"{"error":"expired_token"}"#), .expired)
        XCTAssertEqual(outcome(400, #"{"error":"access_denied"}"#), .denied)
        XCTAssertEqual(
            outcome(200, #"{"access_token":"at","refresh_token":"rt","expires_in":3600}"#),
            .tokens(OAuthTokenResponse(accessToken: "at", refreshToken: "rt", expiresIn: 3600))
        )
        if case .failed = outcome(500, "nope") {} else { XCTFail("500 should fail") }
    }

    func testOIDCDiscoveryParsing() throws {
        let data = Data(#"{"issuer":"https://auth.x.ai","token_endpoint":"https://auth.x.ai/oauth2/token","device_authorization_endpoint":"https://auth.x.ai/oauth2/device/code","authorization_endpoint":"https://auth.x.ai/oauth2/auth"}"#.utf8)
        let discovery = try OIDCDiscoveryDocument.parse(data)
        XCTAssertEqual(discovery.issuer, "https://auth.x.ai")
        XCTAssertEqual(discovery.tokenEndpoint.absoluteString, "https://auth.x.ai/oauth2/token")
        XCTAssertEqual(discovery.deviceAuthorizationEndpoint?.absoluteString, "https://auth.x.ai/oauth2/device/code")
    }

    func testGrokDeviceConfigNeedsAnExplicitClientID() {
        // The Grok CLI client id is pending maintainer confirmation; nothing ships it.
        XCTAssertNil(XAISubscriptionConfig.bundledClientID)
        let config = XAISubscriptionConfig(clientID: "test-client")
        XCTAssertEqual(config.scope, "openid profile email offline_access grok-cli:access api:access")
        XCTAssertEqual(config.deviceAuthorizationEndpoint.absoluteString, "https://auth.x.ai/oauth2/device/code")
        XCTAssertEqual(config.discoveryURL.absoluteString, "https://auth.x.ai/.well-known/openid-configuration")
        XCTAssertEqual(config.apiBaseURL, "https://api.x.ai/v1")
        let body = String(data: config.deviceAuthorizationBody(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.hasPrefix("client_id=test-client&scope="))
    }

    // MARK: Billing errors and API-key fallback

    func testNotEligibleFallsBackToAPIKey() {
        let body = Data(#"{"error":{"code":"subscription_sharing_user_not_eligible","message":"Not eligible","param":null}}"#.utf8)
        let error = SubscriptionBillingPolicy.classifyChatGPT(statusCode: 403, body: body, requestID: "req_1")
        XCTAssertEqual(error.kind, .notEligible)
        XCTAssertEqual(error.code, "subscription_sharing_user_not_eligible")
        XCTAssertEqual(error.requestID, "req_1")
        XCTAssertTrue(error.fallsBackToAPIKey)
        XCTAssertTrue(error.userMessage.contains("Plus or Pro"))
    }

    func testUsageLimitPointsToManageUsageAndDoesNotSwitchBilling() {
        let body = Data(#"{"error":{"code":"subscription_sharing_usage_limit_exceeded","message":"limit"}}"#.utf8)
        let error = SubscriptionBillingPolicy.classifyChatGPT(statusCode: 429, body: body)
        XCTAssertEqual(error.kind, .usageLimit)
        XCTAssertFalse(error.fallsBackToAPIKey)
        XCTAssertTrue(error.userMessage.contains("Manage usage"))
        XCTAssertTrue(error.userMessage.contains(SubscriptionBillingPolicy.chatGPTManageUsageURL.absoluteString))
    }

    func testOtherChatGPTCodes() {
        func kind(_ status: Int, _ code: String, param: String? = nil) -> SubscriptionBillingErrorKind {
            let paramJSON = param.map { #""\#($0)""# } ?? "null"
            let body = Data(#"{"error":{"code":"\#(code)","message":"m","param":\#(paramJSON)}}"#.utf8)
            return SubscriptionBillingPolicy.classifyChatGPT(statusCode: status, body: body).kind
        }
        XCTAssertEqual(kind(503, "subscription_sharing_usage_unavailable"), .temporarilyUnavailable)
        XCTAssertEqual(kind(503, "subscription_sharing_user_unavailable"), .temporarilyUnavailable)
        XCTAssertEqual(kind(401, "subscription_sharing_invalid_user"), .reauthenticate)
        XCTAssertEqual(kind(400, "subscription_sharing_unsupported_capability", param: "temperature"), .unsupportedCapability("temperature"))
        XCTAssertEqual(kind(403, "subscription_sharing_route_not_supported"), .permission)
        XCTAssertEqual(kind(403, "chatpass_v2_scope_not_authorized"), .permission)
    }

    func testDirectAdmissionDetailBodyIsDiagnosticText() {
        let body = Data(#"{"detail":"Region not permitted"}"#.utf8)
        let error = SubscriptionBillingPolicy.classifyChatGPT(statusCode: 403, body: body)
        XCTAssertEqual(error.kind, .permission)
        XCTAssertNil(error.code)
        XCTAssertTrue(error.userMessage.contains("Region not permitted"))
        XCTAssertFalse(error.fallsBackToAPIKey)
    }

    func testStreamFailureEventCodesAreClassified() {
        let event = #"{"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_limit_exceeded","message":"limit"}}}"#
        XCTAssertEqual(SubscriptionBillingPolicy.chatGPTStreamError(fromEventJSON: event)?.kind, .usageLimit)
        XCTAssertNil(SubscriptionBillingPolicy.chatGPTStreamError(fromEventJSON: #"{"type":"response.output_text.delta","delta":"hi"}"#))
    }

    func testEntitlementErrorsFallBackForDeviceCodeProviders() {
        XCTAssertTrue(SubscriptionBillingPolicy.classifyEntitlement(statusCode: 402, body: Data()).fallsBackToAPIKey)
        XCTAssertTrue(SubscriptionBillingPolicy.classifyEntitlement(statusCode: 403, body: Data()).fallsBackToAPIKey)
        XCTAssertFalse(SubscriptionBillingPolicy.classifyEntitlement(statusCode: 500, body: Data()).fallsBackToAPIKey)
    }
}
