// SPDX-License-Identifier: MIT
import Foundation

/// Display strings and resolved defaults for the model Options UI.
public enum ModelOptionsFormatting {
    public static let maxOutputPresets: [Int] = [
        1_024,
        2_048,
        4_096,
        8_192,
        16_384,
        32_768,
        65_536,
        128_000,
    ]

    /// Per-tab Options are editable only after that tab has its own model.
    public static func shouldShowEditableOptions(hasOwnModelSelection: Bool) -> Bool {
        hasOwnModelSelection
    }

    public static func thinkingPickerLabel(
        _ effort: ReasoningEffort,
        defaultEffort: ReasoningEffort?
    ) -> String {
        if effort == defaultEffort {
            return "\(effort.displayName) (Default)"
        }
        return effort.displayName
    }

    public static func resolvedThinking(
        options: ModelGenerationOptions,
        capabilities: ModelCapabilities
    ) -> ReasoningEffort? {
        ModelCapabilityCatalog.sanitizedReasoningEffort(
            options.reasoningEffort,
            capabilities: capabilities
        ) ?? capabilities.defaultReasoningEffort
    }

    public static func resolvedRememberThinking(
        options: ModelGenerationOptions,
        capabilities: ModelCapabilities
    ) -> Bool {
        guard capabilities.supportsRememberThinking else { return false }
        return options.rememberThinking ?? true
    }

    public static func clampMaxOutputTokens(
        _ requested: Int?,
        capabilities: ModelCapabilities
    ) -> Int? {
        guard let requested else { return nil }
        let upper = max(capabilities.maxOutputTokens, 1)
        return min(max(requested, 1), upper)
    }

    public static func maxOutputChoices(for capabilities: ModelCapabilities) -> [Int] {
        var sizes = maxOutputPresets.filter { $0 <= capabilities.maxOutputTokens }
        if !sizes.contains(capabilities.maxOutputTokens) {
            sizes.append(capabilities.maxOutputTokens)
        }
        return sizes
    }

    /// Body of the inherited Settings line, e.g. "Medium thinking, Auto context".
    public static func inheritedSummary(
        options: ModelGenerationOptions,
        capabilities: ModelCapabilities
    ) -> String {
        var parts: [String] = []
        if let effort = resolvedThinking(options: options, capabilities: capabilities) {
            parts.append("\(effort.displayName) thinking")
        }
        if let tokens = ModelCapabilityCatalog.clampContextTokens(
            options.contextWindowTokens,
            capabilities: capabilities
        ) {
            parts.append("\(ModelCapabilityCatalog.contextLabel(tokens: tokens)) context")
        } else {
            parts.append("Auto context")
        }
        if let maxOutput = clampMaxOutputTokens(options.maxOutputTokens, capabilities: capabilities) {
            parts.append("\(ModelCapabilityCatalog.contextLabel(tokens: maxOutput)) max output")
        }
        return parts.joined(separator: ", ")
    }

    public static func usingGlobalDefaultLine(
        options: ModelGenerationOptions,
        capabilities: ModelCapabilities
    ) -> String {
        "Using global default: \(inheritedSummary(options: options, capabilities: capabilities))"
    }

    public static func optionsToPersist(
        thinking: ReasoningEffort?,
        contextWindowTokens: Int?,
        maxOutputTokens: Int?,
        rememberThinking: Bool,
        capabilities: ModelCapabilities
    ) -> ModelGenerationOptions {
        let effort = ModelCapabilityCatalog.sanitizedReasoningEffort(
            thinking,
            capabilities: capabilities
        )
        let context = ModelCapabilityCatalog.clampContextTokens(
            contextWindowTokens,
            capabilities: capabilities
        )
        let maxOutput = clampMaxOutputTokens(maxOutputTokens, capabilities: capabilities)
        let remember: Bool? = capabilities.supportsRememberThinking ? rememberThinking : nil
        return ModelGenerationOptions(
            reasoningEffort: effort,
            maxOutputTokens: maxOutput,
            contextWindowTokens: context,
            rememberThinking: remember
        )
    }
}
