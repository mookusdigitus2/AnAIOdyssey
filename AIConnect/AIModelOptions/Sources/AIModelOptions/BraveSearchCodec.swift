// SPDX-License-Identifier: MIT
import Foundation

/// One Brave Search web result (title, destination URL, snippet).
public struct BraveSearchResult: Equatable, Sendable {
    public var title: String
    public var url: String
    public var snippet: String

    public init(title: String, url: String, snippet: String) {
        self.title = title
        self.url = url
        self.snippet = snippet
    }
}

/// Official Brave Search API helpers (`GET /res/v1/web/search`).
///
/// Auth is the `X-Subscription-Token` header. Results live under `web.results`
/// as `{title, url, description}`.
///
/// Brave’s terms allow only **temporary** storage of search results. The app
/// keeps payloads and snippets in memory for the current Chat turn, then
/// persists the model’s answer plus source titles and links — never raw
/// descriptions, page excerpts, or the JSON body. There is no result cache.
public enum BraveSearchCodec {
    public static let endpoint = "https://api.search.brave.com/res/v1/web/search"
    public static let signupURLString = "https://brave.com/search/api/"
    public static let subscriptionHeader = "X-Subscription-Token"
    public static let acceptHeader = "application/json"
    public static let freePlanNote =
        "The free plan includes $5 of credit a month (about 1,000 searches) and needs a card on file."
    public static let cardFootnote =
        "Brave asks for a card but doesn't charge within the free limit."
    public static let getFreeKeyTitle = "Get a free key"
    public static let attributionLine = "Search results from Brave"
    public static let testButtonTitle = "Test"
    /// Brave results are never written to a disk or memory cache.
    public static let cachesResults = false

    public static var signupURL: URL? {
        URL(string: signupURLString)
    }

    public static func searchURL(query: String, count: Int) -> URL? {
        var components = URLComponents(string: endpoint)
        let capped = max(1, min(count, 20))
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "count", value: String(capped)),
        ]
        return components?.url
    }

    /// Parses `web.results[{title,url,description}]` from a Brave JSON body.
    public static func parseResults(_ data: Data, limit: Int) -> [BraveSearchResult] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        let web = object["web"] as? [String: Any]
        let rows = (web?["results"] as? [[String: Any]]) ?? []
        let capped = max(1, limit)
        return rows.prefix(capped).compactMap { item in
            let title = (item["title"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let url = (item["url"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard url.hasPrefix("http") else { return nil }
            let snippet = (item["description"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return BraveSearchResult(
                title: title.isEmpty ? url : title,
                url: url,
                snippet: snippet
            )
        }
    }

    public static func isAuthOrQuotaFailure(statusCode: Int) -> Bool {
        statusCode == 401 || statusCode == 402 || statusCode == 403 || statusCode == 429
    }

    public enum ProbeStatus: Equatable, Sendable {
        case reachable
        case missingKey
        case rejected
        case unreachable
    }

    public static func mapProbe(statusCode: Int?, error: Error?, hasKey: Bool) -> ProbeStatus {
        if !hasKey { return .missingKey }
        if error != nil { return .unreachable }
        guard let statusCode else { return .unreachable }
        if (200...299).contains(statusCode) { return .reachable }
        if isAuthOrQuotaFailure(statusCode: statusCode) { return .rejected }
        return .unreachable
    }

    public static func probeMessage(_ status: ProbeStatus) -> String {
        switch status {
        case .reachable: "Connected"
        case .missingKey: "Add a Brave Search API key."
        case .rejected: "Brave Search rejected the API key."
        case .unreachable: "Couldn't reach Brave Search."
        }
    }

    public static func failureReason(statusCode: Int) -> String {
        switch statusCode {
        case 401, 403:
            "Brave Search rejected the API key."
        case 402:
            "Brave Search quota was exceeded."
        case 429:
            "Brave Search rate-limited the request."
        default:
            "Brave Search HTTP \(statusCode)"
        }
    }
}
