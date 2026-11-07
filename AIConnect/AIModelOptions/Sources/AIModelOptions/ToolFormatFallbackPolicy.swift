// SPDX-License-Identifier: MIT
import Foundation

/// Detects a reply that should have been a tool call but came back as text.
/// The user-facing sentence lives in the app/UI layer, not here.
public enum ToolFormatFallbackPolicy {
    /// GPT-OSS is the only family that writes Harmony tokens.
    public static func looksLikeGPTOSS(_ modelID: String) -> Bool {
        ModelCapabilityCatalog.leafModelID(modelID)
            .localizedCaseInsensitiveContains("gpt-oss")
    }

    /// Harmony leak, or a Qwen / default LM Studio tool wrapper that did not parse.
    public static func looksLikeFailedToolUse(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if containsHarmonyTokens(trimmed) { return true }
        if trimmed.contains("<tool_call>") || trimmed.contains("[TOOL_REQUEST]") {
            return LMStudioToolProtocol.calls(inContent: trimmed).isEmpty
        }
        return false
    }

    /// Tools were offered, none were parsed, and the text looks like a failed call
    /// — or Harmony was forced on a model that does not write Harmony.
    public static func shouldSuggestDifferentFormat(
        toolsWereOffered: Bool,
        parsedToolCallCount: Int,
        assistantText: String,
        forcedHarmonyOnNonGPTOSS: Bool
    ) -> Bool {
        guard toolsWereOffered, parsedToolCallCount == 0 else { return false }
        if forcedHarmonyOnNonGPTOSS { return true }
        return looksLikeFailedToolUse(assistantText)
    }

    public static func containsHarmonyTokens(_ text: String) -> Bool {
        text.contains("<|start|>")
            || text.contains("<|channel|>")
            || text.contains("<|message|>")
            || text.contains("<|call|>")
            || text.contains("<|return|>")
    }
}
