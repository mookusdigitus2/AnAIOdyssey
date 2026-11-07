// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import AnAIOdysseyCore
import AIModelOptions
import SwiftUI

/// A persisted web source attached to a research report (a `WebSearchResult` made `Codable` for storage).
public struct ResearchSource: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let url: String
    public let snippet: String
    /// Engine that produced this source (`brave`, `searchServer`, `quickFacts`).
    public let engine: String?

    public init(
        id: String = UUID().uuidString,
        title: String,
        url: String,
        snippet: String,
        engine: String? = nil
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.snippet = snippet
        self.engine = engine
    }

    /// Adapts a live search result into a storable source, preserving its id.
    /// Brave terms: persist title and URL only — never raw snippets.
    init(searchResult: WebSearchResult, actualEngine: ChatWebSearchEngine?) {
        let persistSnippet = actualEngine != .brave
        self.init(
            id: searchResult.id,
            title: searchResult.title,
            url: searchResult.url,
            snippet: persistSnippet ? searchResult.snippet : "",
            engine: actualEngine?.rawValue
        )
    }
}

/// One turn in a research conversation, persisted so follow-up questions retain context.
public struct ResearchThreadEntry: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let role: String
    public let content: String
    public let createdAt: Date

    public init(
        id: String = UUID().uuidString,
        role: String,
        content: String,
        createdAt: Date = .now
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
    }
}

/// Which model + backend a research run should use, produced by `LLMModelPreparer`.
public struct ResearchRunConfiguration: Sendable {
    public let modelID: String
    public let backend: LLMBackendPreference
    public let connectionID: String?

    public init(modelID: String, backend: LLMBackendPreference, connectionID: String? = nil) {
        self.modelID = modelID
        self.backend = backend
        self.connectionID = connectionID
    }
}

/// Errors thrown during a research run, with display-ready descriptions.
public enum ResearchServiceError: Error, LocalizedError {
    case emptyQuery
    case modelNotLoaded(String)
    case generationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .emptyQuery:
            "Enter a research query first."
        case .modelNotLoaded(let message):
            message
        case .generationFailed(let message):
            "Research failed: \(message)"
        }
    }
}

/// Orchestrates the "research" feature: web search → LLM synthesis → persisted report.
///
/// A run searches the web for sources, asks the model to synthesize them into a
/// markdown report (streaming the text to the UI as it arrives), then saves the
/// result. Follow-up questions reuse the original sources and prior thread so the
/// conversation builds on itself.
@MainActor
public final class ResearchService {
    private let webSearch: any WebSearchServiceProtocol
    private let llmService: any LLMServiceProtocol
    private let providerSettings: ProviderSettings
    /// Persistence for research reports and their threads/sources.
    public let reports: any ResearchReportRepositoryProtocol

    public init(
        webSearch: any WebSearchServiceProtocol,
        llmService: any LLMServiceProtocol,
        providerSettings: ProviderSettings,
        reports: any ResearchReportRepositoryProtocol
    ) {
        self.webSearch = webSearch
        self.llmService = llmService
        self.providerSettings = providerSettings
        self.reports = reports
    }

    /// Lists saved research reports.
    public func listReports() throws -> [ResearchReport] {
        try reports.listReports()
    }

    /// Deletes a research report by id.
    public func deleteReport(id: String) throws {
        try reports.deleteReport(id: id)
    }

    /// Fetches a single research report by id.
    public func fetchReport(id: String) throws -> ResearchReport? {
        try reports.fetchReport(id: id)
    }

    /// Starts a brand-new research run, streaming the synthesized report text. Creates a new stored report.
    public func runResearch(
        query: String,
        configuration: ResearchRunConfiguration,
        shouldContinue: @escaping @MainActor () -> Bool = { true }
    ) -> AsyncThrowingStream<String, Error> {
        runResearchInternal(
            query: query,
            configuration: configuration,
            existingReportID: nil,
            priorThread: [],
            priorSources: nil,
            originalQuery: nil,
            shouldContinue: shouldContinue
        )
    }

