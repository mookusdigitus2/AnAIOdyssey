// SPDX-License-Identifier: MIT
import XCTest
@testable import AIModelOptions

final class ChatWebSearchPolicyTests: XCTestCase {
    func testToggleOffOmitsToolsAndAddsUnavailableNote() {
        let backend = ChatWebSearchPolicy.backend(
            isAllowed: false,
            engine: .brave,
            baseURL: "https://api.openai.com/v1"
        )
        XCTAssertEqual(backend, .none)
        XCTAssertTrue(ChatWebSearchPolicy.extraStructuredTools(backend: backend).isEmpty)
        XCTAssertEqual(
            ChatWebSearchPolicy.systemNote(backend: backend),
            ChatWebSearchPolicy.unavailableSystemNote
        )
        XCTAssertFalse(ChatWebSearchPolicy.shouldShowToolbarGlobe(isAllowed: false))
    }

    func testDefaultEngineIsBraveForEveryProvider() {
        for host in [
            "https://api.openai.com/v1",
            "https://api.x.ai/v1",
            "https://openrouter.ai/api/v1",
            "http://localhost:1234/v1",
            nil,
        ] {
            let backend = ChatWebSearchPolicy.backend(
                isAllowed: true,
                engine: .brave,
                baseURL: host
            )
            XCTAssertEqual(backend, .appSearch, host ?? "local")
            let tools = ChatWebSearchPolicy.extraStructuredTools(backend: backend)
            XCTAssertEqual(tools.count, 1, host ?? "local")
            XCTAssertEqual(tools[0]["type"] as? String, "function")
            let function = tools[0]["function"] as? [String: Any]
            XCTAssertEqual(function?["name"] as? String, "web_search")
            XCTAssertFalse(ChatWebSearchPolicy.containsHostedWebSearch(tools))
            XCTAssertFalse(
                ChatWebSearchPolicy.shouldForceResponsesAPI(
                    backend: backend,
                    baseURL: host ?? "http://localhost"
                )
            )
        }
        XCTAssertTrue(ChatWebSearchPolicy.shouldShowToolbarGlobe(isAllowed: true))
    }

    func testProviderEngineUsesHostedToolOnOpenAIAndXAI() {
        for host in ["https://api.openai.com/v1", "https://api.x.ai/v1"] {
            let backend = ChatWebSearchPolicy.backend(
                isAllowed: true,
                engine: .aiProvider,
                baseURL: host
            )
            XCTAssertEqual(backend, .hosted, host)
            let tools = ChatWebSearchPolicy.extraStructuredTools(backend: backend)
            XCTAssertEqual(tools[0]["type"] as? String, "web_search")
            XCTAssertNil(tools[0]["function"])
            XCTAssertTrue(ChatWebSearchPolicy.containsHostedWebSearch(tools))
            XCTAssertTrue(ChatWebSearchPolicy.shouldForceResponsesAPI(backend: backend, baseURL: host))
        }
        XCTAssertTrue(
            OpenAIRequestCodec.shouldUseResponsesAPI(
                baseURL: "https://api.x.ai/v1",
                model: "grok-2",
                hasTools: true,
                hasHostedWebSearch: true
            )
        )
    }

    func testProviderEngineFallsBackToBraveWithoutNativeSearch() {
        let backend = ChatWebSearchPolicy.backend(
            isAllowed: true,
            engine: .aiProvider,
            baseURL: "https://openrouter.ai/api/v1"
        )
        XCTAssertEqual(backend, .appSearch)
        XCTAssertEqual(
            ChatWebSearchPolicy.effectiveEngine(
                isAllowed: true,
                selected: .aiProvider,
                baseURL: "https://openrouter.ai/api/v1"
            ),
            .brave
        )
    }

