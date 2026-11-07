// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import AnAIOdysseyCore
import AIModelOptions

/// A single web-search hit (title, URL, snippet) consumed by the Research feature and agent tools.
public struct WebSearchResult: Sendable, Identifiable, Hashable, Equatable {
    public let id: String
    public let title: String
    public let url: String
    public let snippet: String

    public init(id: String = UUID().uuidString, title: String, url: String, snippet: String) {
        self.id = id
        self.title = title
        self.url = url
        self.snippet = snippet
    }
}

/// Errors surfaced by web search, with display-ready descriptions.
public enum WebSearchError: Error, LocalizedError {
    case invalidQuery
    case requestFailed(String)
    case parseFailed

    public var errorDescription: String? {
        switch self {
        case .invalidQuery:
            "Search query is empty."
        case .requestFailed(let message):
            "Search request failed: \(message)"
        case .parseFailed:
            "Could not parse search results."
        }
    }
}

/// Abstraction over a web-search provider so the app can swap real and mock implementations.
@MainActor
public protocol WebSearchServiceProtocol: AnyObject {
    /// Returns up to `limit` results for `query`, throwing `WebSearchError` on failure.
    func search(query: String, limit: Int) async throws -> [WebSearchResult]
}

/// Real web search for Chat and Research using the selected engine.
///
/// Brave is the default. My Search Server (SearXNG) is opt-in. When Brave has
/// no key or fails, and the selected engine is not a working search server,
/// the only fallback is official Instant Answers plus Wikipedia.
@MainActor
public final class WebSearchService: WebSearchServiceProtocol {
    private let session: URLSession
    /// Optional base URL of a self-hosted SearXNG instance; enables that tier when set.
    private let searxBaseURL: String?

    public init(session: URLSession = .shared, searxBaseURL: String? = nil) {
        self.session = session
        self.searxBaseURL = searxBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Init override if set; otherwise the shared Chat/Research UserDefaults address.
    public func resolvedSearxBaseURL() -> String {
        if let searxBaseURL, !searxBaseURL.isEmpty {
            return searxBaseURL
        }
        return AIDataAccess.searxBaseURL
    }

    public func resolvedEngine() -> ChatWebSearchEngine {
        ChatWebSearchEngine.resolvedSelectable(
            UserDefaults.standard.string(forKey: AIDataAccess.chatWebSearchEngineKey)
        )
    }

    public func resolvedBraveAPIKey() -> String {
        RemoteAPIKeyStore().apiKey(for: AIDataAccess.braveSearchKeyAccount)
    }

    /// Research and Settings use the same selected engine as Chat.
    public func search(query: String, limit: Int = 5) async throws -> [WebSearchResult] {
        let outcome = try await searchUsingSelectedEngine(query: query, limit: limit)
        return outcome.results
    }

    public func searchUsingSelectedEngine(
        query: String,
        limit: Int = 5,
        engine: ChatWebSearchEngine? = nil,
        braveAPIKey: String? = nil,
        searxBaseURL: String? = nil
    ) async throws -> WebSearchOutcome {
        let selected = engine.flatMap { $0.isSelectable ? $0 : nil } ?? resolvedEngine()
        let chat = try await searchForChat(
            query: query,
            engine: selected,
            braveAPIKey: braveAPIKey ?? resolvedBraveAPIKey(),
            searxBaseURL: searxBaseURL,
            limit: limit,
            fetchPageText: false
        )
        return WebSearchOutcome(
            results: chat.pages.map {
                WebSearchResult(title: $0.title, url: $0.url, snippet: $0.snippet)
            },
            actualEngine: chat.actualEngine,
            fallbackReason: chat.fallbackReason,
            instantAnswer: chat.instantAnswer
        )
    }

    /// Chat search for the selected engine, with Instant Answer + Wikipedia fallback.
    public func searchForChat(
        query: String,
        engine: ChatWebSearchEngine,
        braveAPIKey: String = "",
        searxBaseURL: String? = nil,
        limit: Int = 5,
        fetchPageText: Bool = true
    ) async throws -> ChatWebSearchOutcome {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw WebSearchError.invalidQuery
        }
        let selected = engine == .quickFacts ? .brave : engine
        switch selected {
        case .brave, .aiProvider, .quickFacts:
            return try await searchBraveThenQuickFacts(
                query: trimmed,
                apiKey: braveAPIKey,
                limit: limit,
                fetchPageText: fetchPageText
            )
        case .searchServer:
            return try await searchServerThenQuickFacts(
                query: trimmed,
                searxBaseURL: searxBaseURL,
                limit: limit,
                fetchPageText: fetchPageText
            )
        }
    }

