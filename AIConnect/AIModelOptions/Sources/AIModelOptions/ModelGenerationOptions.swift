// SPDX-License-Identifier: MIT
import Foundation

/// User-adjustable generation options for one model selection.
public struct ModelGenerationOptions: Equatable, Sendable {
    /// Reasoning effort to request; nil leaves the provider default unless the
    /// model requires a value (Astra always sends `medium` when unset).
    public var reasoningEffort: ReasoningEffort?
    /// Cap on output tokens (`max_output_tokens` / `max_completion_tokens` /
    /// `max_tokens`); nil keeps the model-family default.
    public var maxOutputTokens: Int?
    /// Conversation context window in tokens; nil means Auto (the model limit).
    public var contextWindowTokens: Int?
    /// When set, Responses requests store reasoning so later turns can continue it.
    /// `nil` uses the model's default (`true` for reasoning models).
    public var rememberThinking: Bool?
    /// Responses `reasoning.mode` (`standard` or `pro`) when the model supports it.
    public var reasoningMode: String?

    public init(
        reasoningEffort: ReasoningEffort? = nil,
        maxOutputTokens: Int? = nil,
        contextWindowTokens: Int? = nil,
        rememberThinking: Bool? = nil,
        reasoningMode: String? = nil
    ) {
        self.reasoningEffort = reasoningEffort
        self.maxOutputTokens = maxOutputTokens
        self.contextWindowTokens = contextWindowTokens
        self.rememberThinking = rememberThinking
        self.reasoningMode = reasoningMode
    }

    public var isEmpty: Bool {
        reasoningEffort == nil
            && maxOutputTokens == nil
            && contextWindowTokens == nil
            && rememberThinking == nil
            && reasoningMode == nil
    }
}

extension ModelGenerationOptions: Codable {
    enum CodingKeys: String, CodingKey {
        case reasoningEffort
        case maxOutputTokens
        case contextWindowTokens
        case rememberThinking
        case reasoningMode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reasoningEffort = try container.decodeIfPresent(ReasoningEffort.self, forKey: .reasoningEffort)
        maxOutputTokens = try container.decodeIfPresent(Int.self, forKey: .maxOutputTokens)
        contextWindowTokens = try container.decodeIfPresent(Int.self, forKey: .contextWindowTokens)
        rememberThinking = try container.decodeIfPresent(Bool.self, forKey: .rememberThinking)
        reasoningMode = try container.decodeIfPresent(String.self, forKey: .reasoningMode)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(reasoningEffort, forKey: .reasoningEffort)
        try container.encodeIfPresent(maxOutputTokens, forKey: .maxOutputTokens)
        try container.encodeIfPresent(contextWindowTokens, forKey: .contextWindowTokens)
        try container.encodeIfPresent(rememberThinking, forKey: .rememberThinking)
        try container.encodeIfPresent(reasoningMode, forKey: .reasoningMode)
    }
}