    func testCitationParsingFromURLCitationAnnotations() {
        let json = """
        {
          "type": "response.completed",
          "response": {
            "output": [{
              "type": "message",
              "content": [{
                "type": "output_text",
                "text": "Paris is mild today.",
                "annotations": [{
                  "type": "url_citation",
                  "url_citation": {
                    "url": "https://weather.example/paris",
                    "title": "Paris weather"
                  }
                }]
              }]
            }]
          }
        }
        """
        let citations = ChatWebSearchPolicy.parseCitations(fromResponseJSON: json)
        XCTAssertEqual(citations.count, 1)
        XCTAssertEqual(citations[0].title, "Paris weather")
        XCTAssertEqual(citations[0].url, "https://weather.example/paris")
        XCTAssertEqual(citations[0].domain, "weather.example")
    }

    func testCitationParsingFromMarkdownAndIndexedLinks() {
        let text = """
        Latest score is in. [BBC Sport](https://www.bbc.com/sport/123) and [[2]](https://espn.com/game)
        """
        let citations = ChatWebSearchPolicy.parseCitations(from: text)
        XCTAssertEqual(citations.map(\.url), [
            "https://espn.com/game",
            "https://www.bbc.com/sport/123",
        ])
        XCTAssertEqual(citations.first { $0.url.contains("bbc") }?.domain, "bbc.com")
    }

    func testCurrentEventsHeuristicAndOffHint() {
        XCTAssertTrue(ChatWebSearchPolicy.looksLikeCurrentEventsQuery("What's the latest news?"))
        XCTAssertFalse(ChatWebSearchPolicy.looksLikeCurrentEventsQuery("Summarize this note"))
        XCTAssertTrue(
            ChatWebSearchPolicy.shouldShowOffHint(
                isAllowed: false,
                userPrompt: "What's the latest news?",
                assistantReply: "I can only speak from training data."
            )
        )
        XCTAssertFalse(
            ChatWebSearchPolicy.shouldShowOffHint(
                isAllowed: false,
                userPrompt: "How do I boil an egg?",
                assistantReply: "Simmer for about 8 minutes."
            )
        )
        XCTAssertFalse(
            ChatWebSearchPolicy.shouldShowOffHint(
                isAllowed: true,
                userPrompt: "What's the latest news?",
                assistantReply: "Here are today's headlines."
            )
        )
    }

    func testFailedSearchOutput() {
        XCTAssertTrue(ChatWebSearchPolicy.isFailedSearchOutput(ChatWebSearchPolicy.failedSearchToolOutput))
        XCTAssertFalse(ChatWebSearchPolicy.isFailedSearchOutput("1. Example\n   https://example.com"))
        let metadata = ChatWebSearchPolicy.mergeMetadata(
            existing: nil,
            citations: [],
            usedWebSearch: false,
            showOffHint: false,
            searchFailed: true
        )
        XCTAssertTrue(ChatWebSearchPolicy.searchFailed(from: metadata))
        XCTAssertEqual(
            ChatWebSearchPolicy.searchUnreachableLine,
            "Couldn't reach a search service, so this answer doesn't use the web."
        )
    }

    func testPrivacyFootersFollowEngine() {
        XCTAssertEqual(
            ChatWebSearchPolicy.privacyFooter(engine: .brave),
            PrivacyDisclosures.chatBraveFooter
        )
        XCTAssertEqual(
            ChatWebSearchPolicy.privacyFooter(engine: .aiProvider),
            PrivacyDisclosures.chatProviderFooter
        )
        XCTAssertEqual(
            ChatWebSearchPolicy.privacyFooter(engine: .searchServer),
            PrivacyDisclosures.chatSearchServerFooter
        )
        XCTAssertEqual(
            ChatWebSearchPolicy.privacyFooter(engine: .quickFacts),
            PrivacyDisclosures.chatQuickFactsFooter
        )
        XCTAssertTrue(PrivacyDisclosures.chatBraveFooter.contains("Brave Search"))
        XCTAssertTrue(PrivacyDisclosures.chatBraveFooter.contains("go to Brave Search"))
        XCTAssertTrue(PrivacyDisclosures.chatProviderFooter.contains("bill"))
        XCTAssertTrue(PrivacyDisclosures.chatSearchServerFooter.contains("your own search server"))
        XCTAssertTrue(PrivacyDisclosures.chatQuickFactsFooter.contains("Instant Answers"))
        XCTAssertFalse(PrivacyDisclosures.chatBraveFooter.contains("DuckDuckGo"))
    }

