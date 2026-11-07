// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import AnAIOdysseyCore
import AIModelOptions

/// Chat `web_search` tool: app-run engine (Brave default, optional SearXNG).
///
/// Registered when Chat web search is on and the engine is not the hosted AI
/// provider tool. Brave without a key (or a failed request) falls back to
/// Instant Answers and Wikipedia, never the unofficial HTML results page.
@MainActor
public struct ChatWebSearchTool: AgentTool {
    public let name = ChatWebSearchPolicy.fallbackToolName
    private let search: any WebSearchServiceProtocol
    private let engine: ChatWebSearchEngine
    private let braveAPIKey: String
    private let searxBaseURL: String

    public init(
        search: any WebSearchServiceProtocol,
        engine: ChatWebSearchEngine = .brave,
        braveAPIKey: String = "",
        searxBaseURL: String = ""
    ) {
        self.search = search
        self.engine = engine
        self.braveAPIKey = braveAPIKey
        self.searxBaseURL = searxBaseURL
    }

    public func execute(content: String, context: inout AgentContext) async throws -> String {
        _ = context
        let query = ChatWebSearchPolicy.searchQuery(fromToolInput: content)
        guard !query.isEmpty else {
            return "Search query is empty."
        }
        do {
            if let service = search as? WebSearchService {
                let outcome = try await service.searchForChat(
                    query: query,
                    engine: engine,
                    braveAPIKey: braveAPIKey,
                    searxBaseURL: searxBaseURL,
                    limit: 5
                )
                return ChatWebSearchPolicy.formatAppSearchResults(
                    actualEngine: outcome.actualEngine,
                    fallbackFrom: outcome.fallbackFrom,
                    fallbackReason: outcome.fallbackReason,
                    instantAnswer: outcome.instantAnswer,
                    pages: outcome.pages.map {
                        (title: $0.title, url: $0.url, snippet: $0.snippet, pageText: $0.pageText)
                    }
                )
            }
            let results = try await search.search(query: query, limit: 5)
            return ChatWebSearchPolicy.formatSearchResults(
                results.map { (title: $0.title, url: $0.url, snippet: $0.snippet) }
            )
        } catch {
            return ChatWebSearchPolicy.failedSearchToolOutput
        }
    }
}
