// SPDX-License-Identifier: MIT
import Foundation

/// A source shown under a Chat reply that used the web.
public struct ChatWebSearchCitation: Equatable, Sendable, Hashable, Codable, Identifiable {
    public var title: String
    public var url: String
    public var domain: String

    public var id: String { url }

    public init(title: String, url: String, domain: String? = nil) {
        self.title = title
        self.url = url
        self.domain = domain ?? ChatWebSearchPolicy.domain(from: url)
    }
}

/// Disk form of a Chat reply that used the web: answer + titles/links, no snippets.
public struct ChatWebSearchPersistedMessage: Equatable, Sendable {
    public var answer: String
    public var citations: [ChatWebSearchCitation]
    public var attribution: String?
    public var metadata: String?

    public var serialized: String {
        answer + "\n" + (metadata ?? "")
    }

    public init(
        answer: String,
        citations: [ChatWebSearchCitation],
        attribution: String?,
        metadata: String?
    ) {
        self.answer = answer
        self.citations = citations
        self.attribution = attribution
        self.metadata = metadata
    }
}

/// How Chat should attach web search for one request.
public enum ChatWebSearchBackend: Equatable, Sendable {
    /// Toggle off: no search tool, and the model is told the web is unavailable.
    case none
    /// App-run `web_search` function tool (Brave, My Search Server, or quick facts).
    case appSearch
    /// OpenAI / xAI native Responses `web_search` hosted tool (opt-in).
    case hosted
}

/// Next hop after the selected Chat search engine fails.
public enum ChatWebSearchFallbackStep: Equatable, Sendable {
    case selectedEngine(ChatWebSearchEngine)
    /// Official Instant Answers + Wikipedia only — never the HTML results page.
    case quickFacts
}

/// Chat-only web search: Privacy toggle, request tools, citations, and off-state hint.
///
/// Research uses the same selected engine. This policy never injects
/// workspace documents, research items, or memories into the search tool.
public enum ChatWebSearchPolicy {
    public static let fallbackToolName = "web_search"
    public static let privacyToggleTitle = "Allow web search in Chat"
    /// Always pass the selected engine — never hard-code DuckDuckGo.
    public static let searchingStatus = "Searching the web…"
    public static let offHintText = "Web search is off."
    public static let turnOnButtonTitle = "Turn On"
    public static let searchUnreachableLine =
        "Couldn't reach a search service, so this answer doesn't use the web."
    public static let duckDuckGoUnreachableLine = searchUnreachableLine
    public static let toolbarGlobeAccessibilityLabel = "Web search is on"
    public static let usedWebSearchAccessibilityLabel = "Used web search"
    public static let failedSearchMarker = "WEB_SEARCH_FAILED"
    public static let fallbackMarker = "WEB_SEARCH_FALLBACK"
    public static let fallbackReasonMarker = "WEB_SEARCH_FALLBACK_REASON"
    public static let quickFactsOnlyLine =
        "Quick facts only. Add a free Brave key for full web results."
    public static let braveFailedLine = "Couldn't reach Brave, so this used quick facts."
    public static let searchServerFailedLine =
        "Couldn't reach your search server, so this used quick facts."
    public static let braveFallbackLine = braveFailedLine
    public static let searchServerFallbackLine = searchServerFailedLine
    public static let engineMarker = "WEB_SEARCH_ENGINE"
    public static let braveAttributionLine = BraveSearchCodec.attributionLine
    public static let braveCardFootnote = BraveSearchCodec.cardFootnote
    public static let getFreeKeyTitle = BraveSearchCodec.getFreeKeyTitle

    public static let unavailableSystemNote = """
        Web search is unavailable. Do not pretend to browse the web, fetch live pages, or invent current events, prices, or dates as if you looked them up. Answer from your own knowledge and say when something may be outdated.
        """

    public static let allowedSystemNote = """
        Web search is available for current facts. Send only search terms from the user's request — do not include workspace documents, research items, or memories unless the user put them in this prompt. If a tool result starts with WEB_SEARCH_FAILED, the search did not run — do not claim you used the web or cite live sources.
        """

    public static let appSearchToolCatalogDefault = """
        ## Web search
        ```web_search
        search terms from the user's request
        ```
        Search the web from this app. Send only search terms — do not include workspace documents, research items, or memories unless the user put them in this prompt. The tool result names the engine that actually answered.
        """