    func testEffectiveEngineKeepsBraveAndSearchServer() {
        XCTAssertEqual(
            ChatWebSearchPolicy.effectiveEngine(
                isAllowed: true,
                selected: .brave,
                baseURL: "https://api.openai.com/v1"
            ),
            .brave
        )
        XCTAssertEqual(
            ChatWebSearchPolicy.effectiveEngine(
                isAllowed: true,
                selected: .searchServer,
                baseURL: nil
            ),
            .searchServer
        )
        XCTAssertEqual(
            ChatWebSearchPolicy.backend(isAllowed: true, engine: .brave, baseURL: nil),
            .appSearch
        )
        XCTAssertEqual(
            ChatWebSearchPolicy.backend(isAllowed: true, engine: .searchServer, baseURL: nil),
            .appSearch
        )
    }

    func testFallbackChainAndNoticeCopy() {
        XCTAssertEqual(
            ChatWebSearchPolicy.fallbackChain(for: .brave),
            [.selectedEngine(.brave), .quickFacts]
        )
        XCTAssertEqual(
            ChatWebSearchPolicy.fallbackChain(for: .searchServer),
            [.selectedEngine(.searchServer), .quickFacts]
        )
        XCTAssertEqual(ChatWebSearchPolicy.fallbackChain(for: .aiProvider), [])
        XCTAssertEqual(
            ChatWebSearchPolicy.fallbackLine(for: .braveFailed),
            "Couldn't reach Brave, so this used quick facts."
        )
        XCTAssertEqual(
            ChatWebSearchPolicy.fallbackLine(for: .searchServerFailed),
            "Couldn't reach your search server, so this used quick facts."
        )
        XCTAssertEqual(
            ChatWebSearchPolicy.fallbackLine(for: .missingBraveKey),
            "Quick facts only. Add a free Brave key for full web results."
        )
        XCTAssertEqual(
            ChatWebSearchPolicy.quickFactsOnlyLine,
            "Quick facts only. Add a free Brave key for full web results."
        )

        let formatted = ChatWebSearchPolicy.formatAppSearchResults(
            actualEngine: .quickFacts,
            fallbackFrom: .brave,
            instantAnswer: nil,
            pages: [(title: "Iceland", url: "https://en.wikipedia.org/wiki/Iceland", snippet: "Nordic", pageText: nil)]
        )
        XCTAssertTrue(formatted.contains("ENGINE: quick facts"))
        XCTAssertTrue(formatted.contains("WEB_SEARCH_FALLBACK: Couldn't reach Brave, so this used quick facts."))
        XCTAssertEqual(
            ChatWebSearchPolicy.parseFallbackNotice(from: formatted),
            "Couldn't reach Brave, so this used quick facts."
        )
        XCTAssertEqual(ChatWebSearchPolicy.parseFallbackReason(from: formatted), .braveFailed)
        XCTAssertEqual(ChatWebSearchPolicy.parseActualEngine(from: formatted), .quickFacts)

        let missingKey = ChatWebSearchPolicy.formatAppSearchResults(
            actualEngine: .quickFacts,
            fallbackReason: .missingBraveKey,
            instantAnswer: nil,
            pages: [(title: "Iceland", url: "https://en.wikipedia.org/wiki/Iceland", snippet: "Nordic", pageText: nil)]
        )
        XCTAssertEqual(
            ChatWebSearchPolicy.parseFallbackNotice(from: missingKey),
            ChatWebSearchPolicy.quickFactsOnlyLine
        )
        XCTAssertTrue(ChatWebSearchPolicy.isQuickFactsHint(ChatWebSearchPolicy.parseFallbackNotice(from: missingKey)))

        XCTAssertEqual(
            ChatWebSearchPolicy.noticeToPersist(reason: .missingBraveKey, alreadyShowedQuickFactsHint: false),
            ChatWebSearchPolicy.quickFactsOnlyLine
        )
        XCTAssertNil(
            ChatWebSearchPolicy.noticeToPersist(reason: .missingBraveKey, alreadyShowedQuickFactsHint: true)
        )
        XCTAssertEqual(
            ChatWebSearchPolicy.noticeToPersist(reason: .braveFailed, alreadyShowedQuickFactsHint: true),
            ChatWebSearchPolicy.braveFailedLine
        )
    }

