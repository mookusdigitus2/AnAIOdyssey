// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import Network
import AnAIOdysseyCore

/// A one-shot localhost HTTP listener that captures the OAuth authorization code.
///
/// Google's installed-app flow redirects the browser to `http://127.0.0.1:<port>/oauth2callback?code=...`.
/// This server listens on that loopback port just long enough to read the single redirect
/// request, parse the `code` query parameter, reply with a friendly page, and shut down.
/// It's used only by the macOS interactive sign-in flow.
enum OAuthLoopbackServer {
    /// Starts the loopback listener and resumes with the captured authorization code.
    ///
    /// Bridges the callback-based `Network` API into async/await via a checked continuation.
    /// The continuation resumes exactly once: with the code on success, or an error if the
    /// port is invalid, the request lacks a code, or the listener fails. The listener is
    /// torn down as soon as a code is captured.
    static func captureAuthorizationCode(expectedPath: String = "/oauth2callback", port: UInt16 = 8765) async throws -> String {
        let queue = DispatchQueue(label: "google-oauth-loopback")
        return try await withCheckedThrowingContinuation { continuation in
            do {
                // Validate the requested TCP port.
                guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                    continuation.resume(throwing: GoogleOAuthError.tokenExchangeFailed("Invalid loopback port."))
                    return
                }

                // Listen for the browser's single redirect connection.
                let listener = try NWListener(using: .tcp, on: nwPort)
                listener.newConnectionHandler = { connection in
                    connection.start(queue: queue)
                    // Read the incoming HTTP request bytes (one read is enough for the GET line).
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                        defer { connection.cancel() }
                        guard let data,
                              let request = String(data: data, encoding: .utf8) else {
                            return
                        }

                        // Parse the HTTP request line, confirm it's the callback path, and
                        // extract the `code` query parameter from the request target.
                        guard let requestLine = request.split(separator: "\r\n", maxSplits: 1).first,
                              requestLine.contains(expectedPath),
                              let urlPart = requestLine.split(separator: " ").dropFirst().first,
                              let components = URLComponents(string: String(urlPart)),
                              let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
                            // Malformed/code-less callback: tell the browser and fail the flow.
                            sendResponse(connection: connection, status: "400 Bad Request", body: "Missing authorization code.")
                            continuation.resume(throwing: GoogleOAuthError.missingAuthorizationCode)
                            return
                        }

                        // Success: show a confirmation page, stop listening, return the code.
                        sendResponse(connection: connection, status: "200 OK", body: "Google sign-in complete. You can return to \(AppBranding.appName).")
                        listener.cancel()
                        continuation.resume(returning: code)
                    }
                }

                // Propagate a fatal listener failure (e.g. port already in use).
                listener.stateUpdateHandler = { state in
                    if case .failed(let error) = state {
                        continuation.resume(throwing: error)
                    }
                }

                listener.start(queue: queue)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Writes a minimal HTTP/1.1 response with an HTML body, then closes the connection.
    private static func sendResponse(connection: NWConnection, status: String, body: String) {
        let response = """
        HTTP/1.1 \(status)
        Content-Type: text/html; charset=utf-8
        Connection: close

        <html><body><p>\(body)</p></body></html>
        """
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