    public func probeSearchServer(baseURL: String) async -> SearXNGProbeStatus {
        guard let url = SearXNGSearchCodec.probeURL(baseURL: baseURL) else {
            return .unreachable
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10
        do {
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            return SearXNGSearchCodec.mapProbe(
                statusCode: http?.statusCode,
                contentType: http?.value(forHTTPHeaderField: "Content-Type"),
                body: data,
                error: nil
            )
        } catch {
            return SearXNGSearchCodec.mapProbe(
                statusCode: nil,
                contentType: nil,
                body: Data(),
                error: error
            )
        }
    }

    public func probeBraveSearch(apiKey: String) async -> BraveSearchCodec.ProbeStatus {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return .missingKey }
        guard let url = BraveSearchCodec.searchURL(query: "test", count: 1) else {
            return .unreachable
        }
        var request = URLRequest(url: url)
        request.setValue(key, forHTTPHeaderField: BraveSearchCodec.subscriptionHeader)
        request.setValue(BraveSearchCodec.acceptHeader, forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10
        do {
            let (_, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode
            return BraveSearchCodec.mapProbe(statusCode: code, error: nil, hasKey: true)
        } catch {
            return BraveSearchCodec.mapProbe(statusCode: nil, error: error, hasKey: true)
        }
    }

    /// In-memory only for this call. Brave terms forbid caching or persisting
    /// raw result payloads; Chat keeps snippets for the turn, then stores the
    /// model’s answer plus titles and links.
    private func braveSearch(query: String, apiKey: String, limit: Int) async throws -> [WebSearchResult] {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw WebSearchError.requestFailed("Brave Search API key is missing.")
        }
        guard let url = BraveSearchCodec.searchURL(query: query, count: limit) else {
            throw WebSearchError.requestFailed("Invalid Brave Search URL.")
        }

        var request = URLRequest(url: url)
        request.setValue(key, forHTTPHeaderField: BraveSearchCodec.subscriptionHeader)
        request.setValue(BraveSearchCodec.acceptHeader, forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw WebSearchError.requestFailed("Brave Search returned no response.")
        }
        guard (200...299).contains(http.statusCode) else {
            throw WebSearchError.requestFailed(BraveSearchCodec.failureReason(statusCode: http.statusCode))
        }

        return BraveSearchCodec.parseResults(data, limit: limit).map {
            WebSearchResult(title: $0.title, url: $0.url, snippet: $0.snippet)
        }
    }

    private func searchBraveThenQuickFacts(
        query: String,
        apiKey: String,
        limit: Int,
        fetchPageText: Bool
    ) async throws -> ChatWebSearchOutcome {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            return try await quickFactsOutcome(
                query: query,
                limit: limit,
                reason: .missingBraveKey
            )
        }
        do {
            let results = try await braveSearch(query: query, apiKey: key, limit: limit)
            guard !results.isEmpty else {
                return try await quickFactsOutcome(
                    query: query,
                    limit: limit,
                    reason: .braveFailed
                )
            }
            return await assembleChatOutcome(
                results: results,
                actualEngine: .brave,
                fallbackReason: nil,
                fetchPageText: fetchPageText
            )
        } catch {
            return try await quickFactsOutcome(
                query: query,
                limit: limit,
                reason: .braveFailed
            )
        }
    }

