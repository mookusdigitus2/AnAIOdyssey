// SPDX-License-Identifier: MIT
import Foundation

/// Whether a picker selection is on-device MLX, Apple's Foundation Model, or a remote HTTP model.
public enum ModelBackendKind: String, Sendable {
    case localMLX
    case appleFoundation
    case remote
}

/// What the UI and request encoder may send for one model.
public struct ModelCapabilities: Equatable, Sendable {
    public let modelID: String
    public let displayName: String
    public let contextWindowTokens: Int
    public let maxOutputTokens: Int
    public let supportedReasoningEfforts: [ReasoningEffort]
    public let defaultReasoningEffort: ReasoningEffort?
    /// When true, omitting effort is treated as the default (Astra rejects `none`).
    public let alwaysSendsReasoningEffort: Bool
    public let supportsRememberThinking: Bool
    public let prefersResponsesAPI: Bool
    public let requiresResponsesAPIForTools: Bool
    public let rejectsTemperature: Bool
    public let usesMaxCompletionTokens: Bool
    public let isLocalMLX: Bool
    /// GPT-5.6 / GPT-6 Responses `reasoning.mode` (`standard` / `pro`).
    public let supportsReasoningMode: Bool
    /// Unix recency used when `/v1/models` does not include `created`.
    public let releaseDate: Int
    /// Provider-reported vision input. Nil in the static catalog unless live data says so.
    public let supportsVision: Bool
    /// Official OpenAI / xAI Responses `reasoning.summary`. Off for hosts that reject it.
    public let supportsReasoningSummary: Bool

    public var supportsThinking: Bool { !supportedReasoningEfforts.isEmpty }

    public init(
        modelID: String,
        displayName: String,
        contextWindowTokens: Int,
        maxOutputTokens: Int,
        supportedReasoningEfforts: [ReasoningEffort] = [],
        defaultReasoningEffort: ReasoningEffort? = nil,
        alwaysSendsReasoningEffort: Bool = false,
        supportsRememberThinking: Bool = false,
        prefersResponsesAPI: Bool = false,
        requiresResponsesAPIForTools: Bool = false,
        rejectsTemperature: Bool = false,
        usesMaxCompletionTokens: Bool = false,
        isLocalMLX: Bool = false,
        supportsReasoningMode: Bool = false,
        releaseDate: Int = 0,
        supportsVision: Bool = false,
        supportsReasoningSummary: Bool = false
    ) {
        self.modelID = modelID
        self.displayName = displayName
        self.contextWindowTokens = contextWindowTokens
        self.maxOutputTokens = maxOutputTokens
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.defaultReasoningEffort = defaultReasoningEffort
        self.alwaysSendsReasoningEffort = alwaysSendsReasoningEffort
        self.supportsRememberThinking = supportsRememberThinking
        self.prefersResponsesAPI = prefersResponsesAPI
        self.requiresResponsesAPIForTools = requiresResponsesAPIForTools
        self.rejectsTemperature = rejectsTemperature
        self.usesMaxCompletionTokens = usesMaxCompletionTokens
        self.isLocalMLX = isLocalMLX
        self.supportsReasoningMode = supportsReasoningMode
        self.releaseDate = releaseDate
        self.supportsVision = supportsVision
        self.supportsReasoningSummary = supportsReasoningSummary
    }
}

/// Static lookup for context limits, thinking levels, and API routing.
public enum ModelCapabilityCatalog {
    public static let astraModelID = "gpt-6-astra"
    public static let appleFoundationModelID = "apple_foundation"
    public static let astraContextWindowTokens = 1_050_000
    public static let astraMaxOutputTokens = 128_000

    /// Seeded into official OpenAI connections so newest chat models are pickable before Query Models.
    public static let bundledOpenAIModelIDs = [
        astraModelID,
        "gpt-6.1-sol",
        "gpt-6-luna",
        "gpt-5.6-sol",
        "gpt-4o",
        "gpt-4o-mini",
    ]

    /// Seeded into xAI connections from https://docs.x.ai/developers/models.
    public static let bundledXAIChatModelIDs = [
        "grok-4.7",
        "grok-4.6",
        "grok-4.5",
    ]

    public static let bundledXAIImageModelIDs = [
        "grok-imagine-image-2.0",
    ]

