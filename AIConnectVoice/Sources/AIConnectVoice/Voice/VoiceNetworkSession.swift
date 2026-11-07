// SPDX-License-Identifier: MIT
import Foundation
import AIConnect
import AIModelOptions

/// Shared HTTP/2 session plus a HEAD preconnect so the first spoken turn does
/// not pay DNS / TLS / connection setup.
public enum VoiceNetworkSession {
    public static let shared: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.httpShouldUsePipelining = true
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 180
        return URLSession(configuration: configuration)
    }()

    public static func preconnect(urls: [URL]) async {
        guard !urls.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for url in urls {
                group.addTask {
                    var request = URLRequest(url: url)
                    request.httpMethod = "HEAD"
                    request.timeoutInterval = 4
                    request.cachePolicy = .reloadIgnoringLocalCacheData
                    _ = try? await shared.data(for: request)
                }
            }
        }
    }
}