    private func searchServerThenQuickFacts(
        query: String,
        searxBaseURL: String?,
        limit: Int,
        fetchPageText: Bool
    ) async throws -> ChatWebSearchOutcome {
        let base = (searxBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
            $0.isEmpty ? nil : $0
        } ?? resolvedSearxBaseURL()
        do {
            guard !base.isEmpty else {
                throw WebSearchError.requestFailed("Search server address is missing.")
            }
            let results = try await searxSearch(query: query, limit: limit, baseURL: base)
            guard !results.isEmpty else {
                throw WebSearchError.requestFailed("Search server returned no results.")
            }
            return await assembleChatOutcome(
                results: results,
                actualEngine: .searchServer,
                fallbackReason: nil,
                fetchPageText: fetchPageText
            )
        } catch {
            return try await quickFactsOutcome(
                query: query,
                limit: limit,
                reason: .searchServerFailed
            )
        }
    }

    private func quickFactsOutcome(
        query: String,
        limit: Int,
        reason: ChatWebSearchFallbackReason
    ) async throws -> ChatWebSearchOutcome {
        let instant = await fetchInstantAnswer(query: query)
        let wiki = (try? await wikipediaSearch(query: query, limit: limit)) ?? []
        var pages: [ChatWebSearchPage] = []
        if let instant, !instant.url.isEmpty {
            pages.append(
                ChatWebSearchPage(
                    title: instant.heading.isEmpty ? "Instant answer" : instant.heading,
                    url: instant.url,
                    snippet: instant.text,
                    pageText: nil
                )
            )
        }
        for result in wiki {
            if pages.contains(where: { $0.url == result.url }) { continue }
            pages.append(
                ChatWebSearchPage(
                    title: result.title,
                    url: result.url,
                    snippet: result.snippet,
                    pageText: nil
                )
            )
        }
        if instant == nil && pages.isEmpty {
            throw WebSearchError.requestFailed("Quick facts unavailable.")
        }
        return ChatWebSearchOutcome(
            actualEngine: .quickFacts,
            fallbackReason: reason,
            instantAnswer: instant,
            pages: pages
        )
    }

    private func assembleChatOutcome(
        results: [WebSearchResult],
        actualEngine: ChatWebSearchEngine,
        fallbackReason: ChatWebSearchFallbackReason?,
        fetchPageText: Bool
    ) async -> ChatWebSearchOutcome {
        var pages: [ChatWebSearchPage] = []
        for result in results.prefix(DuckDuckGoSearchCodec.pageFetchCount) {
            let text = fetchPageText ? await fetchReadablePage(urlString: result.url) : nil
            pages.append(
                ChatWebSearchPage(
                    title: result.title,
                    url: result.url,
                    snippet: result.snippet,
                    pageText: text
                )
            )
        }
        return ChatWebSearchOutcome(
            actualEngine: actualEngine,
            fallbackReason: fallbackReason,
            instantAnswer: nil,
            pages: pages
        )
    }

    /// Queries Wikipedia's `opensearch` API, which returns parallel arrays of titles, descriptions, and URLs.
    private func wikipediaSearch(query: String, limit: Int) async throws -> [WebSearchResult] {
        var components = URLComponents(string: "https://en.wikipedia.org/w/api.php")!
        components.queryItems = [
            URLQueryItem(name: "action", value: "opensearch"),
            URLQueryItem(name: "search", value: query),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "namespace", value: "0"),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let url = components.url else {
            throw WebSearchError.requestFailed("Invalid Wikipedia search URL.")
        }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw WebSearchError.requestFailed("Wikipedia HTTP error.")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [Any],
              json.count >= 4,
              let titles = json[1] as? [String],
              let descriptions = json[2] as? [String],
              let urls = json[3] as? [String] else {
            throw WebSearchError.parseFailed
        }

        return zip(zip(titles, descriptions), urls).map { pair, url in
            let (title, description) = pair
            return WebSearchResult(
                title: title,
                url: url,
                snippet: description.isEmpty ? "Wikipedia article." : description
            )
        }
    }

    /// Queries a self-hosted SearXNG instance's JSON API and maps its `results` array.
    private func searxSearch(query: String, limit: Int, baseURL: String) async throws -> [WebSearchResult] {
        guard let url = SearXNGSearchCodec.searchURL(baseURL: baseURL, query: query) else {
            throw WebSearchError.requestFailed("Invalid SearXNG URL.")
        }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw WebSearchError.requestFailed("SearXNG HTTP \(code)")
        }

