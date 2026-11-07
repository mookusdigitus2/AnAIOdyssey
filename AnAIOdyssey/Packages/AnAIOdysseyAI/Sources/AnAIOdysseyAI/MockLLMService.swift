// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation

/// A fully offline stand-in for a real LLM backend.
///
/// Used as the guaranteed last-resort fallback (when neither MLX nor a remote
/// provider is available) and in tests/previews. It fakes loading progress and
/// streams a canned reply word-by-word so the chat UI behaves identically to a
/// real backend without any network or model weights.
@MainActor
public final class MockLLMService: LLMServiceProtocol {
    public var selectedModelID: String = LLMModelCatalog.defaultModelID
    public private(set) var isModelLoaded = false
    public private(set) var loadProgress: Double?
    public var loadStatus = "Mock backend"
    public let usesMLXBackend = false

    public init() {}

    public func availableModels() -> [LLMModelOption] {
        LLMModelCatalog.models
    }

    /// Simulates a model load by stepping progress to completion over a short delay.
    ///
    /// Mirrors the real services' state transitions so SwiftUI progress UI can be
    /// exercised without downloading anything.
    public func loadSelectedModel() async throws {
        // Walk loadProgress from 0 to 1 in small steps to mimic a real download.
        loadProgress = 0
        loadStatus = "Loading mock model..."
        for step in 1...5 {
            try await Task.sleep(for: .milliseconds(50))
            loadProgress = Double(step) / 5.0
        }
        isModelLoaded = true
        loadProgress = nil
        loadStatus = "Mock model ready"
    }

    /// Streams a deterministic canned reply, emulating token streaming with small per-word delays.
    public func streamResponse(to prompt: String, history: [LLMChatTurn]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                // Refuse to generate until "loaded", matching real backend semantics.
                guard isModelLoaded else {
                    continuation.finish(throwing: LLMServiceError.modelNotLoaded)
                    return
                }
                // Pick a canned reply shaped by the system prompt, then drip it out word-by-word.
                let systemPrompt = history.first { $0.role == "system" }?.content ?? ""
                let reply = Self.mockResponse(systemPrompt: systemPrompt, userPrompt: prompt)
                for word in reply.split(separator: " ") {
                    try await Task.sleep(for: .milliseconds(10))
                    continuation.yield(String(word) + " ")
                }
                continuation.finish()
            }
        }
    }

    /// Chooses a plausible canned response based on cues in the system prompt.
    ///
    /// Recognizes the app's email-summarizer and reply-drafting prompts so those
    /// features produce structurally valid output (matching the `<<<...>>>`
    /// markers the parsers expect) even in offline/mock mode.
    static func mockResponse(systemPrompt: String, userPrompt: String) -> String {
        if systemPrompt.localizedCaseInsensitiveContains("email summarizer") {
            return """
            <<<SUMMARY>>>
            - Mock summary of the email.
            - Follow up with the sender if needed.
            <<<END>>>
            """
        }
        if systemPrompt.localizedCaseInsensitiveContains("drafting an email reply") {
            return """
            <<<REPLY>>>
            Hi,

            Thanks for your email about \(extractSubject(from: userPrompt)). I'll follow up shortly.

            Best
            <<<END>>>
            """
        }
        return "Mock MLX reply to: \(userPrompt)"
    }

    /// Pulls the email subject out of a prompt so the canned reply can reference it; falls back to a generic phrase.
    private static func extractSubject(from prompt: String) -> String {
        for line in prompt.components(separatedBy: "\n") where line.hasPrefix("Subject:") {
            return line.replacingOccurrences(of: "Subject:", with: "").trimmingCharacters(in: .whitespaces)
        }
        return "your message"
    }
}