    public static let contextSizePresets: [Int] = [
        8_192,
        16_384,
        32_768,
        65_536,
        128_000,
        256_000,
        512_000,
        astraContextWindowTokens,
    ]

    public static let astraReasoningEfforts: [ReasoningEffort] = [
        .low, .medium, .high, .xhigh, .max,
    ]

    public static func leafModelID(_ modelID: String) -> String {
        (modelID as NSString).lastPathComponent.lowercased()
    }

    public static func capabilities(
        forModelID modelID: String,
        backend: ModelBackendKind
    ) -> ModelCapabilities {
        capabilities(forModelID: modelID, backend: backend, live: nil)
    }

    public static func capabilities(
        forModelID modelID: String,
        backend: ModelBackendKind,
        live: LiveModelCapabilities?
    ) -> ModelCapabilities {
        let base: ModelCapabilities
        switch backend {
        case .localMLX:
            base = localMLXCapabilities(modelID: modelID)
        case .appleFoundation:
            base = appleFoundationCapabilities(modelID: modelID)
        case .remote:
            base = remoteCapabilities(modelID: modelID)
        }
        return applying(live, to: base)
    }

    /// Overlay provider-reported context, vision, and reasoning on the static catalog.
    public static func applying(_ live: LiveModelCapabilities?, to caps: ModelCapabilities) -> ModelCapabilities {
        guard let live, !live.isEmpty else { return caps }
        var efforts = live.reasoningEfforts.isEmpty ? caps.supportedReasoningEfforts : live.reasoningEfforts
        var defaultEffort = live.defaultReasoningEffort ?? caps.defaultReasoningEffort
        if hasFixedReasoningEfforts(caps.modelID) {
            // The chat template raises on any other level, so the server's list can only narrow it.
            efforts = caps.supportedReasoningEfforts.filter { live.reasoningEfforts.isEmpty || live.reasoningEfforts.contains($0) }
            if let current = defaultEffort, !efforts.contains(current) { defaultEffort = nil }
        }
        return ModelCapabilities(
            modelID: caps.modelID,
            displayName: caps.displayName,
            contextWindowTokens: live.contextWindowTokens ?? caps.contextWindowTokens,
            maxOutputTokens: caps.maxOutputTokens,
            supportedReasoningEfforts: efforts,
            defaultReasoningEffort: defaultEffort,
            alwaysSendsReasoningEffort: caps.alwaysSendsReasoningEffort,
            supportsRememberThinking: caps.supportsRememberThinking,
            prefersResponsesAPI: caps.prefersResponsesAPI,
            requiresResponsesAPIForTools: caps.requiresResponsesAPIForTools,
            rejectsTemperature: caps.rejectsTemperature,
            usesMaxCompletionTokens: caps.usesMaxCompletionTokens,
            isLocalMLX: caps.isLocalMLX,
            supportsReasoningMode: caps.supportsReasoningMode,
            releaseDate: caps.releaseDate,
            supportsVision: live.supportsVision ?? caps.supportsVision,
            supportsReasoningSummary: caps.supportsReasoningSummary
        )
    }

    public static func clampContextTokens(
        _ requested: Int?,
        capabilities: ModelCapabilities
    ) -> Int? {
        guard let requested else { return nil }
        let lower = 1
        let upper = max(capabilities.contextWindowTokens, lower)
        return min(max(requested, lower), upper)
    }

    /// Returns a value that is legal to send, or nil when the field should be omitted.
    public static func sanitizedReasoningEffort(
        _ requested: ReasoningEffort?,
        capabilities: ModelCapabilities
    ) -> ReasoningEffort? {
        guard capabilities.supportsThinking else { return nil }
        if let requested, capabilities.supportedReasoningEfforts.contains(requested) {
            return requested
        }
        if requested != nil || capabilities.alwaysSendsReasoningEffort {
            return capabilities.defaultReasoningEffort
        }
        return nil
    }

    public static func contextChoices(for capabilities: ModelCapabilities) -> [Int] {
        var sizes = contextSizePresets.filter { $0 <= capabilities.contextWindowTokens }
        if !sizes.contains(capabilities.contextWindowTokens) {
            sizes.append(capabilities.contextWindowTokens)
        }
        return sizes
    }