        if SearXNGSearchCodec.looksLikeHTML(contentType: http.value(forHTTPHeaderField: "Content-Type"), body: data) {
            throw WebSearchError.requestFailed("SearXNG returned HTML instead of JSON.")
        }

        let parsed = SearXNGSearchCodec.parseResults(data, limit: limit)
        return parsed.map {
            WebSearchResult(title: $0.title, url: $0.url, snippet: $0.snippet)
        }
    }

    private func fetchInstantAnswer(query: String) async -> DuckDuckGoInstantAnswer? {
        guard let url = DuckDuckGoSearchCodec.instantAnswerURL(query: query) else { return nil }
        var request = URLRequest(url: url)
        request.setValue(DuckDuckGoSearchCodec.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 8
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return nil
            }
            return DuckDuckGoSearchCodec.parseInstantAnswer(json: data)
        } catch {
            return nil
        }
    }

    private func fetchReadablePage(urlString: String) async -> String? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.setValue(DuckDuckGoSearchCodec.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = DuckDuckGoSearchCodec.pageFetchTimeout
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return nil
            }
            let capped = data.prefix(DuckDuckGoSearchCodec.pageFetchByteCap)
            guard let html = String(data: Data(capped), encoding: .utf8)
                    ?? String(data: Data(capped), encoding: .isoLatin1) else {
                return nil
            }
            let text = DuckDuckGoSearchCodec.readableText(fromHTML: html)
            return text.isEmpty ? nil : text
        } catch {
            return nil
        }
    }
}

/// One Chat search hit, optionally with on-device readable page text.
public struct ChatWebSearchPage: Sendable {
    public var title: String
    public var url: String
    public var snippet: String
    public var pageText: String?

    public init(title: String, url: String, snippet: String, pageText: String?) {
        self.title = title
        self.url = url
        self.snippet = snippet
        self.pageText = pageText
    }
}

/// Chat search payload that names the engine that actually answered.
public struct ChatWebSearchOutcome: Sendable {
    public var actualEngine: ChatWebSearchEngine
    public var fallbackReason: ChatWebSearchFallbackReason?
    public var instantAnswer: DuckDuckGoInstantAnswer?
    public var pages: [ChatWebSearchPage]

    public var fallbackFrom: ChatWebSearchEngine? {
        switch fallbackReason {
        case .missingBraveKey, .braveFailed: .brave
        case .searchServerFailed: .searchServer
        case nil: nil
        }
    }

    public init(
        actualEngine: ChatWebSearchEngine,
        fallbackReason: ChatWebSearchFallbackReason?,
        instantAnswer: DuckDuckGoInstantAnswer?,
        pages: [ChatWebSearchPage]
    ) {
        self.actualEngine = actualEngine
        self.fallbackReason = fallbackReason
        self.instantAnswer = instantAnswer
        self.pages = pages
    }
}

/// Research/Settings search payload with the engine that actually answered.
public struct WebSearchOutcome: Sendable {
    public var results: [WebSearchResult]
    public var actualEngine: ChatWebSearchEngine
    public var fallbackReason: ChatWebSearchFallbackReason?
    public var instantAnswer: DuckDuckGoInstantAnswer?
}

/// Offline stand-in for `WebSearchService` that fabricates deterministic results, for previews/tests/offline use.
@MainActor
public final class MockWebSearchService: WebSearchServiceProtocol {
    public init() {}

    /// Returns synthetic results derived from the query, honoring the same 1...10 limit clamp as the real service.
    public func search(query: String, limit: Int = 5) async throws -> [WebSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let cappedLimit = max(1, min(limit, 10))
        return (1...cappedLimit).map { index in
            WebSearchResult(
                title: "Result \(index): \(trimmed)",
                url: "https://example.com/search?q=\(index)",
                snippet: "Mock search snippet \(index) discussing \(trimmed)."
            )
        }
    }
}
