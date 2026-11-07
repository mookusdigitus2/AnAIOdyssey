// SPDX-License-Identifier: MIT
import Foundation

/// One SearXNG JSON result (title, destination URL, snippet).
public struct SearXNGSearchResult: Equatable, Sendable {
    public var title: String
    public var url: String
    public var snippet: String

    public init(title: String, url: String, snippet: String) {
        self.title = title
        self.url = url
        self.snippet = snippet
    }
}

/// Outcome of the Settings Test button for My Search Server (SearXNG).
public enum SearXNGProbeStatus: Equatable, Sendable {
    case reachable
    case unreachable
    case needsJSONOrLimiter
}

/// SearXNG JSON API helpers (`GET /search?q=&format=json`).
///
/// Results live under `results` as `{title, url, content}`. The Test button
/// probes `/search?q=test&format=json`.
public enum SearXNGSearchCodec {
    public static let unreachableMessage = "Can't reach it. Is your VPN on?"
    public static let needsJSONOrLimiterMessage =
        "JSON output must be enabled on this SearXNG instance, and the limiter must allow this device."
    public static let reachableMessage = "Connected"
    public static let helpText =
        "Address of your SearXNG search server. Chat and Research share this address. Turn on your VPN if the server is only reachable that way (for example over Tailscale)."

    public static func normalizeBaseURL(_ raw: String) -> String? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        if URLComponents(string: trimmed)?.scheme == nil {
            trimmed = "https://\(trimmed)"
        }
        guard let url = URL(string: trimmed), url.host != nil else {
            return nil
        }
        return trimmed
    }

    public static func searchURL(baseURL: String, query: String) -> URL? {
        guard let normalized = normalizeBaseURL(baseURL) else { return nil }
        guard var components = URLComponents(string: normalized + "/search") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "categories", value: "general"),
        ]
        return components.url
    }

    public static func probeURL(baseURL: String) -> URL? {
        searchURL(baseURL: baseURL, query: "test")
    }

    /// Parses `results[{title,url,content}]` from a SearXNG JSON body.
    public static func parseResults(_ data: Data, limit: Int) -> [SearXNGSearchResult] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["results"] as? [[String: Any]] else {
            return []
        }
        let capped = max(1, limit)
        return rows.prefix(capped).compactMap { item in
            let title = (item["title"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let url = (item["url"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard url.hasPrefix("http") else { return nil }
            let snippet = (item["content"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                ?? (item["snippet"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? ""
            return SearXNGSearchResult(
                title: title.isEmpty ? url : title,
                url: url,
                snippet: snippet
            )
        }
    }

    public static func looksLikeHTML(contentType: String?, body: Data) -> Bool {
        let type = contentType?.lowercased() ?? ""
        if type.contains("text/html") {
            return true
        }
        let text = String(data: body, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        return text.hasPrefix("<!doctype") || text.hasPrefix("<html") || text.contains("<html")
    }

    public static func isJSONObject(_ data: Data) -> Bool {
        (try? JSONSerialization.jsonObject(with: data)) is [String: Any]
    }

    /// Maps a Test-button HTTP response (or transport error) to a UI status.
    public static func mapProbe(
        statusCode: Int?,
        contentType: String?,
        body: Data,
        error: Error?
    ) -> SearXNGProbeStatus {
        if error != nil, statusCode == nil {
            return .unreachable
        }
        guard let statusCode else {
            return .unreachable
        }
        if statusCode == 403 || statusCode == 429 {
            return .needsJSONOrLimiter
        }
        if looksLikeHTML(contentType: contentType, body: body) {
            return .needsJSONOrLimiter
        }
        if (200...299).contains(statusCode), isJSONObject(body) {
            return .reachable
        }
        if (200...299).contains(statusCode) {
            return .needsJSONOrLimiter
        }
        return .unreachable
    }

    public static func probeMessage(_ status: SearXNGProbeStatus) -> String {
        switch status {
        case .reachable: reachableMessage
        case .unreachable: unreachableMessage
        case .needsJSONOrLimiter: needsJSONOrLimiterMessage
        }
    }
}