    func testBravePersistedMessageOmitsRawResultSnippets() {
        let uniqueSnippet = "BRAVE_RAW_SNIPPET_NORDIC_ISLAND_9f3c"
        let pageText = "BRAVE_PAGE_TEXT_SHOULD_NOT_PERSIST_7a1b"
        let results = [
            BraveSearchResult(
                title: "Iceland",
                url: "https://en.wikipedia.org/wiki/Iceland",
                snippet: uniqueSnippet
            ),
        ]
        let citations = ChatWebSearchPolicy.persistableCitations(fromBrave: results)
        XCTAssertEqual(citations.map(\.title), ["Iceland"])
        XCTAssertEqual(citations.map(\.url), ["https://en.wikipedia.org/wiki/Iceland"])

        let record = ChatWebSearchPolicy.persistedChatMessage(
            answer: "Iceland is a Nordic island country in the North Atlantic.",
            citations: citations,
            actualEngine: .brave
        )
        XCTAssertEqual(record.attribution, "Search results from Brave")
        XCTAssertEqual(ChatWebSearchPolicy.persistedEngine(from: record.metadata), .brave)
        XCTAssertTrue(ChatWebSearchPolicy.showsBraveAttribution(from: record.metadata))
        XCTAssertFalse(
            ChatWebSearchPolicy.persistedFormContainsRawSnippets(
                answer: record.answer,
                metadata: record.metadata,
                snippets: [uniqueSnippet, pageText]
            )
        )
        XCTAssertFalse(record.serialized.contains(uniqueSnippet))
        XCTAssertFalse(record.serialized.contains(pageText))
        XCTAssertFalse(record.serialized.contains("\"snippet\""))
        XCTAssertFalse(record.serialized.contains("\"description\""))
        XCTAssertTrue(record.serialized.contains("Iceland"))
        XCTAssertTrue(record.serialized.contains("en.wikipedia.org"))
        XCTAssertFalse(BraveSearchCodec.cachesResults)
        XCTAssertEqual(ChatWebSearchPolicy.braveAttributionLine, "Search results from Brave")
    }

    func testResponsesToolsPassHostedWebSearchThrough() {
        let mapped = OpenAIRequestCodec.responsesTools(fromChatTools: [
            ["type": "web_search"],
            [
                "type": "function",
                "function": [
                    "name": "list_notes",
                    "description": "List notes",
                    "parameters": ["type": "object"] as [String: Any],
                ] as [String: Any],
            ],
        ])
        XCTAssertEqual(mapped[0]["type"] as? String, "web_search")
        XCTAssertEqual(mapped[1]["name"] as? String, "list_notes")
    }
}

final class ChatWebSearchEngineMigrationTests: XCTestCase {
    func testResolvedMigratesDuckDuckGoToBrave() {
        XCTAssertEqual(ChatWebSearchEngine.resolved("duckDuckGo"), .brave)
        XCTAssertEqual(ChatWebSearchEngine.resolved(nil), .brave)
        XCTAssertEqual(ChatWebSearchEngine.resolved(""), .brave)
        XCTAssertEqual(ChatWebSearchEngine.resolved("unknown"), .brave)
        XCTAssertEqual(ChatWebSearchEngine.resolved("brave"), .brave)
        XCTAssertEqual(ChatWebSearchEngine.resolved("searchServer"), .searchServer)
        XCTAssertEqual(ChatWebSearchEngine.resolved("aiProvider"), .aiProvider)
        XCTAssertEqual(ChatWebSearchEngine.resolvedSelectable("duckDuckGo"), .brave)
        XCTAssertEqual(ChatWebSearchEngine.resolvedSelectable("quickFacts"), .brave)
        XCTAssertNil(ChatWebSearchEngine(rawValue: "duckDuckGo"))
        XCTAssertFalse(ChatWebSearchEngine.allCases.contains { $0.rawValue == "duckDuckGo" })
        XCTAssertEqual(ChatWebSearchEngine.primaryCases, [.brave, .aiProvider])
        XCTAssertEqual(ChatWebSearchEngine.default, .brave)
    }

