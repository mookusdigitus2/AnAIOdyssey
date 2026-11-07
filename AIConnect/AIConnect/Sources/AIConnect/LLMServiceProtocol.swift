// SPDX-License-Identifier: MIT
import Foundation
import AIModelOptions

/// A user-selectable language model and the metadata the UI needs to present it.
///
/// `estimatedMemoryGB` is used to gate loading on low-RAM devices and to drive
/// the recommendations in `ModelCatalogService`.
public struct LLMModelOption: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let estimatedMemoryGB: Double

    public init(id: String, displayName: String, estimatedMemoryGB: Double) {
        self.id = id
        self.displayName = displayName
        self.estimatedMemoryGB = estimatedMemoryGB
    }
}

/// Static catalog of the on-device MLX models the app ships support for.
///
/// This is the single source of truth for which local models exist; remote
/// provider models are discovered dynamically and live outside this catalog.
public enum LLMModelCatalog {
    /// The smallest model, used as the safe default on first launch and as a fallback everywhere.
    public static let defaultModelID = "llama3_2_1B_4bit"

    /// All known local models, ordered smallest-first so callers can pick the lightest viable option.
    public static let models: [LLMModelOption] = [
        LLMModelOption(
            id: "llama3_2_1B_4bit",
            displayName: "Llama 3.2 1B (4-bit)",
            estimatedMemoryGB: 1.2
        ),
        LLMModelOption(
            id: "llama3_2_3B_4bit",
            displayName: "Llama 3.2 3B (4-bit)",
            estimatedMemoryGB: 2.5
        ),
    ]

    /// Looks up a catalog entry by id; returns `nil` for unknown/remote ids (used to distinguish local vs remote models).
    public static func option(for id: String) -> LLMModelOption? {
        models.first { $0.id == id }
    }
}

/// One message in a chat transcript, using OpenAI-style roles ("system", "user", "assistant").
///
/// This is the backend-agnostic exchange format: every LLM service translates
/// these turns into whatever shape its underlying API expects.
public struct LLMChatTurn: Sendable, Codable, Equatable {
    public let role: String
    public let content: String
    public let toolCalls: [EncodedFunctionCall]
    public let toolCallID: String?

    public init(
        role: String,
        content: String,
        toolCalls: [EncodedFunctionCall] = [],
        toolCallID: String? = nil
    ) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
    }

    enum CodingKeys: String, CodingKey {
        case role, content, toolCalls, toolCallID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decode(String.self, forKey: .role)
        content = try container.decode(String.self, forKey: .content)
        toolCalls = try container.decodeIfPresent([EncodedFunctionCall].self, forKey: .toolCalls) ?? []
        toolCallID = try container.decodeIfPresent(String.self, forKey: .toolCallID)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        try container.encode(content, forKey: .content)
        if !toolCalls.isEmpty {
            try container.encode(toolCalls, forKey: .toolCalls)
        }
        try container.encodeIfPresent(toolCallID, forKey: .toolCallID)
    }

    public var chatMessage: ChatCompletionMessage {
        ChatCompletionMessage(
            role: role,
            content: content,
            toolCalls: toolCalls.map(ChatCompletionToolCall.init),
            toolCallID: toolCallID
        )
    }
}

/// Records assistant `tool_calls` and `role: tool` turns so multi-step Chat
/// Completions can be built from history instead of a service-level last-call cache.
public enum LLMChatToolHistory {
    public static func assigningCallIDs(_ blocks: [ToolCallBlock]) -> [ToolCallBlock] {
        blocks.map { block in
            if let id = block.callID, !id.isEmpty { return block }
            return ToolCallBlock(toolType: block.toolType, content: block.content, callID: "call_\(UUID().uuidString)",
                                 arguments: block.arguments)
        }
    }

