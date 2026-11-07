// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import AnAIOdysseyCore
import AIModelOptions

/// Errors thrown while the Documents writing feature generates a document.
public enum DocumentWritingError: Error, LocalizedError {
    case emptyBrief
    case notConfigured
    case modelNotLoaded(String)
    case generationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .emptyBrief:
            return "Provide a title or brief for the document."
        case .notConfigured:
            return "Documents writing is not configured."
        case .modelNotLoaded(let message):
            return message
        case .generationFailed(let message):
            return "Document writing failed: \(message)"
        }
    }
}

/// Result of the Documents writing pipeline.
public struct DocumentWriteResult: Sendable {
    public let id: String
    public let title: String
    public let excerpt: String
    public let created: Bool

    public init(id: String, title: String, excerpt: String, created: Bool) {
        self.id = id
        self.title = title
        self.excerpt = excerpt
        self.created = created
    }
}

/// Generates a Document using the Documents feature model — the same pipeline a
/// Documents-tab write would use — instead of the task agent composing the body.
@MainActor
public final class DocumentWritingService {
    private let llmService: any LLMServiceProtocol
    private let providerSettings: ProviderSettings
    public let documents: any DocumentRepositoryProtocol

    public init(
        llmService: any LLMServiceProtocol,
        providerSettings: ProviderSettings,
        documents: any DocumentRepositoryProtocol
    ) {
        self.llmService = llmService
        self.providerSettings = providerSettings
        self.documents = documents
    }

    public func writeDocument(
        title: String?,
        brief: String,
        existingDocumentID: String? = nil,
        extraContext: String? = nil,
        configuration: ResearchRunConfiguration,
        shouldContinue: @escaping @MainActor () -> Bool = { true }
    ) async throws -> DocumentWriteResult {
        let trimmedBrief = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBrief.isEmpty || !(title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DocumentWritingError.emptyBrief
        }
        guard shouldContinue() else {
            throw CancellationError()
        }

        let existing: Document?
        if let existingDocumentID {
            existing = try documents.fetchDocument(id: existingDocumentID)
        } else {
            existing = nil
        }

        try await prepareModel(configuration: configuration)
        guard shouldContinue() else {
            throw CancellationError()
        }

        let userPrompt = Self.writingUserPrompt(
            title: title,
            brief: trimmedBrief.isEmpty ? (title ?? "") : trimmedBrief,
            existingTitle: existing?.title,
            existingBody: existing?.currentContent,
            extraContext: extraContext
        )
        var body = ""
        let stream = llmService.streamResponse(
            to: userPrompt,
            history: [LLMChatTurn(role: "system", content: Self.writingSystemPrompt)]
        )
        for try await chunk in stream {
            guard shouldContinue() else {
                throw CancellationError()
            }
            body += chunk
        }
        guard shouldContinue() else {
            throw CancellationError()
        }

        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBody.isEmpty else {
            throw DocumentWritingError.generationFailed(
                "The AI model returned no text. Check Settings → Default Models by Tab → Documents."
            )
        }

        let resolvedTitle = AgentTaskRunPolicy.documentTitle(
            requested: title ?? existing?.title,
            body: trimmedBody,
            brief: trimmedBrief
        )

        if let existing {
            if existing.title != resolvedTitle {
                try documents.updateDocument(id: existing.id, title: resolvedTitle, content: nil)
                existing.title = resolvedTitle
            }
            _ = existing.saveContent(trimmedBody, summary: "Written by Documents feature", source: "ai")
            try documents.save()
            return DocumentWriteResult(
                id: existing.id,
                title: resolvedTitle,
                excerpt: excerpt(trimmedBody),
                created: false
            )
        }

        let document = try documents.createDocument(title: resolvedTitle, content: trimmedBody)
        _ = document.saveContent(trimmedBody, summary: "Written by Documents feature", source: "ai")
        try documents.save()
        return DocumentWriteResult(
            id: document.id,
            title: resolvedTitle,
            excerpt: excerpt(trimmedBody),
            created: true
        )
    }

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
            throw DocumentWritingError.modelNotLoaded(
                "Could not load an AI model for Documents (\(configuration.modelID), \(configuration.backend.title)). \(error.localizedDescription)"
            )
        }
    }

    static var writingSystemPrompt: String {
        """
        You are the Documents writing feature in \(AppBranding.appName).
        Write a complete, well-structured markdown document that fulfills the brief.
        Output only the document body — no preamble, no tool calls, no surrounding quotes.
        Use headings, lists, and short paragraphs. Prefer concrete, useful content.
        """
    }

    static func writingUserPrompt(
        title: String?,
        brief: String,
        existingTitle: String?,
        existingBody: String?,
        extraContext: String?
    ) -> String {
        var prompt = ""
        if let title, !title.isEmpty {
            prompt += "Document title: \(title)\n\n"
        }
        prompt += "Brief:\n\(brief)\n"
        if let extraContext, !extraContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            prompt += "\nSupporting context (for example research):\n\(extraContext)\n"
        }
        if let existingBody, !existingBody.isEmpty {
            prompt += "\nExisting document"
            if let existingTitle, !existingTitle.isEmpty {
                prompt += " “\(existingTitle)”"
            }
            prompt += " — rewrite or replace it according to the brief:\n\(existingBody)\n"
        }
        prompt += "\nWrite the full document now."
        return prompt
    }

    private func excerpt(_ body: String) -> String {
        let collapsed = body.replacingOccurrences(of: "\n", with: " ")
        if collapsed.count <= 400 {
            return collapsed
        }
        return String(collapsed.prefix(400)) + "…"
    }
}
