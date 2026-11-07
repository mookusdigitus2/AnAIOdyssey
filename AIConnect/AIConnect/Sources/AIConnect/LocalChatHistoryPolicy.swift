// SPDX-License-Identifier: MIT
import Foundation
import AIModelOptions

/// What an assistant turn in a Chat Completions history carries for a model served on this
/// Mac or its local network. Cloud OpenAI-style APIs require string tool arguments and don't
/// take `reasoning_content`, so both stay off for them, whatever the Tool Format is.
public enum LocalChatHistoryPolicy {
    /// Resend each assistant turn's thinking as `reasoning_content`: LM Studio on a local or
    /// private host (Qwen3.5+ templates keep thinking across turns).
    public static func sendsReasoningContent(connection: RemoteConnection, usesResponsesAPI: Bool) -> Bool {
        !usesResponsesAPI && connection.servesLMStudioTools && isLocal(connection)
    }

    /// Send history tool-call `arguments` as a JSON object: only LM Studio on a local or private
    /// host serving Qwen3.5 or later or Qwen3-Coder, whose templates do `arguments|items`
    /// (QwenLM/Qwen3#1894). Ollama's and vLLM's OpenAI endpoints type `arguments` as a string and
    /// reject an object, so they keep strings even on an Automatic row: the server's own answer
    /// (`servesLMStudioTools`, `apiProvider`) decides, never the port.
    public static func sendsToolArgumentsAsObjects(connection: RemoteConnection, modelID: String, usesResponsesAPI: Bool) -> Bool {
        guard !usesResponsesAPI, connection.servesLMStudioTools, isLocal(connection),
              connection.apiProvider != .ollama else { return false }
        let leaf = ModelCapabilityCatalog.leafModelID(modelID).lowercased()
        if leaf.hasPrefix("qwen3-coder") { return true }
        guard let version = ModelToolSupportCatalog.qwenVersion(leaf) else { return false }
        return version >= (3, 5)
    }

    static func isLocal(_ connection: RemoteConnection) -> Bool {
        OpenAICompatibleAPI.isPrivateNetworkHost(connection.trimmedBaseURL)
    }
}