    public static func assistantTurn(text: String, blocks: [ToolCallBlock]) -> LLMChatTurn {
        LLMChatTurn(
            role: "assistant",
            content: text,
            toolCalls: blocks.map {
                // The model's own JSON when it made a native call; `content` is only the extracted
                // input ("" for `{}`), which LM Studio can't parse back (HTTP 500).
                EncodedFunctionCall(name: $0.toolType, arguments: $0.arguments ?? $0.content, callID: $0.callID)
            }
        )
    }

    public static func toolTurns(outputs: [EncodedFunctionCallOutput]) -> [LLMChatTurn] {
        outputs.map { LLMChatTurn(role: "tool", content: $0.output, toolCallID: $0.callID) }
    }
}

/// Errors surfaced by any LLM service, with user-facing descriptions suitable for direct display.
public enum LLMServiceError: Error, LocalizedError {
    case modelNotLoaded
    case modelNotDownloaded(String)
    case modelNotSupported(String)
    case insufficientMemory(requiredGB: Double, availableGB: Double)
    case generationFailed(String)
    /// Stream ended early (`finish_reason` length / content filter, or Responses incomplete).
    case replyCutOff(String)

    /// Human-readable, actionable messages so the chat UI can show errors verbatim.
    public var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            "No model is loaded. Open Settings and load a model first."
        case .modelNotDownloaded(let id):
            "Model '\(id)' isn't downloaded. Download it in Settings → Local Models, or configure a remote provider."
        case .modelNotSupported(let id):
            "Model '\(id)' is not supported."
        case .insufficientMemory(let requiredGB, let availableGB):
            String(format: "Model needs %.1f GB but only %.1f GB is allowed on this device.", requiredGB, availableGB)
        case .generationFailed(let message):
            "Generation failed: \(message)"
        case .replyCutOff(let message):
            message
        }
    }
}

/// The common contract every chat backend implements (local MLX, remote HTTP, mock, or the composite that switches between them).
///
/// Conformers are `@MainActor` because their loading/status state is observed by
/// SwiftUI views; all mutation therefore happens on the main thread while the
/// heavy work is awaited off it.
@MainActor
public protocol LLMServiceProtocol: AnyObject {
    /// The model the service will load/use next; setting it does not load eagerly.
    var selectedModelID: String { get set }
    /// Whether a model is currently loaded and ready to stream responses.
    var isModelLoaded: Bool { get }
    /// Fractional download/load progress in 0...1, or `nil` when indeterminate or idle.
    var loadProgress: Double? { get }
    /// Short human-readable status line shown in the UI (e.g. "Llama 3.2 1B (4-bit) ready").
    var loadStatus: String { get }
    /// Whether the active backend runs on-device via MLX (affects UI hints about privacy/offline use).
    var usesMLXBackend: Bool { get }
    /// Catalog id currently loaded in MLX RAM, if any.
    var loadedLocalModelID: String? { get }
    /// Catalog id whose weights are being loaded into MLX RAM, if any.
    var loadingLocalModelID: String? { get }

    /// Models the user can pick for this backend right now.
    func availableModels() -> [LLMModelOption]
    /// Loads `selectedModelID`, downloading weights or validating the endpoint as needed. Throws `LLMServiceError` on failure.
    func loadSelectedModel() async throws
    /// Drops an on-device MLX model from RAM. No-op for remote/mock backends.
    func unloadLocalModel(_ modelID: String)
    /// Streams the assistant reply token-by-token. Errors are delivered through the stream's failure path so the UI can show partial output.
    func streamResponse(to prompt: String, history: [LLMChatTurn]) -> AsyncThrowingStream<String, Error>
}

public extension LLMServiceProtocol {
    var loadedLocalModelID: String? { nil }
    var loadingLocalModelID: String? { nil }
    func unloadLocalModel(_ modelID: String) {}

    /// Collects a full non-streaming response (used by agent adapters and tests).
    func completeResponse(to prompt: String, history: [LLMChatTurn] = []) async throws -> String {
        var parts: [String] = []
        for try await token in streamResponse(to: prompt, history: history) {
            parts.append(token)
        }
        return parts.joined()
    }
}
