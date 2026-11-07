// SPDX-License-Identifier: MIT
import Foundation
import XCTest
@testable import AIModelOptions

final class ChatGPTOAuthCodecTests: XCTestCase {
    func testPKCEChallengeMatchesRFC7636() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(
            ChatGPTOAuthCodec.pkceChallenge(verifier: verifier),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        )
    }

    func testAuthorizationURLEncodesFirstRegistration() {
        let url = ChatGPTOAuthCodec.authorizationURL(
            clientID: ChatGPTOAuthCodec.dynamicClientID,
            redirectURI: ChatGPTOAuthCodec.redirectURI(port: 1455),
            state: "state-1",
            nonce: "nonce-1",
            codeChallenge: "challenge-1",
            extAgentHostID: "urn:uuid:11111111-1111-1111-1111-111111111111"
        )
        let items = queryItems(url)
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "auth.openai.com")
        XCTAssertEqual(url.path, "/api/accounts/authorize")
        XCTAssertEqual(items["client_id"], "dynamic_agent_client")
        XCTAssertEqual(items["agent_name_hint"], "An AI Odyssey")
        XCTAssertEqual(items["ext_agent_host_id"], "urn:uuid:11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(items["response_type"], "code")
        XCTAssertEqual(items["redirect_uri"], "http://127.0.0.1:1455/auth/callback")
        XCTAssertEqual(items["scope"], ChatGPTOAuthCodec.requestedScope)
        XCTAssertEqual(items["resource"], "https://api.openai.com/v1")
        XCTAssertEqual(items["state"], "state-1")
        XCTAssertEqual(items["nonce"], "nonce-1")
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["code_challenge"], "challenge-1")
        XCTAssertFalse(url.absoluteString.contains("localhost"))
        XCTAssertTrue(url.absoluteString.contains("agent_name_hint=An%20AI%20Odyssey"))
        XCTAssertTrue(url.absoluteString.contains("scope=openid%20profile%20email%20offline_access%20resource.invoke%20chatgpt.tokens.use.direct"))
    }

    func testReturningAuthorizationURLOmitsAgentNameHint() {
        let url = ChatGPTOAuthCodec.authorizationURL(
            clientID: "oaiapp_saved",
            redirectURI: ChatGPTOAuthCodec.redirectURI(port: 54321),
            state: "s",
            nonce: "n",
            codeChallenge: "c",
            extAgentHostID: "urn:uuid:aaaa",
            loginHint: "user@example.com",
            idTokenHint: "expired-id-token"
        )
        let items = queryItems(url)
        XCTAssertEqual(items["client_id"], "oaiapp_saved")
        XCTAssertNil(items["agent_name_hint"])
        XCTAssertEqual(items["login_hint"], "user@example.com")
        XCTAssertEqual(items["id_token_hint"], "expired-id-token")
        XCTAssertEqual(items["redirect_uri"], "http://127.0.0.1:54321/auth/callback")
    }

    func testTokenExchangeBodyHasNoSecretAndIncludesResource() throws {
        let body = ChatGPTOAuthCodec.tokenExchangeBody(
            code: "auth-code",
            clientID: "oaiapp_issued",
            codeVerifier: "verifier",
            redirectURI: "http://127.0.0.1:1455/auth/callback"
        )
        let fields = formFields(body)
        XCTAssertEqual(fields["grant_type"], "authorization_code")
        XCTAssertEqual(fields["client_id"], "oaiapp_issued")
        XCTAssertEqual(fields["code"], "auth-code")
        XCTAssertEqual(fields["code_verifier"], "verifier")
        XCTAssertEqual(fields["redirect_uri"], "http://127.0.0.1:1455/auth/callback")
        XCTAssertEqual(fields["resource"], "https://api.openai.com/v1")
        XCTAssertNil(fields["client_secret"])
        XCTAssertEqual(Set(fields.keys).count, 6)
        XCTAssertEqual(
            String(data: body, encoding: .utf8),
            "grant_type=authorization_code&client_id=oaiapp_issued&code=auth-code&code_verifier=verifier&redirect_uri=http%3A%2F%2F127.0.0.1%3A1455%2Fauth%2Fcallback&resource=https%3A%2F%2Fapi.openai.com%2Fv1"
        )
    }

    func testRefreshBodyOmitsScopeAndSecret() {
        let body = ChatGPTOAuthCodec.refreshTokenBody(
            refreshToken: "refresh-1",
            clientID: "oaiapp_issued"
        )
        let fields = formFields(body)
        XCTAssertEqual(fields["grant_type"], "refresh_token")
        XCTAssertEqual(fields["client_id"], "oaiapp_issued")
        XCTAssertEqual(fields["refresh_token"], "refresh-1")
        XCTAssertEqual(fields["resource"], "https://api.openai.com/v1")
        XCTAssertNil(fields["scope"])
        XCTAssertNil(fields["client_secret"])
        XCTAssertEqual(
            String(data: body, encoding: .utf8),
            "grant_type=refresh_token&client_id=oaiapp_issued&refresh_token=refresh-1&resource=https%3A%2F%2Fapi.openai.com%2Fv1"
        )
    }

    func testCallbackParsesIssuedClientIDAndScopes() throws {
        let url = URL(string: "http://127.0.0.1:1455/auth/callback?code=abc&scope=chatgpt.tokens.use.direct+email+offline_access+openid+profile+resource.invoke&state=original&client_id=oaiapp_123")!
        let callback = try ChatGPTOAuthCodec.parseCallbackURL(url)
        XCTAssertEqual(callback.code, "abc")
        XCTAssertEqual(callback.state, "original")
        XCTAssertEqual(callback.issuedClientID, "oaiapp_123")
        XCTAssertTrue(ChatGPTOAuthCodec.isPlanEligible(
            grantedScopes: ChatGPTOAuthCodec.parseScopeString(callback.scope)
        ))
    }

    func testAccessDeniedMapsToEligibilityCopy() {
        let url = URL(string: "http://127.0.0.1:1455/auth/callback?error=access_denied&state=s")!
        XCTAssertThrowsError(try ChatGPTOAuthCodec.parseCallbackURL(url)) { error in
            let codecError = error as? ChatGPTOAuthCodecError
            XCTAssertEqual(codecError, .authorization("access_denied", nil))
            XCTAssertEqual(
                (error as? LocalizedError)?.errorDescription,
                ChatGPTOAuthCodec.ineligibleUserMessage
            )
        }
    }

    func testNeverPersistsDynamicAgentClient() {
        XCTAssertThrowsError(
            try ChatGPTOAuthCodec.resolvedIssuedClientID(
                callbackClientID: "dynamic_agent_client",
                pendingClientID: "dynamic_agent_client"
            )
        ) { error in
            XCTAssertEqual(error as? ChatGPTOAuthCodecError, .incompleteRegistration)
        }
        XCTAssertEqual(
            try ChatGPTOAuthCodec.resolvedIssuedClientID(
                callbackClientID: "oaiapp_new",
                pendingClientID: "dynamic_agent_client"
            ),
            "oaiapp_new"
        )
        XCTAssertEqual(
            try ChatGPTOAuthCodec.resolvedIssuedClientID(
                callbackClientID: nil,
                pendingClientID: "oaiapp_saved"
            ),
            "oaiapp_saved"
        )
        XCTAssertThrowsError(
            try ChatGPTOAuthCodec.resolvedIssuedClientID(
                callbackClientID: "oaiapp_other",
                pendingClientID: "oaiapp_saved"
            )
        ) { error in
            XCTAssertEqual(error as? ChatGPTOAuthCodecError, .clientIDMismatch)
        }
    }

    func testEligibilityFromGrantedScopes() {
        XCTAssertTrue(
            ChatGPTOAuthCodec.isPlanEligible(
                grantedScopes: ["openid", "chatgpt.tokens.use.direct", "email"]
            )
        )
        XCTAssertFalse(
            ChatGPTOAuthCodec.isPlanEligible(grantedScopes: ["openid", "profile", "email"])
        )
        XCTAssertFalse(ChatGPTOAuthCodec.isPlanEligible(grantedScopes: []))
    }

    func testTokenResponseParsing() throws {
        let json = """
        {"access_token":"at","refresh_token":"rt","id_token":"id","token_type":"Bearer","expires_in":3600,"scope":"openid chatgpt.tokens.use.direct"}
        """.data(using: .utf8)!
        let response = try ChatGPTOAuthCodec.parseTokenResponse(json)
        XCTAssertEqual(response.accessToken, "at")
        XCTAssertEqual(response.refreshToken, "rt")
        XCTAssertTrue(
            ChatGPTOAuthCodec.isPlanEligible(
                grantedScopes: ChatGPTOAuthCodec.parseScopeString(response.scope)
            )
        )
    }

    func testIDTokenClaimValidation() throws {
        let payload: [String: Any] = [
            "iss": "https://auth.openai.com",
            "aud": "oaiapp_issued",
            "nonce": "abc",
            "sub": "user-1",
            "email": "user@example.com",
            "exp": Date().addingTimeInterval(600).timeIntervalSince1970,
        ]
        let jwt = unsignedJWT(payload: payload)
        let identity = try ChatGPTOAuthCodec.validateIDTokenClaims(
            jwt,
            issuedClientID: "oaiapp_issued",
            nonce: "abc"
        )
        XCTAssertEqual(identity.subject, "user-1")
        XCTAssertEqual(identity.email, "user@example.com")
    }

    func testIDTokenRejectsWrongNonceAndAudience() {
        let payload: [String: Any] = [
            "iss": "https://auth.openai.com",
            "aud": "other",
            "nonce": "nope",
            "sub": "user-1",
            "exp": Date().addingTimeInterval(600).timeIntervalSince1970,
        ]
        let jwt = unsignedJWT(payload: payload)
        XCTAssertThrowsError(
            try ChatGPTOAuthCodec.validateIDTokenClaims(
                jwt,
                issuedClientID: "oaiapp_issued",
                nonce: "abc"
            )
        )
    }

    private func queryItems(_ url: URL) -> [String: String] {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .reduce(into: [String: String]()) { result, item in
                result[item.name] = item.value
            } ?? [:]
    }

    private func formFields(_ data: Data) -> [String: String] {
        let raw = String(data: data, encoding: .utf8) ?? ""
        return raw.split(separator: "&").reduce(into: [String: String]()) { result, pair in
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return }
            result[parts[0]] = parts[1].removingPercentEncoding
        }
    }

    private func unsignedJWT(payload: [String: Any]) -> String {
        let header = ChatGPTOAuthCodec.base64URLEncode(Data("{\"alg\":\"none\"}".utf8))
        let payloadData = try! JSONSerialization.data(withJSONObject: payload)
        let body = ChatGPTOAuthCodec.base64URLEncode(payloadData)
        return "\(header).\(body).sig"
    }
}