    public static let failedSearchToolOutput = """
        WEB_SEARCH_FAILED: Web search could not be reached. Do not claim you searched the web or cite live sources. Answer from your own knowledge and say the information may be outdated.
        """

    public static let hostedWebSearchTool: [String: Any] = ["type": "web_search"]

    public static var fallbackFunctionTool: [String: Any] {
        [
            "type": "function",
            "function": [
                "name": fallbackToolName,
                "description": "Search the public web. Pass only search terms from the user request — not workspace documents, research, or memories unless the user included them.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "query": [
                            "type": "string",
                            "description": "Search terms from the user's request.",
                        ],
                    ],
                    "required": ["query"],
                ] as [String: Any],
            ] as [String: Any],
        ]
    }

    private static let citationsMetadataKey = "webSearchCitations"
    private static let usedWebSearchMetadataKey = "usedWebSearch"
    private static let offHintMetadataKey = "webSearchOffHint"
    private static let searchFailedMetadataKey = "webSearchFailed"
    private static let fallbackNoticeMetadataKey = "webSearchFallbackNotice"
    private static let engineMetadataKey = "webSearchEngine"
    private static let rawResultMetadataKeys = ["snippet", "description", "pageText", "payload", "raw"]

    public static func supportsNativeWebSearch(baseURL: String?) -> Bool {
        guard let baseURL else { return false }
        return OpenAIRequestCodec.isOfficialOpenAIHost(baseURL) || OpenAIRequestCodec.isXAIHost(baseURL)
    }

    public static func effectiveEngine(
        isAllowed: Bool,
        selected: ChatWebSearchEngine,
        baseURL: String?
    ) -> ChatWebSearchEngine {
        guard isAllowed else { return .brave }
        if selected == .aiProvider {
            return supportsNativeWebSearch(baseURL: baseURL) ? .aiProvider : .brave
        }
        return selected == .quickFacts ? .brave : selected
    }

    /// Chosen engine, then official Instant Answers + Wikipedia.
    public static func fallbackChain(for selected: ChatWebSearchEngine) -> [ChatWebSearchFallbackStep] {
        switch selected {
        case .brave, .quickFacts:
            [.selectedEngine(.brave), .quickFacts]
        case .searchServer:
            [.selectedEngine(.searchServer), .quickFacts]
        case .aiProvider:
            []
        }
    }

    public static func fallbackLine(for reason: ChatWebSearchFallbackReason) -> String {
        switch reason {
        case .missingBraveKey: quickFactsOnlyLine
        case .braveFailed: braveFailedLine
        case .searchServerFailed: searchServerFailedLine
        }
    }

    public static func fallbackLine(forFailedEngine engine: ChatWebSearchEngine) -> String? {
        switch engine {
        case .brave: braveFailedLine
        case .searchServer: searchServerFailedLine
        case .aiProvider, .quickFacts: nil
        }
    }

    public static func isQuickFactsHint(_ notice: String?) -> Bool {
        notice == quickFactsOnlyLine
    }

    /// The no-key line is shown at most once per chat; failure lines always show.
    public static func noticeToPersist(
        reason: ChatWebSearchFallbackReason?,
        alreadyShowedQuickFactsHint: Bool
    ) -> String? {
        guard let reason else { return nil }
        if reason == .missingBraveKey {
            return alreadyShowedQuickFactsHint ? nil : quickFactsOnlyLine
        }
        return fallbackLine(for: reason)
    }

    public static func backend(
        isAllowed: Bool,
        engine: ChatWebSearchEngine = .brave,
        baseURL: String? = nil
    ) -> ChatWebSearchBackend {
        guard isAllowed else { return .none }
        if effectiveEngine(isAllowed: true, selected: engine, baseURL: baseURL) == .aiProvider {
            return .hosted
        }
        return .appSearch
    }

    public static func extraStructuredTools(backend: ChatWebSearchBackend) -> [[String: Any]] {
        switch backend {
        case .none:
            []
        case .hosted:
            [hostedWebSearchTool]
        case .appSearch:
            [fallbackFunctionTool]
        }
    }

    public static func systemNote(
        backend: ChatWebSearchBackend,
        engine: ChatWebSearchEngine = .brave
    ) -> String? {
        switch backend {
        case .none:
            unavailableSystemNote
        case .hosted:
            allowedSystemNote
        case .appSearch:
            allowedSystemNote + "\n\n" + appSearchToolCatalog(engine: engine)
        }
    }

    public static func appSearchToolCatalog(engine: ChatWebSearchEngine) -> String {
        switch engine {
        case .brave:
            """
            ## Web search
            ```web_search
            search terms from the user's request
            ```
            Search Brave Search from this app. Send only search terms — do not include workspace documents, research items, or memories unless the user put them in this prompt. The tool result names the engine that actually answered.
            """
        case .searchServer:
            """
            ## Web search
            ```web_search
            search terms from the user's request
            ```
            Search the user's SearXNG server from this app. Send only search terms — do not include workspace documents, research items, or memories unless the user put them in this prompt. The tool result names the engine that actually answered.
            """
        case .aiProvider:
            appSearchToolCatalogDefault
        case .quickFacts:
            """
            ## Web search
            ```web_search
            search terms from the user's request
            ```
            Search DuckDuckGo Instant Answers and Wikipedia from this app for quick facts. Send only search terms — do not include workspace documents, research items, or memories unless the user put them in this prompt. The tool result names the engine that actually answered.
            """
        }
    }

    public static func privacyFooter(engine: ChatWebSearchEngine) -> String {
        PrivacyDisclosures.chatWebSearchFooter(engine: engine)
    }

    public static func isFailedSearchOutput(_ text: String) -> Bool {
        text.contains(failedSearchMarker)
    }

    public static func containsHostedWebSearch(_ tools: [[String: Any]]) -> Bool {
        OpenAIRequestCodec.containsHostedWebSearch(tools)
    }

    public static func shouldForceResponsesAPI(backend: ChatWebSearchBackend, baseURL: String) -> Bool {
        backend == .hosted && supportsNativeWebSearch(baseURL: baseURL)
    }

    public static func searchQuery(fromToolInput content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["query", "input", "q", "search"] {
                if let value = object[key] as? String {
                    let query = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !query.isEmpty { return query }
                }
            }
        }
        if let first = trimmed.split(whereSeparator: \.isNewline).first {
            let line = String(first).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.lowercased().hasPrefix("query:") {
                return String(line.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return line
        }
        return trimmed
    }

    public static func formatSearchResults(
        _ results: [(title: String, url: String, snippet: String)]
    ) -> String {
        formatDuckDuckGoResults(
            instantAnswer: nil,
            pages: results.map { (title: $0.title, url: $0.url, snippet: $0.snippet, pageText: nil as String?) }
        )
    }

    public static func formatAppSearchResults(
        actualEngine: ChatWebSearchEngine,
        fallbackFrom: ChatWebSearchEngine? = nil,
        fallbackReason: ChatWebSearchFallbackReason? = nil,
        instantAnswer: DuckDuckGoInstantAnswer?,
        pages: [(title: String, url: String, snippet: String, pageText: String?)]
    ) -> String {
        let body = formatDuckDuckGoResults(instantAnswer: instantAnswer, pages: pages)
        var header = "ENGINE: \(actualEngine.modelName)\n\(engineMarker): \(actualEngine.rawValue)"
        let reason = fallbackReason ?? fallbackFrom.flatMap { failed -> ChatWebSearchFallbackReason? in
            switch failed {
            case .brave: .braveFailed
            case .searchServer: .searchServerFailed
            case .aiProvider, .quickFacts: nil
            }
        }
        if let reason {
            header += "\n\(fallbackReasonMarker): \(reason.rawValue)"
            header += "\n\(fallbackMarker): \(fallbackLine(for: reason))"
        }
        return header + "\n\n" + body
    }

    public static func parseActualEngine(from output: String) -> ChatWebSearchEngine? {
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix(engineMarker) else { continue }
            let rest = trimmed.dropFirst(engineMarker.count)
                .trimmingCharacters(in: CharacterSet(charactersIn: ": "))
            return ChatWebSearchEngine(rawValue: rest)
        }
        return nil
    }

    /// Citations that may be written to disk: title and URL only (no snippets).
    public static func persistableCitations(fromBrave results: [BraveSearchResult]) -> [ChatWebSearchCitation] {
        results.map { ChatWebSearchCitation(title: $0.title, url: $0.url) }
    }

    /// What Chat writes after a Brave-answered turn: the model’s reply plus
    /// source titles/links. Raw Brave snippets and page text stay out.
    public static func persistedChatMessage(
        answer: String,
        citations: [ChatWebSearchCitation],
        actualEngine: ChatWebSearchEngine,
        fallbackFrom: ChatWebSearchEngine? = nil,
        searchFailed: Bool = false
    ) -> ChatWebSearchPersistedMessage {
        let attribution = actualEngine == .brave ? braveAttributionLine : nil
        let metadata = mergeMetadata(
            existing: nil,
            citations: citations,
            usedWebSearch: !searchFailed && (actualEngine == .brave || !citations.isEmpty),
            showOffHint: false,
            searchFailed: searchFailed,
            fallbackNotice: fallbackFrom.flatMap(fallbackLine(forFailedEngine:)),
            actualEngine: actualEngine
        )
        return ChatWebSearchPersistedMessage(
            answer: answer,
            citations: citations,
            attribution: attribution,
            metadata: metadata
        )
    }

    public static func persistedFormContainsRawSnippets(
        answer: String,
        metadata: String?,
        snippets: [String]
    ) -> Bool {
        let blob = (answer + "\n" + (metadata ?? "")).lowercased()
        if rawResultMetadataKeys.contains(where: { blob.contains("\"\($0.lowercased())\"") }) {
            return true
        }
        return snippets.contains { snippet in
            let needle = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
            return !needle.isEmpty && blob.contains(needle.lowercased())
        }
    }

    public static func parseFallbackNotice(from output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix(fallbackMarker),
                  !trimmed.hasPrefix(fallbackReasonMarker) else { continue }
            let rest = trimmed.dropFirst(fallbackMarker.count)
                .trimmingCharacters(in: CharacterSet(charactersIn: ": "))
            return rest.isEmpty ? nil : rest
        }
        return nil
    }

    public static func parseFallbackReason(from output: String) -> ChatWebSearchFallbackReason? {
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix(fallbackReasonMarker) else { continue }
            let rest = trimmed.dropFirst(fallbackReasonMarker.count)
                .trimmingCharacters(in: CharacterSet(charactersIn: ": "))
            return ChatWebSearchFallbackReason(rawValue: rest)
        }
        return nil
    }

    public static func formatDuckDuckGoResults(
        instantAnswer: DuckDuckGoInstantAnswer?,
        pages: [(title: String, url: String, snippet: String, pageText: String?)]
    ) -> String {
        var parts: [String] = []
        if let instantAnswer, !instantAnswer.text.isEmpty {
            var line = "Instant answer"
            if !instantAnswer.heading.isEmpty {
                line += " (\(instantAnswer.heading))"
            }
            line += ": \(instantAnswer.text)"
            if !instantAnswer.url.isEmpty {
                line += "\n   \(instantAnswer.url)"
            }
            parts.append(line)
        }
        for (index, result) in pages.enumerated() {
            let title = result.title.isEmpty ? result.url : result.title
            var block = "\(index + 1). \(title)\n   \(result.url)"
            let snippet = result.snippet.trimmingCharacters(in: .whitespacesAndNewlines)
            if !snippet.isEmpty {
                block += "\n   \(snippet)"
            }
            if let pageText = result.pageText?.trimmingCharacters(in: .whitespacesAndNewlines),
               !pageText.isEmpty {
                block += "\n   Page text: \(pageText)"
            }
            parts.append(block)
        }
        return parts.isEmpty ? "No web results." : parts.joined(separator: "\n\n")
    }

    public static func domain(from url: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let host = URL(string: withScheme)?.host?.lowercased(), !host.isEmpty else {
            return trimmed
        }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    public static func parseCitations(
        from text: String,
        responseJSON: [String: Any]? = nil
    ) -> [ChatWebSearchCitation] {
        var seen: Set<String> = []
        var citations: [ChatWebSearchCitation] = []

        func append(title: String, url: String) {
            let normalized = normalizeURL(url)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { return }
            let resolvedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            citations.append(
                ChatWebSearchCitation(
                    title: resolvedTitle.isEmpty ? domain(from: normalized) : resolvedTitle,
                    url: normalized
                )
            )
        }

        collectCitations(from: responseJSON, into: &citations, seen: &seen)

        let numbered = try? NSRegularExpression(
            pattern: #"\[\[(\d+)\]\]\((https?://[^)\s]+)\)"#
        )
        let nsText = text as NSString
        let full = NSRange(location: 0, length: nsText.length)
        numbered?.matches(in: text, range: full).forEach { match in
            guard match.numberOfRanges >= 3 else { return }
            let url = nsText.substring(with: match.range(at: 2))
            append(title: domain(from: url), url: url)
        }

        let markdown = try? NSRegularExpression(
            pattern: #"\[([^\]\n]{1,120})\]\((https?://[^)\s]+)\)"#
        )
        markdown?.matches(in: text, range: full).forEach { match in
            guard match.numberOfRanges >= 3 else { return }
            append(
                title: nsText.substring(with: match.range(at: 1)),
                url: nsText.substring(with: match.range(at: 2))
            )
        }

        let bare = try? NSRegularExpression(pattern: #"https?://[^\s)\]>]+"#)
        if citations.isEmpty {
            bare?.matches(in: text, range: full).forEach { match in
                let url = nsText.substring(with: match.range)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))
                append(title: domain(from: url), url: url)
            }
        }

        return citations
    }

    public static func parseCitations(fromResponseJSON json: String) -> [ChatWebSearchCitation] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        return parseCitations(from: "", responseJSON: object)
    }

    public static func isWebSearchStreamEvent(_ type: String) -> Bool {
        type.contains("web_search")
    }

    public static func looksLikeCurrentEventsQuery(_ prompt: String) -> Bool {
        let lowered = prompt.lowercased()
        let keywords = [
            "latest", "today", "tonight", "news", "headline", "breaking",
            "current", "right now", "this morning", "this week", "this month",
            "yesterday", "live score", "who won", "what happened",
        ]
        if keywords.contains(where: { lowered.contains($0) }) {
            return true
        }
        if lowered.contains("price") || lowered.contains("stock") || lowered.contains("cost of") {
            return true
        }
        if lowered.contains("what day") || lowered.contains("what date") || lowered.contains("what year") {
            return true
        }
        if lowered.range(of: #"\b20\d{2}\b"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    public static func replySignalsNeedsWeb(_ reply: String) -> Bool {
        let lowered = reply.lowercased()
        let phrases = [
            "i don't have access to the internet",
            "i don't have access to the web",
            "i do not have access to the internet",
            "i do not have access to the web",
            "i can't browse",
            "i cannot browse",
            "i can't search the web",
            "i cannot search the web",
            "i don't have real-time",
            "i do not have real-time",
            "as of my last update",
            "my knowledge cutoff",
            "my knowledge cut-off",
            "would need to search",
            "need to look this up",
            "without web access",
            "web search is unavailable",
            "i can't check live",
            "i cannot check live",
        ]
        return phrases.contains { lowered.contains($0) }
    }

    /// Only for replies that look current-events-related. Never every message.
    public static func shouldShowOffHint(
        isAllowed: Bool,
        userPrompt: String,
        assistantReply: String
    ) -> Bool {
        guard !isAllowed else { return false }
        let prompt = userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let reply = assistantReply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !reply.isEmpty else { return false }
        return looksLikeCurrentEventsQuery(prompt) || replySignalsNeedsWeb(reply)
    }

    public static func mergeMetadata(
        existing: String?,
        citations: [ChatWebSearchCitation],
        usedWebSearch: Bool,
        showOffHint: Bool,
        searchFailed: Bool = false,
        fallbackNotice: String? = nil,
        actualEngine: ChatWebSearchEngine? = nil
    ) -> String? {
        var object: [String: Any] = [:]
        if let existing,
           let data = existing.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            object = parsed
        }
        if citations.isEmpty {
            object.removeValue(forKey: citationsMetadataKey)
        } else {
            object[citationsMetadataKey] = citations.map { citation in
                [
                    "title": citation.title,
                    "url": citation.url,
                    "domain": citation.domain,
                ]
            }
        }
        if usedWebSearch {
            object[usedWebSearchMetadataKey] = true
        } else {
            object.removeValue(forKey: usedWebSearchMetadataKey)
        }
        if showOffHint {
            object[offHintMetadataKey] = true
        } else {
            object.removeValue(forKey: offHintMetadataKey)
        }
        if searchFailed {
            object[searchFailedMetadataKey] = true
        } else {
            object.removeValue(forKey: searchFailedMetadataKey)
        }
        if let fallbackNotice, !fallbackNotice.isEmpty {
            object[fallbackNoticeMetadataKey] = fallbackNotice
        } else {
            object.removeValue(forKey: fallbackNoticeMetadataKey)
        }
        if let actualEngine {
            object[engineMetadataKey] = actualEngine.rawValue
        } else {
            object.removeValue(forKey: engineMetadataKey)
        }
        if actualEngine == .brave {
            for key in rawResultMetadataKeys {
                object.removeValue(forKey: key)
            }
        }
        guard !object.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else {
            return existing.flatMap { $0.isEmpty ? nil : $0 }
        }
        return text
    }

    public static func citations(from metadata: String?) -> [ChatWebSearchCitation] {
        guard let object = metadataObject(metadata),
              let rows = object[citationsMetadataKey] as? [[String: Any]] else {
            return []
        }
        return rows.compactMap { row in
            guard let url = row["url"] as? String, !url.isEmpty else { return nil }
            return ChatWebSearchCitation(
                title: (row["title"] as? String) ?? domain(from: url),
                url: url,
                domain: row["domain"] as? String
            )
        }
    }

    public static func usedWebSearch(from metadata: String?) -> Bool {
        metadataObject(metadata)?[usedWebSearchMetadataKey] as? Bool == true
    }

    public static func showOffHint(from metadata: String?) -> Bool {
        metadataObject(metadata)?[offHintMetadataKey] as? Bool == true
    }

    public static func searchFailed(from metadata: String?) -> Bool {
        metadataObject(metadata)?[searchFailedMetadataKey] as? Bool == true
    }

    public static func fallbackNotice(from metadata: String?) -> String? {
        guard let text = metadataObject(metadata)?[fallbackNoticeMetadataKey] as? String else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func persistedEngine(from metadata: String?) -> ChatWebSearchEngine? {
        guard let raw = metadataObject(metadata)?[engineMetadataKey] as? String else {
            return nil
        }
        return ChatWebSearchEngine(rawValue: raw)
    }

    public static func showsBraveAttribution(from metadata: String?) -> Bool {
        persistedEngine(from: metadata) == .brave
    }

    public static func shouldShowToolbarGlobe(isAllowed: Bool) -> Bool {
        isAllowed
    }

    public static func shouldShowPersistedOffHint(isAllowed: Bool, metadata: String?) -> Bool {
        !isAllowed && showOffHint(from: metadata)
    }

    // MARK: - Private

    private static func metadataObject(_ metadata: String?) -> [String: Any]? {
        guard let metadata,
              let data = metadata.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private static func normalizeURL(_ url: String) -> String {
        url.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;)]>\"'"))
    }

    private static func collectCitations(
        from object: [String: Any]?,
        into citations: inout [ChatWebSearchCitation],
        seen: inout Set<String>
    ) {
        guard let object else { return }

        func append(title: String, url: String) {
            let normalized = normalizeURL(url)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { return }
            let resolvedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            citations.append(
                ChatWebSearchCitation(
                    title: resolvedTitle.isEmpty ? domain(from: normalized) : resolvedTitle,
                    url: normalized
                )
            )
        }

        func walk(_ value: Any) {
            if let dictionary = value as? [String: Any] {
                let type = dictionary["type"] as? String
                if type == "url_citation" || dictionary["url_citation"] != nil {
                    let nested = dictionary["url_citation"] as? [String: Any]
                    let url = (nested?["url"] as? String)
                        ?? (dictionary["url"] as? String)
                        ?? ""
                    let title = (nested?["title"] as? String)
                        ?? (dictionary["title"] as? String)
                        ?? ""
                    if !url.isEmpty {
                        append(title: title, url: url)
                    }
                }
                if let url = dictionary["url"] as? String,
                   url.hasPrefix("http"),
                   type == "source" || dictionary["title"] != nil {
                    append(title: (dictionary["title"] as? String) ?? "", url: url)
                }
                for nested in dictionary.values {
                    walk(nested)
                }
            } else if let array = value as? [Any] {
                for item in array {
                    walk(item)
                }
            }
        }

        walk(object)
    }
}