    func testMigrateStoredEngineRewritesDuckDuckGo() {
        let suite = "anaiodyssey.tests.engine-migrate.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return XCTFail("Could not create suite defaults")
        }
        defaults.removePersistentDomain(forName: suite)
        defaults.set("duckDuckGo", forKey: ChatWebSearchEngine.storageKey)
        XCTAssertEqual(ChatWebSearchEngine.migrateStoredEngine(in: defaults), .brave)
        XCTAssertEqual(defaults.string(forKey: ChatWebSearchEngine.storageKey), "brave")

        defaults.set("searchServer", forKey: ChatWebSearchEngine.storageKey)
        XCTAssertEqual(ChatWebSearchEngine.migrateStoredEngine(in: defaults), .searchServer)
        XCTAssertEqual(defaults.string(forKey: ChatWebSearchEngine.storageKey), "searchServer")
        defaults.removePersistentDomain(forName: suite)
    }
}

final class PrivacyDisclosuresTests: XCTestCase {
    func testEveryTabHasADisclosure() {
        for tab in PrivacyTab.allCases {
            let text = PrivacyDisclosures.disclosure(for: tab)
            XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, tab.rawValue)
            XCTAssertFalse(tab.title.isEmpty, tab.rawValue)
            XCTAssertFalse(tab.systemImage.isEmpty, tab.rawValue)
        }
    }

    func testNothingLeavesTabs() {
        XCTAssertEqual(PrivacyDisclosures.disclosure(for: .search), PrivacyDisclosures.nothingLeaves)
        XCTAssertEqual(PrivacyDisclosures.disclosure(for: .notes), PrivacyDisclosures.nothingLeaves)
        XCTAssertEqual(
            PrivacyDisclosures.nothingLeaves,
            "Nothing from this tab leaves your device."
        )
    }

    func testChatDisclosureSwitchesWithEngine() {
        XCTAssertEqual(
            PrivacyDisclosures.disclosure(for: .chats, chatWebSearchAllowed: false),
            PrivacyDisclosures.chatMessages
        )
        let brave = PrivacyDisclosures.disclosure(
            for: .chats,
            chatWebSearchAllowed: true,
            chatEngine: .brave
        )
        XCTAssertTrue(brave.contains(PrivacyDisclosures.chatBraveFooter))
        XCTAssertTrue(brave.contains("go to Brave Search"))
        let provider = PrivacyDisclosures.disclosure(
            for: .chats,
            chatWebSearchAllowed: true,
            chatEngine: .aiProvider
        )
        XCTAssertTrue(provider.contains(PrivacyDisclosures.chatProviderFooter))
        XCTAssertTrue(provider.contains("bill"))
        let server = PrivacyDisclosures.disclosure(
            for: .chats,
            chatWebSearchAllowed: true,
            chatEngine: .searchServer
        )
        XCTAssertTrue(server.contains(PrivacyDisclosures.chatSearchServerFooter))
        XCTAssertTrue(server.contains("your own search server"))
        XCTAssertFalse(server.contains("Brave Search"))
        let facts = PrivacyDisclosures.disclosure(
            for: .chats,
            chatWebSearchAllowed: true,
            chatEngine: .quickFacts
        )
        XCTAssertTrue(facts.contains("Instant Answers"))
        XCTAssertTrue(facts.contains("Wikipedia"))
    }

    /// Settings Chat footer uses this same call with the live picker value.
    func testChatPrivacyFooterFollowsSelectedEngineLive() {
        var previous: String?
        for engine in ChatWebSearchEngine.allCases {
            let footer = PrivacyDisclosures.disclosure(
                for: .chats,
                chatWebSearchAllowed: true,
                chatEngine: engine
            )
            let engineFooter = PrivacyDisclosures.chatWebSearchFooter(engine: engine)
            XCTAssertEqual(
                footer,
                PrivacyDisclosures.chatDisclosure(isWebSearchAllowed: true, engine: engine)
            )
            XCTAssertEqual(ChatWebSearchPolicy.privacyFooter(engine: engine), engineFooter)
            XCTAssertTrue(footer.contains(engineFooter), engine.rawValue)
            XCTAssertFalse(footer.contains("DuckDuckGo (free)"), engine.rawValue)
            if engine != .brave && engine != .quickFacts {
                XCTAssertFalse(
                    engineFooter.contains("DuckDuckGo"),
                    "\(engine.rawValue) footer must not be hard-coded to DuckDuckGo"
                )
            }
            if let previous {
                XCTAssertNotEqual(footer, previous, "Footer must change when the picker changes")
            }
            previous = footer
        }
        XCTAssertEqual(ChatWebSearchEngine.allCases.count, 3)
    }

    func testResearchFooterSaysRunsKeepGoingWhileAppIsOpen() {
        XCTAssertEqual(PrivacyDisclosures.researchRunsWhileOpen, "Runs keep going while the app is open.")
        for engine in ChatWebSearchEngine.allCases + [.quickFacts] {
            XCTAssertTrue(
                PrivacyDisclosures.disclosure(for: .research, chatEngine: engine)
                    .hasSuffix("Runs keep going while the app is open."),
                "\(engine)"
            )
        }
    }

    func testResearchDisclosureFollowsSelectedEngine() {
        let brave = PrivacyDisclosures.disclosure(for: .research, chatEngine: .brave)
        XCTAssertTrue(brave.contains("Brave Search"))
        XCTAssertTrue(brave.contains("sends search terms to Brave Search"))
        XCTAssertEqual(brave, PrivacyDisclosures.researchBraveFooter + " " + PrivacyDisclosures.researchRunsWhileOpen)
        XCTAssertEqual(PrivacyDisclosures.research, PrivacyDisclosures.researchBraveFooter)

        let server = PrivacyDisclosures.disclosure(for: .research, chatEngine: .searchServer)
        XCTAssertTrue(server.contains("your own search server"))
        XCTAssertFalse(server.contains("Brave Search"))

        let provider = PrivacyDisclosures.disclosure(for: .research, chatEngine: .aiProvider)
        XCTAssertTrue(provider.contains("AI provider"))
        XCTAssertTrue(provider.contains("bill"))

        let facts = PrivacyDisclosures.disclosure(for: .research, chatEngine: .quickFacts)
        XCTAssertTrue(facts.contains("Instant Answers"))
        XCTAssertTrue(facts.contains("Wikipedia"))
        XCTAssertFalse(PrivacyDisclosures.researchBraveFooter.contains("HTML"))
        XCTAssertFalse(PrivacyDisclosures.researchBraveFooter.contains("results page"))
    }

    func testTasksNoteResearchAndNoMailCalendar() {
        XCTAssertTrue(PrivacyDisclosures.tasks.contains("Research"))
        XCTAssertTrue(PrivacyDisclosures.tasks.localizedCaseInsensitiveContains("email"))
        XCTAssertTrue(PrivacyDisclosures.tasks.localizedCaseInsensitiveContains("calendar"))
        XCTAssertFalse(PrivacyDisclosures.tasks.contains("DuckDuckGo"))
    }
}