    public static func contextLabel(tokens: Int) -> String {
        if tokens == astraContextWindowTokens {
            return "1.05M"
        }
        if tokens >= 1_000_000, tokens % 1_000_000 == 0 {
            return "\(tokens / 1_000_000)M"
        }
        if tokens >= 1000, tokens % 1000 == 0 {
            return "\(tokens / 1000)K"
        }
        // 1024-based sizes (8,192 / 16,384 / 32,768 / …) still read as 8K / 16K / 32K.
        if tokens >= 1024, tokens % 1024 == 0 {
            return "\(tokens / 1024)K"
        }
        return "\(tokens)"
    }

    public static func displayName(forModelID modelID: String, backend: ModelBackendKind) -> String {
        capabilities(forModelID: modelID, backend: backend).displayName
    }

    public static func isImageGenerationModel(_ modelID: String) -> Bool {
        let leaf = leafModelID(modelID)
        if leaf.hasPrefix("dall-e") { return true }
        if leaf.hasPrefix("gpt-image") || leaf.hasPrefix("chatgpt-image") { return true }
        if leaf.hasPrefix("grok-imagine-image") { return true }
        return false
    }

    public static func isChatModel(_ modelID: String) -> Bool {
        let leaf = leafModelID(modelID)
        if isImageGenerationModel(leaf) { return false }
        if leaf.hasPrefix("grok-imagine-video") { return false }
        if leaf.contains("embed") || leaf.contains("tts") || leaf.contains("whisper")
            || leaf.contains("transcribe") || leaf.contains("moderation")
            || leaf.contains("realtime") || leaf.contains("babbage") || leaf.contains("davinci") {
            return false
        }
        return true
    }

    /// Newest first. Uses `/v1/models` `created` when present, else catalog release dates.
    public static func newestChatModels(
        _ models: [RemoteModelDescriptor],
        limit: Int = 10
    ) -> [String] {
        let chat = models.filter { isChatModel($0.id) }
        let sorted = chat.sorted { lhs, rhs in
            let left = lhs.created ?? capabilities(forModelID: lhs.id, backend: .remote).releaseDate
            let right = rhs.created ?? capabilities(forModelID: rhs.id, backend: .remote).releaseDate
            if left != right { return left > right }
            return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
        }
        return Array(sorted.prefix(limit)).map(\.id)
    }

    // MARK: - Private

    private static func appleFoundationCapabilities(modelID: String) -> ModelCapabilities {
        ModelCapabilities(
            modelID: modelID,
            displayName: "Apple On-Device",
            contextWindowTokens: 4096,
            maxOutputTokens: 4096,
            releaseDate: 1_751_328_000
        )
    }

    private static func localMLXCapabilities(modelID: String) -> ModelCapabilities {
        ModelCapabilities(
            modelID: modelID,
            displayName: modelID,
            contextWindowTokens: 131_072,
            maxOutputTokens: 4096,
            isLocalMLX: true,
            releaseDate: 1_704_067_200
        )
    }

    /// Models whose chat template accepts only the catalog's levels (Qwen3.8 raises
    /// "Unexpected reasoning effort" on anything but `low`, `medium` and `xhigh`).
    static func hasFixedReasoningEfforts(_ modelID: String) -> Bool {
        leafModelID(modelID).hasPrefix("qwen3.8")
    }

