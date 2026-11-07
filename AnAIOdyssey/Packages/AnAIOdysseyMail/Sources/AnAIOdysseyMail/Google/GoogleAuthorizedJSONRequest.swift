// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation

/// Shared request path for the Google REST clients (Gmail and Calendar).
///
/// Authorizes a request with a valid bearer token and decodes the JSON object
/// body. When Google rejects the token with HTTP 401 even though it looked
/// valid locally (revoked token, device clock skew, stale cached expiry), the
/// token is force-refreshed once and the request retried — the standard OAuth
/// client behavior. Without this retry a locally-unexpired-but-rejected token
/// wedged every mail and calendar read until the user signed in again.
enum GoogleAuthorizedJSONRequest {
    /// Builds a request from a bearer token, sends it, and decodes the JSON body.
    ///
    /// `makeRequest` is called again with the fresh token on the single retry.
    static func perform(
        oauth: GoogleOAuthService,
        session: URLSession,
        makeRequest: (String) -> URLRequest
    ) async throws -> [String: Any] {
        let token = try await oauth.validAccessToken()
        let request = makeRequest(token)
        ConnectionDebug.log("GoogleAPI", "request \(request.httpMethod ?? "GET") \(endpoint(for: request.url))")
        let (data, status) = try await execute(request, session: session)
        ConnectionDebug.log("GoogleAPI", "response \(endpoint(for: request.url)) status=\(status) bytes=\(data.count)")
        if status != 401 {
            return try decodeObject(data: data, status: status)
        }

        // Google refused the token; mint a fresh one and retry exactly once.
        ConnectionDebug.log("GoogleAPI", "401 \(endpoint(for: request.url)); forcing token refresh")
        let freshToken = try await oauth.validAccessToken(rejecting: token)
        let retryRequest = makeRequest(freshToken)
        let (retryData, retryStatus) = try await execute(retryRequest, session: session)
        ConnectionDebug.log("GoogleAPI", "retry response \(endpoint(for: retryRequest.url)) status=\(retryStatus) bytes=\(retryData.count)")
        if retryStatus == 401 {
            throw GoogleAPIError.unauthorized
        }
        return try decodeObject(data: retryData, status: retryStatus)
    }

    private static func execute(
        _ request: URLRequest,
        session: URLSession
    ) async throws -> (Data, Int) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            ConnectionDebug.log(
                "GoogleAPI",
                "transport failure \(endpoint(for: request.url)) error=\(error.localizedDescription)"
            )
            throw error
        }
        guard let http = response as? HTTPURLResponse else {
            ConnectionDebug.log("GoogleAPI", "non-HTTP response \(endpoint(for: request.url))")
            throw GoogleAPIError.invalidResponse
        }
        return (data, http.statusCode)
    }

    /// Maps non-2xx statuses to `.requestFailed` (with a clipped body for
    /// context) and non-object bodies to `.invalidResponse`.
    private static func decodeObject(data: Data, status: Int) throws -> [String: Any] {
        guard (200...299).contains(status) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            ConnectionDebug.log("GoogleAPI", "request failed status=\(status) detail=\(safeErrorDetail(body))")
            throw GoogleAPIError.requestFailure(status: status, body: body)
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GoogleAPIError.invalidResponse
        }
        return object
    }

    /// Like `perform`, but treats empty 2xx bodies (HTTP 204) as success with `[:]`.
    static func performAllowingEmpty(
        oauth: GoogleOAuthService,
        session: URLSession,
        makeRequest: (String) -> URLRequest
    ) async throws -> [String: Any] {
        let token = try await oauth.validAccessToken()
        let request = makeRequest(token)
        ConnectionDebug.log("GoogleAPI", "request \(request.httpMethod ?? "GET") \(endpoint(for: request.url))")
        let (data, status) = try await execute(request, session: session)
        ConnectionDebug.log("GoogleAPI", "response \(endpoint(for: request.url)) status=\(status) bytes=\(data.count)")
        if status != 401 {
            return try decodeObjectAllowingEmpty(data: data, status: status)
        }
        ConnectionDebug.log("GoogleAPI", "401 \(endpoint(for: request.url)); forcing token refresh")
        let freshToken = try await oauth.validAccessToken(rejecting: token)
        let retryRequest = makeRequest(freshToken)
        let (retryData, retryStatus) = try await execute(retryRequest, session: session)
        ConnectionDebug.log("GoogleAPI", "retry response \(endpoint(for: retryRequest.url)) status=\(retryStatus) bytes=\(retryData.count)")
        if retryStatus == 401 {
            throw GoogleAPIError.unauthorized
        }
        return try decodeObjectAllowingEmpty(data: retryData, status: retryStatus)
    }

    private static func decodeObjectAllowingEmpty(data: Data, status: Int) throws -> [String: Any] {
        guard (200...299).contains(status) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            ConnectionDebug.log("GoogleAPI", "request failed status=\(status) detail=\(safeErrorDetail(body))")
            throw GoogleAPIError.requestFailure(status: status, body: body)
        }
        if data.isEmpty { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GoogleAPIError.invalidResponse
        }
        return object
    }

    /// Names endpoints without printing account emails, message ids, or query values.
    private static func endpoint(for url: URL?) -> String {
        guard let url else { return "unknown-endpoint" }
        let path = url.path
        if path.hasSuffix("/labels") { return "gmail-labels" }
        if path.contains("/messages/") { return "gmail-message" }
        if path.hasSuffix("/messages") { return "gmail-messages" }
        if path.hasSuffix("/calendarList") { return "calendar-list" }
        if path.contains("/events/") { return "calendar-event" }
        if path.hasSuffix("/events") { return "calendar-events" }
        if path.hasSuffix("/userinfo") { return "google-userinfo" }
        return url.host ?? "google-api"
    }

    /// Clips and flattens Google error JSON; successful payloads are never logged.
    private static func safeErrorDetail(_ body: String) -> String {
        String(body.prefix(240))
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}
