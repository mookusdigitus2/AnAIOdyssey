// SPDX-License-Identifier: MIT
#if canImport(Network)
import Foundation
import Network
import AIModelOptions

/// One-shot `127.0.0.1` HTTP listener for Sign in with ChatGPT.
///
/// OpenAI's open-source flow requires `http://127.0.0.1:<port>/auth/callback`.
/// Only the port may vary; `localhost` and `/callback` are rejected by the issuer.
/// The socket is bound to the loopback address, so nothing off-device can reach it.
/// iOS keeps it alive while the app's sign-in sheet is on screen.
public enum ChatGPTOAuthLoopback {
    public struct Listener: Sendable {
        public let port: UInt16
        public let redirectURI: String
        fileprivate let wait: @Sendable () async throws -> ChatGPTAuthorizationCallback
        fileprivate let cancel: @Sendable () -> Void

        public func result() async throws -> ChatGPTAuthorizationCallback {
            try await wait()
        }

        public func stop() {
            cancel()
        }
    }

    public static func start(path: String = ChatGPTOAuthCodec.callbackPath) async throws -> Listener {
        let queue = DispatchQueue(label: "chatgpt-oauth-loopback")
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)

        let portBox = PortBox()
        let state = CallbackState()

        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                // Browsers open speculative connections that never send a request.
                guard let data, let request = String(data: data, encoding: .utf8),
                      let requestLine = request.split(separator: "\r\n", maxSplits: 1).first,
                      let urlPart = requestLine.split(separator: " ").dropFirst().first else {
                    connection.cancel()
                    return
                }
                let raw = String(urlPart)
                guard let components = URLComponents(string: raw.hasPrefix("http") ? raw : "http://127.0.0.1\(raw)"),
                      components.path == path else {
                    // e.g. /favicon.ico: answer and keep waiting for the real callback.
                    sendResponse(connection: connection, status: "404 Not Found", body: "Not found.")
                    return
                }
                do {
                    let callback = try ChatGPTOAuthCodec.parseCallbackQuery(components.queryItems ?? [])
                    sendResponse(
                        connection: connection,
                        status: "200 OK",
                        body: "You can close this window and return to \(AIConnectBranding.appName)."
                    )
                    listener.cancel()
                    state.succeed(callback)
                } catch {
                    sendResponse(connection: connection, status: "400 Bad Request", body: error.localizedDescription)
                    listener.cancel()
                    state.fail(error)
                }
            }
        }

        listener.stateUpdateHandler = { listenerState in
            switch listenerState {
            case .ready:
                if let port = listener.port?.rawValue {
                    portBox.set(port)
                }
            case .failed(let error):
                portBox.fail(error)
                state.fail(error)
            default:
                break
            }
        }

        listener.start(queue: queue)
        let port = try await portBox.wait()
        return Listener(
            port: port,
            redirectURI: ChatGPTOAuthCodec.redirectURI(port: port),
            wait: { try await state.wait() },
            cancel: {
                listener.cancel()
                state.fail(ChatGPTAccountError.cancelled)
            }
        )
    }

    private static func sendResponse(connection: NWConnection, status: String, body: String) {
        let escaped = body
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let html = "<html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width\"></head><body style=\"font-family:-apple-system;padding:2em\"><p>\(escaped)</p></body></html>"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

/// Thread-safe one-shot value delivered from the listener queue to an async waiter.
private final class OneShot<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?

    func finish(_ value: Result<Value, Error>) {
        lock.lock()
        if result != nil {
            lock.unlock()
            return
        }
        result = value
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(with: value)
    }

    func wait() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }
}

private final class PortBox: @unchecked Sendable {
    private let box = OneShot<UInt16>()
    func set(_ port: UInt16) { box.finish(.success(port)) }
    func fail(_ error: Error) { box.finish(.failure(error)) }
    func wait() async throws -> UInt16 { try await box.wait() }
}

private final class CallbackState: @unchecked Sendable {
    private let box = OneShot<ChatGPTAuthorizationCallback>()
    func succeed(_ callback: ChatGPTAuthorizationCallback) { box.finish(.success(callback)) }
    func fail(_ error: Error) { box.finish(.failure(error)) }
    func wait() async throws -> ChatGPTAuthorizationCallback { try await box.wait() }
}
#endif