    private static func remoteCapabilities(modelID: String) -> ModelCapabilities {
        let leaf = leafModelID(modelID)
        if leaf.hasPrefix("qwen3.8") {
            // Thinking model, `xhigh` by default in its template; LM Studio and llama.cpp apply
            // that default when no level is sent, so nothing is sent unless one is picked.
            return ModelCapabilities(
                modelID: modelID,
                displayName: modelID,
                contextWindowTokens: 262_144,
                maxOutputTokens: 32_768,
                supportedReasoningEfforts: [.low, .medium, .xhigh],
                defaultReasoningEffort: nil,
                alwaysSendsReasoningEffort: false,
                releaseDate: ReleaseDate.qwen38
            )
        }
        if leaf == astraModelID || leaf.hasPrefix("gpt-6-astra") {
            return astraCapabilities(modelID: modelID)
        }
        if leaf.hasPrefix("gpt-6.1") {
            return gpt6Family(
                modelID: modelID,
                displayName: "GPT-6.1 Sol",
                efforts: astraReasoningEfforts,
                alwaysSends: true,
                requiresResponsesForTools: true,
                releaseDate: ReleaseDate.gpt61Sol
            )
        }
        if leaf.hasPrefix("gpt-6-luna") {
            return gpt6Family(
                modelID: modelID,
                displayName: "GPT-6 Luna",
                efforts: [.none] + astraReasoningEfforts,
                alwaysSends: false,
                requiresResponsesForTools: true,
                releaseDate: ReleaseDate.gpt6Luna
            )
        }
        if leaf.hasPrefix("gpt-6-sol") || leaf == "gpt-6" {
            return gpt6Family(
                modelID: modelID,
                displayName: "GPT-6 Sol",
                efforts: [.none] + astraReasoningEfforts,
                alwaysSends: false,
                requiresResponsesForTools: true,
                releaseDate: ReleaseDate.gpt6Sol
            )
        }
        if leaf.hasPrefix("gpt-6") {
            return gpt6Family(
                modelID: modelID,
                displayName: modelID,
                efforts: astraReasoningEfforts,
                alwaysSends: true,
                requiresResponsesForTools: true,
                releaseDate: ReleaseDate.gpt6Sol
            )
        }
        if leaf.hasPrefix("gpt-5.6") {
            let name: String
            if leaf.contains("luna") { name = "GPT-5.6 Luna" }
            else if leaf.contains("terra") { name = "GPT-5.6 Terra" }
            else { name = "GPT-5.6 Sol" }
            return ModelCapabilities(
                modelID: modelID,
                displayName: name,
                contextWindowTokens: astraContextWindowTokens,
                maxOutputTokens: astraMaxOutputTokens,
                supportedReasoningEfforts: [.none, .low, .medium, .high, .xhigh, .max],
                defaultReasoningEffort: .medium,
                alwaysSendsReasoningEffort: false,
                supportsRememberThinking: true,
                prefersResponsesAPI: true,
                requiresResponsesAPIForTools: false,
                rejectsTemperature: true,
                usesMaxCompletionTokens: true,
                supportsReasoningMode: true,
                releaseDate: ReleaseDate.gpt56
            )
        }
        if isGPT5Family(leaf) || isOSeries(leaf) {
            return ModelCapabilities(
                modelID: modelID,
                displayName: modelID,
                contextWindowTokens: gpt5ContextWindow(leaf),
                maxOutputTokens: 32_768,
                supportedReasoningEfforts: [.none, .minimal, .low, .medium, .high, .xhigh, .max],
                defaultReasoningEffort: .medium,
                alwaysSendsReasoningEffort: false,
                supportsRememberThinking: true,
                prefersResponsesAPI: true,
                requiresResponsesAPIForTools: false,
                rejectsTemperature: true,
                usesMaxCompletionTokens: true,
                supportsReasoningMode: leaf.hasPrefix("gpt-5.6") || leaf.hasPrefix("gpt-5.4"),
                releaseDate: ReleaseDate.gpt5
            )
        }
        if leaf.hasPrefix("grok-4.7") || leaf.hasPrefix("grok-4.6") {
            return grokReasoning(
                modelID: modelID,
                displayName: leaf.hasPrefix("grok-4.7") ? "Grok 4.7" : "Grok 4.6",
                efforts: [.low, .medium, .high, .xhigh],
                releaseDate: leaf.hasPrefix("grok-4.7") ? ReleaseDate.grok47 : ReleaseDate.grok46
            )
        }
        if leaf.hasPrefix("grok-4.5") {
            return grokReasoning(
                modelID: modelID,
                displayName: "Grok 4.5",
                efforts: [.low, .medium, .high],
                releaseDate: ReleaseDate.grok45
            )
        }
        if leaf.hasPrefix("grok-4.20-multi-agent") {
            return grokReasoning(
                modelID: modelID,
                displayName: "Grok 4.20 Multi-Agent",
                efforts: [.low, .medium, .high, .xhigh],
                releaseDate: ReleaseDate.grok46
            )
        }
        if leaf.hasPrefix("grok-imagine-image") {
            return ModelCapabilities(
                modelID: modelID,
                displayName: "Grok Imagine Image",
                contextWindowTokens: 8_192,
                maxOutputTokens: 0,
                releaseDate: ReleaseDate.grokImagine
            )
        }
        if leaf.hasPrefix("grok") {
            return ModelCapabilities(
                modelID: modelID,
                displayName: modelID,
                contextWindowTokens: 500_000,
                maxOutputTokens: 32_768,
                prefersResponsesAPI: true,
                rejectsTemperature: false,
                usesMaxCompletionTokens: true,
                releaseDate: ReleaseDate.grok45
            )
        }
        if leaf.hasPrefix("gpt-4.1") {
            return ModelCapabilities(
                modelID: modelID,
                displayName: modelID,
                contextWindowTokens: 1_047_576,
                maxOutputTokens: 32_768,
                usesMaxCompletionTokens: true,
                releaseDate: ReleaseDate.gpt41
            )
        }
        if leaf.hasPrefix("gpt-4o") {
            return ModelCapabilities(
                modelID: modelID,
                displayName: modelID,
                contextWindowTokens: 128_000,
                maxOutputTokens: 16_384,
                releaseDate: leaf.contains("mini") ? ReleaseDate.gpt4oMini : ReleaseDate.gpt4o
            )
        }
        return ModelCapabilities(
            modelID: modelID,
            displayName: modelID,
            contextWindowTokens: 128_000,
            maxOutputTokens: 4096
        )
    }