    /// Runs the Research-tab pipeline to completion and returns the saved report.
    /// Pause/Stop flip `shouldContinue` to false; the run then cancels and does not persist.
    public func runResearchToReport(
        query: String,
        configuration: ResearchRunConfiguration,
        shouldContinue: @escaping @MainActor () -> Bool = { true }
    ) async throws -> ResearchReport {
        var completed: ResearchReport?
        let stream = runResearchInternal(
            query: query,
            configuration: configuration,
            existingReportID: nil,
            priorThread: [],
            priorSources: nil,
            originalQuery: nil,
            shouldContinue: shouldContinue,
            onPersisted: { completed = $0 }
        )
        for try await _ in stream {}
        guard let completed else {
            throw ResearchServiceError.generationFailed("Research finished without a saved report.")
        }
        return completed
    }

    /// Continues an existing report with a follow-up question, reusing its prior thread and sources.
    ///
    /// Loads the saved report, feeds the prior conversation back into the model
    /// for context, and appends the follow-up's answer to the same report.
    public func continueResearch(
        reportID: String,
        followUp: String,
        configuration: ResearchRunConfiguration
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    guard let report = try reports.fetchReport(id: reportID) else {
                        throw ResearchServiceError.generationFailed("Research session not found.")
                    }
                    // Restore prior context so the follow-up builds on the original run.
                    let priorThread = Self.decodeThread(from: report)
                    let priorSources = Self.decodeSources(from: report)
                    let stream = runResearchInternal(
                        query: followUp,
                        configuration: configuration,
                        existingReportID: reportID,
                        priorThread: priorThread,
                        priorSources: priorSources,
                        originalQuery: report.query,
                        shouldContinue: { true }
                    )
                    for try await chunk in stream {
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// The shared engine behind both `runResearch` and `continueResearch`.
    ///
    /// Steps: validate query → load model → gather sources (reused for follow-ups,
    /// freshly searched otherwise) → build prompts → stream the model's report
    /// while accumulating it → persist a new report or append a follow-up section.
    /// A web-search failure is non-fatal: it falls back to general knowledge and
    /// notes the absence of live results.
    private func runResearchInternal(
        query: String,
        configuration: ResearchRunConfiguration,
        existingReportID: String?,
        priorThread: [ResearchThreadEntry],
        priorSources: [ResearchSource]?,
        originalQuery: String?,
        shouldContinue: @escaping @MainActor () -> Bool = { true },
        onPersisted: (@MainActor (ResearchReport) -> Void)? = nil
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task { @MainActor in
                do {
                    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else {
                        throw ResearchServiceError.emptyQuery
                    }
                    guard shouldContinue() else {
                        throw CancellationError()
                    }

                    // Ensure a model is loaded, then tell the user which backend is in use.
                    try await prepareModel(configuration: configuration)
                    guard shouldContinue() else {
                        throw CancellationError()
                    }
                    continuation.yield("Using \(llmService.loadStatus)\n\n")

                    // Reuse the original sources on a follow-up; otherwise run a fresh web search.
                    var searchNotice = ""
                    let sources: [ResearchSource]
                    if let priorSources, existingReportID != nil {
                        sources = priorSources
                    } else {
                        do {
                            if let service = webSearch as? WebSearchService {
                                let outcome = try await service.searchUsingSelectedEngine(
                                    query: trimmed,
                                    limit: 5
                                )
                                sources = outcome.results.map {
                                    ResearchSource(searchResult: $0, actualEngine: outcome.actualEngine)
                                }
                                if let reason = outcome.fallbackReason {
                                    searchNotice = ChatWebSearchPolicy.fallbackLine(for: reason) + "\n\n"
                                    continuation.yield(searchNotice)
                                }
                            } else {
                                let searchResults = try await webSearch.search(query: trimmed, limit: 5)
                                sources = searchResults.map {
                                    ResearchSource(searchResult: $0, actualEngine: nil)
                                }
                            }
                        } catch {
                            // Search failure is non-fatal: note it and continue from general knowledge.
                            searchNotice = "Web search note: \(error.localizedDescription)\n\n"
                            sources = []
                            continuation.yield(searchNotice)
                        }
                    }

                    // Assemble the system/user prompts that frame the synthesis task.
                    let sourcesJSON = try Self.encodeSources(sources)
                    let userPrompt = Self.researchUserPrompt(
                        query: trimmed,
                        sources: sources,
                        searchUnavailable: !searchNotice.isEmpty,
                        originalQuery: originalQuery,
                        priorThread: priorThread
                    )
                    let systemPrompt = Self.researchSystemPrompt

                    // Stream the model's report, accumulating it into `summary` while forwarding each chunk.
                    var summary = searchNotice
                    var generatedAny = false
                    let stream = llmService.streamResponse(
                        to: userPrompt,
                        history: [LLMChatTurn(role: "system", content: systemPrompt)]
                    )
                    for try await chunk in stream {
                        guard shouldContinue() else {
                            throw CancellationError()
                        }
                        guard !chunk.isEmpty else { continue }
                        generatedAny = true
                        summary += chunk
                        continuation.yield(chunk)
                    }
                    guard shouldContinue() else {
                        throw CancellationError()
                    }

                    // The persisted body excludes the transient search notice.
                    let reportBody = summary
                        .replacingOccurrences(of: searchNotice, with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard generatedAny, !reportBody.isEmpty else {
                        throw ResearchServiceError.generationFailed(
                            "The AI model returned no text. Check Settings → Remote Provider or choose a different model in Research."
                        )
                    }

                    // Record this exchange in the conversation thread.
                    var thread = priorThread
                    thread.append(ResearchThreadEntry(role: "user", content: trimmed))
                    thread.append(ResearchThreadEntry(role: "assistant", content: summary.trimmingCharacters(in: .whitespacesAndNewlines)))
                    let threadJSON = try Self.encodeThread(thread)

                    if let existingReportID {
                        // Follow-up: append a new section to the existing report's summary.
                        let combinedSummary = priorThread.isEmpty
                            ? summary.trimmingCharacters(in: .whitespacesAndNewlines)
                            : (try reports.fetchReport(id: existingReportID)?.summary ?? "")
                                + "\n\n---\n\n## Follow-up\n\n**Question:** \(trimmed)\n\n\(reportBody)"
                        try reports.updateReport(
                            id: existingReportID,
                            summary: combinedSummary,
                            threadJSON: threadJSON,
                            sourcesJSON: nil
                        )
                        if let report = try reports.fetchReport(id: existingReportID) {
                            onPersisted?(report)
                        }
                    } else {
                        // First run: create a fresh report with its sources.
                        let report = try reports.createReport(
                            query: trimmed,
                            summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
                            sourcesJSON: sourcesJSON,
                            threadJSON: threadJSON
                        )
                        onPersisted?(report)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Loads the model for the run, wrapping any failure in a `modelNotLoaded` error that names the attempted config.
    private func prepareModel(configuration: ResearchRunConfiguration) async throws {
        do {
            try await LLMModelPreparer.prepareWithFallback(
                llmService: llmService,
                providerSettings: providerSettings,
                modelID: configuration.modelID,
                backend: configuration.backend,
                connectionID: configuration.connectionID
            )
        } catch {
            throw ResearchServiceError.modelNotLoaded(
                "Could not load an AI model for research (\(configuration.modelID), \(configuration.backend.title)). \(error.localizedDescription)"
            )
        }
    }

    /// JSON-encodes sources for storage alongside a report.
    private static func encodeSources(_ sources: [ResearchSource]) throws -> String {
        let data = try JSONEncoder().encode(sources)
        guard let json = String(data: data, encoding: .utf8) else {
            throw ResearchServiceError.generationFailed("Could not encode sources.")
        }
        return json
    }

    /// System prompt that instructs the model to synthesize sources into a cited markdown report.
    static var researchSystemPrompt: String {
        """
        You are a research assistant. Synthesize the provided web search snippets into a concise report.
        Use markdown headings and bullet points. Cite source titles inline when helpful.
        If no sources were retrieved, answer from general knowledge and clearly note the lack of live web results.
        """
    }

    /// Builds the user prompt: original topic (for follow-ups), prior conversation, the query, and numbered sources.
    static func researchUserPrompt(
        query: String,
        sources: [ResearchSource],
        searchUnavailable: Bool,
        originalQuery: String? = nil,
        priorThread: [ResearchThreadEntry] = []
    ) -> String {
        var prompt = ""
        // Anchor follow-ups to the original topic when it differs from the current query.
        if let originalQuery, originalQuery != query {
            prompt += "Original research topic: \(originalQuery)\n\n"
        }
        // Replay prior turns for follow-ups; otherwise frame it as a fresh query.
        if !priorThread.isEmpty {
            prompt += "Prior conversation:\n"
            for entry in priorThread {
                let speaker = entry.role == "user" ? "Researcher" : "Assistant"
                prompt += "\(speaker): \(entry.content)\n\n"
            }
            prompt += "Follow-up question: \(query)\n\n"
        } else {
            prompt += "Research query: \(query)\n\n"
        }
        // Either list the numbered sources or explain why there are none.
        if sources.isEmpty {
            prompt += searchUnavailable
                ? "No live web sources were retrieved.\n\n"
                : "No matching sources were found.\n\n"
        } else {
            prompt += "Sources:\n"
            for (index, source) in sources.enumerated() {
                prompt += """
                \(index + 1). \(source.title)
                URL: \(source.url)
                Snippet: \(source.snippet)

                """
            }
        }
        prompt += "\nWrite a structured research summary."
        return prompt
    }

    /// Decodes a report's stored thread, synthesizing a two-turn thread from the query/summary for older reports.
    public static func decodeThread(from report: ResearchReport) -> [ResearchThreadEntry] {
        guard let data = report.threadJSON.data(using: .utf8),
              let thread = try? JSONDecoder().decode([ResearchThreadEntry].self, from: data),
              !thread.isEmpty else {
            // Back-compat: reconstruct a minimal thread from the original query/summary.
            return [
                ResearchThreadEntry(role: "user", content: report.query, createdAt: report.createdAt),
                ResearchThreadEntry(role: "assistant", content: report.summary, createdAt: report.createdAt),
            ]
        }
        return thread
    }

    /// JSON-encodes the conversation thread for storage.
    private static func encodeThread(_ thread: [ResearchThreadEntry]) throws -> String {
        let data = try JSONEncoder().encode(thread)
        guard let json = String(data: data, encoding: .utf8) else {
            throw ResearchServiceError.generationFailed("Could not encode research thread.")
        }
        return json
    }

    /// Decodes a report's stored sources, returning an empty array if absent/corrupt.
    public static func decodeSources(from report: ResearchReport) -> [ResearchSource] {
        guard let data = report.sourcesJSON.data(using: .utf8),
              let sources = try? JSONDecoder().decode([ResearchSource].self, from: data) else {
            return []
        }
        return sources
    }
}

/// Environment key making the active `ResearchService` reachable from SwiftUI views.
private struct ResearchServiceKey: EnvironmentKey {
    static let defaultValue: ResearchService? = nil
}

public extension EnvironmentValues {
    /// The research service available to the current view tree.
    var researchService: ResearchService? {
        get { self[ResearchServiceKey.self] }
        set { self[ResearchServiceKey.self] = newValue }
    }
}