final class DuckDuckGoSearchCodecTests: XCTestCase {
    func testInstantAnswerParser() {
        let json = """
        {"Heading":"Iceland","AbstractText":"A Nordic island country.","AbstractURL":"https://en.wikipedia.org/wiki/Iceland","AbstractSource":"Wikipedia"}
        """.data(using: .utf8)!
        let answer = DuckDuckGoSearchCodec.parseInstantAnswer(json: json)
        XCTAssertEqual(answer?.text, "A Nordic island country.")
        XCTAssertEqual(answer?.url, "https://en.wikipedia.org/wiki/Iceland")
    }

    func testReadableTextStripsTagsAndCaps() {
        let html = "<html><script>ignore()</script><body><h1>Hello</h1><p>World &amp; friends</p></body></html>"
        let text = DuckDuckGoSearchCodec.readableText(fromHTML: html, maxCharacters: 20)
        XCTAssertFalse(text.contains("<"))
        XCTAssertTrue(text.contains("Hello"))
        XCTAssertLessThanOrEqual(text.count, 20)
    }

    func testInstantAnswerURLIsOfficialJSONAPI() {
        let url = DuckDuckGoSearchCodec.instantAnswerURL(query: "iceland weather")
        XCTAssertEqual(url?.host, "api.duckduckgo.com")
        XCTAssertEqual(url?.scheme, "https")
        XCTAssertTrue(url?.absoluteString.contains("format=json") == true)
        XCTAssertTrue(url?.absoluteString.contains("no_html=1") == true)
        XCTAssertFalse(url?.absoluteString.contains("/html") == true)
        XCTAssertEqual(DuckDuckGoSearchCodec.instantAnswerEndpoint, "https://api.duckduckgo.com/")
    }
}

