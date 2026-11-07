// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import AnAIOdysseyAI

/// The minimal email context handed to the on-device LLM for summarizing or replying.
///
/// `recipient` is optional because summarization doesn't need it; when drafting a
/// reply it identifies who the response is addressed to (falling back to the sender).
public struct EmailAIInput: Sendable {
    public let sender: String
    public let subject: String
    public let body: String
    public let recipient: String?

    public init(sender: String, subject: String, body: String, recipient: String? = nil) {
        self.sender = sender
        self.subject = subject
        self.body = body
        self.recipient = recipient
    }
}

/// User-facing errors surfaced by `EmailAIService` operations.
///
/// Conforms to `LocalizedError` so each case carries a presentable message, and to
/// `Equatable` so callers/tests can assert on specific failures.
public enum EmailAIError: Error, LocalizedError, Equatable {
    case emptyBody
    case modelNotLoaded
    case generationFailed(String)

    /// Human-readable description shown to the user for each failure mode.
    public var errorDescription: String? {
        switch self {
        case .emptyBody:
            return "Email body is empty."
        case .modelNotLoaded:
            return "No model is loaded. Open Settings and load a model first."
        case .generationFailed(let message):
            return "Email AI failed: \(message)"
        }
    }
}

/// High-level email assistant that turns raw messages into summaries and reply drafts.
///
/// This is a thin orchestration layer over an injected `LLMServiceProtocol`: it builds
/// the appropriate prompts (via `EmailPrompts`), streams the model's response, and
/// cleans up the output (via `EmailResponseParser`). It is `@MainActor`-isolated
/// because the underlying LLM service is UI-bound. `writingStyle` is mutable so the
/// app can update the user's preferred tone for replies without recreating the service.
@MainActor
public final class EmailAIService {
    private let llmService: any LLMServiceProtocol
    public var writingStyle: String?

    /// Creates the service over a model backend, optionally seeding a reply writing style.
    public init(llmService: any LLMServiceProtocol, writingStyle: String? = nil) {
        self.llmService = llmService
        self.writingStyle = writingStyle
    }

    /// Produces a short bullet-point summary of an email.
    ///
    /// Throws `.emptyBody` if there's nothing to summarize, `.modelNotLoaded` if the
    /// model can't be loaded, and `.generationFailed` if the model returns nothing usable.
    public func summarize(_ input: EmailAIInput) async throws -> String {
        // Reject empty input early so we never spend model time on nothing.
        let body = input.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            throw EmailAIError.emptyBody
        }

        // Make sure a model is available before issuing the request.
        try await ensureModelLoaded()
        // Build the summarization prompt from the email fields.
        let userPrompt = EmailPrompts.summarizeUserPrompt(
            sender: input.sender,
            subject: input.subject,
            body: body
        )
        // Run the model and strip out everything outside the <<<SUMMARY>>> markers.
        let raw = try await complete(
            userPrompt: userPrompt,
            systemPrompt: EmailPrompts.summarizeSystemPrompt
        )
        let summary = EmailResponseParser.extractFencedOutput(from: raw)
        // A blank result means the model ignored the format contract; treat as failure.
        guard !summary.isEmpty else {
            throw EmailAIError.generationFailed("Summary was empty.")
        }
        return summary
    }

    /// Drafts a reply body for an email, honoring the configured writing style.
    ///
    /// Mirrors `summarize` but uses the reply prompts. When no explicit recipient is
    /// provided we reply to the original sender.
    public func draftReply(_ input: EmailAIInput) async throws -> String {
        // Reject empty input early; there is nothing to reply to.
        let body = input.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            throw EmailAIError.emptyBody
        }

        // Make sure a model is available before issuing the request.
        try await ensureModelLoaded()
        // Default the reply recipient to the original sender when unspecified.
        let recipient = input.recipient ?? input.sender
        // Build the reply prompt; the system prompt embeds the user's writing style.
        let userPrompt = EmailPrompts.replyUserPrompt(
            recipient: recipient,
            subject: input.subject,
            originalBody: body
        )
        // Run the model and strip out everything outside the <<<REPLY>>> markers.
        let raw = try await complete(
            userPrompt: userPrompt,
            systemPrompt: EmailPrompts.replySystemPrompt(writingStyle: writingStyle)
        )
        let reply = EmailResponseParser.extractFencedOutput(from: raw)
        // A blank result means the model ignored the format contract; treat as failure.
        guard !reply.isEmpty else {
            throw EmailAIError.generationFailed("Reply draft was empty.")
        }
        return reply
    }

    /// Lazily loads the user's selected model, translating any failure into `.modelNotLoaded`.
    private func ensureModelLoaded() async throws {
        // Nothing to do if a model is already resident in memory.
        if llmService.isModelLoaded { return }
        do {
            try await llmService.loadSelectedModel()
        } catch {
            // Hide the low-level loading error behind a user-actionable message.
            throw EmailAIError.modelNotLoaded
        }
    }

    /// Streams a single-shot completion and concatenates the chunks into one string.
    ///
    /// The system prompt is passed as the conversation history so the model treats it
    /// as instructions rather than user content. Streaming errors are wrapped as
    /// `.generationFailed` carrying the underlying description.
    private func complete(userPrompt: String, systemPrompt: String) async throws -> String {
        var output = ""
        // Seed the conversation with the system prompt, then send the user prompt.
        let stream = llmService.streamResponse(
            to: userPrompt,
            history: [LLMChatTurn(role: "system", content: systemPrompt)]
        )
        do {
            // Accumulate streamed tokens into the final response text.
            for try await chunk in stream {
                output += chunk
            }
        } catch {
            throw EmailAIError.generationFailed(error.localizedDescription)
        }
        return output
    }
}