    private static func astraCapabilities(modelID: String) -> ModelCapabilities {
        gpt6Family(
            modelID: modelID,
            displayName: "GPT-6 Astra",
            efforts: astraReasoningEfforts,
            alwaysSends: true,
            requiresResponsesForTools: true,
            releaseDate: ReleaseDate.gpt6Astra
        )
    }

    private static func gpt6Family(
        modelID: String,
        displayName: String,
        efforts: [ReasoningEffort],
        alwaysSends: Bool,
        requiresResponsesForTools: Bool,
        releaseDate: Int
    ) -> ModelCapabilities {
        ModelCapabilities(
            modelID: modelID,
            displayName: displayName,
            contextWindowTokens: astraContextWindowTokens,
            maxOutputTokens: astraMaxOutputTokens,
            supportedReasoningEfforts: efforts,
            defaultReasoningEffort: .medium,
            alwaysSendsReasoningEffort: alwaysSends,
            supportsRememberThinking: true,
            prefersResponsesAPI: true,
            requiresResponsesAPIForTools: requiresResponsesForTools,
            rejectsTemperature: true,
            usesMaxCompletionTokens: true,
            supportsReasoningMode: true,
            releaseDate: releaseDate,
            supportsReasoningSummary: true
        )
    }

    private static func grokReasoning(
        modelID: String,
        displayName: String,
        efforts: [ReasoningEffort],
        releaseDate: Int
    ) -> ModelCapabilities {
        ModelCapabilities(
            modelID: modelID,
            displayName: displayName,
            contextWindowTokens: 500_000,
            maxOutputTokens: 32_768,
            supportedReasoningEfforts: efforts,
            defaultReasoningEffort: .high,
            alwaysSendsReasoningEffort: true,
            supportsRememberThinking: true,
            prefersResponsesAPI: true,
            requiresResponsesAPIForTools: true,
            rejectsTemperature: true,
            usesMaxCompletionTokens: true,
            releaseDate: releaseDate,
            supportsReasoningSummary: true
        )
    }

    private enum ReleaseDate {
        static let gpt4o = 1_715_558_400
        static let gpt4oMini = 1_721_260_800
        static let gpt41 = 1_744_588_800
        static let gpt5 = 1_754_524_800
        static let gpt56 = 1_771_200_000
        static let gpt6Sol = 1_773_532_800
        static let gpt61Sol = 1_776_643_200
        static let gpt6Astra = 1_777_507_200
        static let gpt6Luna = 1_779_062_400
        static let grok45 = 1_772_582_400
        static let grok46 = 1_775_347_200
        static let grok47 = 1_778_198_400
        static let grokImagine = 1_775_347_200
        static let qwen38 = 1_786_665_600
    }

    private static func isGPT5Family(_ leaf: String) -> Bool {
        leaf.hasPrefix("gpt-5")
    }

    private static func isOSeries(_ leaf: String) -> Bool {
        leaf.hasPrefix("o1") || leaf.hasPrefix("o3") || leaf.hasPrefix("o4")
    }

    private static func gpt5ContextWindow(_ leaf: String) -> Int {
        if leaf.contains("pro") || leaf.hasPrefix("gpt-5.4") || leaf.hasPrefix("gpt-5.6") {
            return 1_050_000
        }
        return 400_000
    }
}