final class BraveSearchCodecTests: XCTestCase {
    func testParsesWebResultsFixture() {
        let data = BraveSearchFixtures.webJSON.data(using: .utf8)!
        let results = BraveSearchCodec.parseResults(data, limit: 5)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].title, "Iceland")
        XCTAssertEqual(results[0].url, "https://en.wikipedia.org/wiki/Iceland")
        XCTAssertTrue(results[0].snippet.contains("Nordic island"))
        XCTAssertEqual(results[1].title, "Iceland weather")
        XCTAssertEqual(results[1].url, "https://weather.example/iceland")
    }

    func testSearchURLAndFailureReasons() {
        let url = BraveSearchCodec.searchURL(query: "iceland weather", count: 5)
        XCTAssertEqual(url?.host, "api.search.brave.com")
        XCTAssertEqual(url?.path, "/res/v1/web/search")
        XCTAssertTrue(url?.absoluteString.contains("q=iceland") == true)
        XCTAssertEqual(BraveSearchCodec.subscriptionHeader, "X-Subscription-Token")
        XCTAssertTrue(BraveSearchCodec.isAuthOrQuotaFailure(statusCode: 401))
        XCTAssertTrue(BraveSearchCodec.isAuthOrQuotaFailure(statusCode: 429))
        XCTAssertEqual(BraveSearchCodec.failureReason(statusCode: 429), "Brave Search rate-limited the request.")
        XCTAssertEqual(BraveSearchCodec.signupURLString, "https://brave.com/search/api/")
        XCTAssertEqual(
            BraveSearchCodec.cardFootnote,
            "Brave asks for a card but doesn't charge within the free limit."
        )
        XCTAssertEqual(BraveSearchCodec.attributionLine, "Search results from Brave")
        XCTAssertEqual(
            BraveSearchCodec.mapProbe(statusCode: nil, error: nil, hasKey: false),
            .missingKey
        )
        XCTAssertEqual(
            BraveSearchCodec.mapProbe(statusCode: 200, error: nil, hasKey: true),
            .reachable
        )
    }
}

final class SearXNGSearchCodecTests: XCTestCase {
    func testParsesResultsFixture() {
        let data = SearXNGFixtures.json.data(using: .utf8)!
        let results = SearXNGSearchCodec.parseResults(data, limit: 5)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].title, "Iceland")
        XCTAssertEqual(results[0].url, "https://en.wikipedia.org/wiki/Iceland")
        XCTAssertTrue(results[0].snippet.contains("Nordic island"))
        XCTAssertEqual(results[1].title, "Reykjavik")
        XCTAssertEqual(results[1].url, "https://www.visitreykjavik.is/")
    }

    func testProbeURLAndNormalization() {
        let url = SearXNGSearchCodec.probeURL(baseURL: "http://100.64.0.10:8888/")
        XCTAssertEqual(url?.host, "100.64.0.10")
        XCTAssertEqual(url?.port, 8888)
        XCTAssertEqual(url?.path, "/search")
        XCTAssertTrue(url?.absoluteString.contains("q=test") == true)
        XCTAssertTrue(url?.absoluteString.contains("format=json") == true)
        XCTAssertEqual(
            SearXNGSearchCodec.normalizeBaseURL("searx.example"),
            "https://searx.example"
        )
    }

    func testProbeResultMapping() {
        let json = SearXNGFixtures.json.data(using: .utf8)!
        XCTAssertEqual(
            SearXNGSearchCodec.mapProbe(
                statusCode: 200,
                contentType: "application/json",
                body: json,
                error: nil
            ),
            .reachable
        )
        XCTAssertEqual(
            SearXNGSearchCodec.mapProbe(
                statusCode: nil,
                contentType: nil,
                body: Data(),
                error: URLError(.cannotConnectToHost)
            ),
            .unreachable
        )
        XCTAssertEqual(
            SearXNGSearchCodec.probeMessage(.unreachable),
            "Can't reach it. Is your VPN on?"
        )
        XCTAssertEqual(
            SearXNGSearchCodec.mapProbe(
                statusCode: 200,
                contentType: "text/html",
                body: Data("<html><body>Search</body></html>".utf8),
                error: nil
            ),
            .needsJSONOrLimiter
        )
        XCTAssertTrue(
            SearXNGSearchCodec.probeMessage(.needsJSONOrLimiter).contains("JSON")
        )
    }
}

final class DuckDuckGoHTMLResultsPageBanTests: XCTestCase {
    func testRepoSwiftSourcesDoNotBuildDuckDuckGoHTMLResultsURL() throws {
        let htmlHost = ["html", "duckduckgo", "com"].joined(separator: ".")
        let htmlPath = ["duckduckgo.com", "html"].joined(separator: "/")
        let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let packageDir = testsDir.deletingLastPathComponent()
        let odysseyDir = packageDir.deletingLastPathComponent().deletingLastPathComponent()
        var hits: [String] = []
        let enumerator = FileManager.default.enumerator(
            at: odysseyDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            if url.path.contains("/.build/") { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            if url.lastPathComponent == "ChatWebSearchPolicyTests.swift" { continue }
            if text.contains(htmlHost) || text.contains(htmlPath) {
                hits.append(url.path.replacingOccurrences(of: odysseyDir.path + "/", with: ""))
            }
        }
        XCTAssertTrue(
            hits.isEmpty,
            "HTML results-page URL leaked in: \(hits.joined(separator: ", "))"
        )
    }
}

private enum BraveSearchFixtures {
    static let webJSON = """
    {
      "query": { "original": "iceland" },
      "web": {
        "results": [
          {
            "title": "Iceland",
            "url": "https://en.wikipedia.org/wiki/Iceland",
            "description": "A Nordic island country."
          },
          {
            "title": "Iceland weather",
            "url": "https://weather.example/iceland",
            "description": "Forecast for Reykjavik."
          }
        ]
      }
    }
    """
}

private enum SearXNGFixtures {
    static let json = """
    {
      "query": "iceland",
      "results": [
        {
          "title": "Iceland",
          "url": "https://en.wikipedia.org/wiki/Iceland",
          "content": "A Nordic island country."
        },
        {
          "title": "Reykjavik",
          "url": "https://www.visitreykjavik.is/",
          "snippet": "The capital of Iceland."
        }
      ]
    }
    """
}
