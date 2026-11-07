// SPDX-License-Identifier: MIT
import Foundation
import AIModelOptions

/// User-visible Tool Format picker strings. Kept in one place so they are easy
/// to swap (for example "Standard (OpenAI)" vs "Standard (most models)").
public enum ToolFormatLabels {
    public static let automatic = "Automatic"
    public static let standard = "Standard (OpenAI)"
    public static let gptOSS = "GPT-OSS (Harmony)"
}

/// Wire protocol / response encoding for a remote model provider connection.
///
/// The Settings picker is labeled **Tool Format**. Automatic (the LM Studio
/// default) picks Harmony only for GPT-OSS models; everything else uses
/// standard OpenAI tools. Gemini, Ollama and Anthropic keep their own labels
/// for the connection list; they are not Tool Format options.
public enum RemoteProtocolEncoding: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic
    case openAIChatCompletions
    case lmStudioHarmony
    case geminiOpenAI
    case ollamaNative
    case anthropicMessages

    public var id: String { rawValue }

    /// Encodings the Tool Format picker offers. Connection types stay off this list.
    public static let toolFormatPickerCases: [RemoteProtocolEncoding] = [
        .automatic, .openAIChatCompletions, .lmStudioHarmony,
    ]

    public var offersToolFormatPicker: Bool {
        Self.toolFormatPickerCases.contains(self)
    }

    public var displayName: String {
        switch self {
        case .automatic: ToolFormatLabels.automatic
        case .openAIChatCompletions: ToolFormatLabels.standard
        case .lmStudioHarmony: ToolFormatLabels.gptOSS
        case .geminiOpenAI: "Gemini (OpenAI-compatible)"
        case .ollamaNative: "Ollama"
        case .anthropicMessages: "Anthropic Messages (Claude)"
        }
    }

    public var subtitle: String {
        switch self {
        case .automatic:
            "Harmony for GPT-OSS models, standard OpenAI tools for every other model"
        case .openAIChatCompletions:
            "OpenAI-style tools on /v1/chat/completions"
        case .lmStudioHarmony:
            "GPT-OSS Harmony tokens plus OpenAI tools"
        case .geminiOpenAI:
            "Google generativelanguage.googleapis.com OpenAI shim"
        case .ollamaNative:
            "Ollama /api/chat and /api/tags endpoints"
        case .anthropicMessages:
            "Native Claude /v1/messages API with required max_tokens"
        }
    }

    public var supportsStructuredTools: Bool {
        switch self {
        case .automatic, .openAIChatCompletions, .geminiOpenAI, .ollamaNative, .lmStudioHarmony:
            true
        case .anthropicMessages:
            false
        }
    }
}

/// Which OpenAI endpoint an OpenAI-style connection talks to.
public enum OpenAIAPIChoice: String, Codable, CaseIterable, Identifiable, Sendable {
    /// An AI Odyssey's routing: Responses on OpenAI and xAI for reasoning and tool calls, Chat Completions elsewhere.
    case automatic
    case chatCompletions
    case responses

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .automatic: "Automatic"
        case .chatCompletions: "Chat Completions"
        case .responses: "Responses"
        }
    }

    public var subtitle: String {
        switch self {
        case .automatic: "Responses on OpenAI and xAI for reasoning models and tool calls, Chat Completions everywhere else."
        case .chatCompletions: "Always /chat/completions. Thinking is sent as reasoning_effort."
        case .responses: "Always /responses. Thinking is sent as reasoning.effort, and tool calls go back as function_call_output."
        }
    }
}

/// A configured remote model provider endpoint with its own encoding adapter.
public struct RemoteConnection: Identifiable, Codable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var apiBaseURL: String
    public var apiKey: String
    public var defaultModel: String
    public var availableModels: [String]
    public var encoding: RemoteProtocolEncoding
    public var isEnabled: Bool
    /// `/v1/models` `created` timestamps, keyed by model id.
    public var modelCreatedAt: [String: Int]?
    /// Issued Sign in with ChatGPT client id (`oaiapp_…`). Never `dynamic_agent_client`.
    public var chatgptIssuedClientID: String?
    public var chatgptEmail: String?
    public var chatgptSubject: String?
    /// True when `chatgpt.tokens.use.direct` was granted. Tokens stay in Keychain.
    public var chatgptPlanEligible: Bool?
    /// OpenAI API choice for OpenAI-style connections. Nil is ``OpenAIAPIChoice/automatic``.
    public var openAIAPI: OpenAIAPIChoice?
    /// Tool calling per model id, from the provider's `/models` capability info.
    public var modelToolSupport: [String: Bool]?
    /// Context, vision, and reasoning from LM Studio `/api/v1/models` (or v0).
    public var liveModelCapabilities: [String: LiveModelCapabilities]?
    /// True once a model refresh got an answer from LM Studio's own `/api/v1/models` (or v0)
    /// list, so LM Studio on any port is treated as LM Studio. Nil before any such answer.
    public var detectedLMStudio: Bool?
    /// True once the server answered Ollama's `GET /api/version`. Nil before any answer.
    public var detectedOllama: Bool?
    /// The normalized base URL the detection above was learned from. Detection only counts
    /// while the connection still points there, so a repointed row is checked again.
    public var detectedBaseURL: String?
    /// Which detection rules saved the answer above. Builds 55–58 saved none and could save a
    /// "no" from an error status, so their "no" is checked again.
    public var detectionVersion: Int?
    /// Only 404/405, or a successful reply that isn't LM Studio's list, counts as "not LM Studio".
    public static let serverDetectionVersion = 2

    public init(
        id: String = UUID().uuidString,
        name: String,
        apiBaseURL: String,
        apiKey: String = "",
        defaultModel: String = "",
        availableModels: [String] = [],
        encoding: RemoteProtocolEncoding = .openAIChatCompletions,
        isEnabled: Bool = true,
        modelCreatedAt: [String: Int]? = nil,
        chatgptIssuedClientID: String? = nil,
        chatgptEmail: String? = nil,
        chatgptSubject: String? = nil,
        chatgptPlanEligible: Bool? = nil,
        openAIAPI: OpenAIAPIChoice? = nil,
        modelToolSupport: [String: Bool]? = nil,
        liveModelCapabilities: [String: LiveModelCapabilities]? = nil,
        detectedLMStudio: Bool? = nil,
        detectedOllama: Bool? = nil,
        detectedBaseURL: String? = nil
    ) {
        self.id = id
        self.name = name
        self.apiBaseURL = apiBaseURL
        self.apiKey = apiKey
        self.defaultModel = defaultModel
        self.availableModels = availableModels
        self.encoding = encoding
        self.isEnabled = isEnabled
        self.modelCreatedAt = modelCreatedAt
        self.chatgptIssuedClientID = chatgptIssuedClientID
        self.chatgptEmail = chatgptEmail
        self.chatgptSubject = chatgptSubject
        self.chatgptPlanEligible = chatgptPlanEligible
        self.openAIAPI = openAIAPI
        self.modelToolSupport = modelToolSupport
        self.liveModelCapabilities = liveModelCapabilities
        self.detectedLMStudio = detectedLMStudio
        self.detectedOllama = detectedOllama
        self.detectedBaseURL = detectedBaseURL
    }

    public func liveCapabilities(for modelID: String) -> LiveModelCapabilities? {
        liveModelCapabilities?[modelID]
    }

    public var apiChoice: OpenAIAPIChoice { openAIAPI ?? .automatic }

    /// Only plain OpenAI-style connections can pick an endpoint. Sign in with ChatGPT is Responses only.
    public var offersAPIChoice: Bool {
        encoding == .openAIChatCompletions && !usesChatGPTAccount
    }

    /// Encoding used for `modelID`. Automatic is Harmony for GPT-OSS, OpenAI otherwise.
    public func resolvedEncoding(forModel modelID: String) -> RemoteProtocolEncoding {
        switch encoding {
        case .automatic:
            return Self.looksLikeGPTOSS(modelID) ? .lmStudioHarmony : .openAIChatCompletions
        default:
            return encoding
        }
    }

    /// LM Studio and other OpenAI-style rows can pick a Tool Format. Gemini,
    /// Ollama and Anthropic hide the picker — those encodings *are* the connection type.
    public var showsToolFormatPicker: Bool { encoding.offersToolFormatPicker }

    /// Shown under the picker when Automatic is selected, e.g.
    /// "Using Standard (OpenAI) for qwen3.8-27b."
    public func automaticResolutionCaption(forModel modelID: String? = nil) -> String? {
        guard encoding == .automatic else { return nil }
        let model = (modelID ?? trimmedModel).trimmingCharacters(in: .whitespacesAndNewlines)
        let picked = resolvedEncoding(forModel: model).displayName
        if model.isEmpty {
            return "Using \(picked)."
        }
        return "Using \(picked) for \(model)."
    }

    public static func looksLikeGPTOSS(_ modelID: String) -> Bool {
        ToolFormatFallbackPolicy.looksLikeGPTOSS(modelID)
    }

    /// Saved Harmony rows whose model is not GPT-OSS become Automatic.
    public mutating func migrateOffStaleHarmony() {
        guard encoding == .lmStudioHarmony else { return }
        if trimmedModel.isEmpty || !Self.looksLikeGPTOSS(trimmedModel) {
            encoding = .automatic
        }
    }

    public static func migrateToolFormat(_ connections: [RemoteConnection]) -> [RemoteConnection] {
        connections.map { connection in
            var copy = connection
            copy.migrateOffStaleHarmony()
            return copy
        }
    }

    /// Whether requests for `model` go to the Responses API.
    public func usesResponsesAPI(model: String, hasTools: Bool, hasHostedWebSearch: Bool = false) -> Bool {
        if usesChatGPTAccount { return true }
        guard resolvedEncoding(forModel: model) == .openAIChatCompletions else { return false }
        switch apiChoice {
        case .responses: return true
        case .chatCompletions: return false
        case .automatic:
            return OpenAIRequestCodec.shouldUseResponsesAPI(
                baseURL: trimmedBaseURL,
                model: model,
                hasTools: hasTools,
                hasHostedWebSearch: hasHostedWebSearch
            )
        }
    }

    /// True when this row is a Sign in with ChatGPT account (tokens in Keychain).
    public var usesChatGPTAccount: Bool {
        guard let chatgptIssuedClientID else { return false }
        let trimmed = chatgptIssuedClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != ChatGPTOAuthCodec.dynamicClientID
    }

    public var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var trimmedBaseURL: String {
        apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var trimmedModel: String {
        defaultModel.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// LM Studio, from the server's own answer: its `/api/v1` or `/api/v0` model list. Before the
    /// server has answered (or after the URL changed), the LM Studio presets (Tool Format
    /// Automatic or GPT-OSS) count. The port never decides: LM Studio runs on any port.
    /// Those servers accept `tools` on `/v1/chat/completions` for every chat model.
    public var servesLMStudioTools: Bool {
        guard encoding.offersToolFormatPicker else { return false }
        if currentOllamaDetection == true { return false }
        if let detected = currentLMStudioDetection { return detected }
        return encoding == .lmStudioHarmony || encoding == .automatic
    }

    /// Whether the saved detection was learned from the URL this connection points at now.
    public var detectionIsCurrent: Bool {
        guard let detectedBaseURL, detectedBaseURL == Self.detectionKey(trimmedBaseURL) else { return false }
        // An LM Studio list can't come from an error, so an older "yes" still stands.
        return detectedLMStudio == true || detectionVersion == Self.serverDetectionVersion
    }

    /// The saved LM Studio answer, or nil when there is none for the current URL.
    public var currentLMStudioDetection: Bool? { detectionIsCurrent ? detectedLMStudio : nil }

    /// The saved Ollama answer, or nil when there is none for the current URL.
    public var currentOllamaDetection: Bool? { detectionIsCurrent ? detectedOllama : nil }

    static func detectionKey(_ baseURL: String) -> String {
        OpenAICompatibleAPI.normalizeBaseURL(baseURL).lowercased()
    }

    /// Saves what the server said it is, for the URL it is at now.
    public mutating func recordServer(isLMStudio: Bool?, isOllama: Bool?) {
        let key = Self.detectionKey(trimmedBaseURL)
        if detectedBaseURL != key {
            detectedLMStudio = nil
            detectedOllama = nil
            detectedBaseURL = key
        }
        if let isLMStudio { detectedLMStudio = isLMStudio }
        if let isOllama { detectedOllama = isOllama }
        detectionVersion = Self.serverDetectionVersion
        if detectedLMStudio == nil && detectedOllama == nil { detectedBaseURL = nil; detectionVersion = nil }
    }

    /// This connection with `saved`'s server answer: the editor's copy shows (and saves) the
    /// latest answer. An answer for another URL doesn't count, as everywhere.
    public func withServerDetection(from saved: RemoteConnection?) -> RemoteConnection {
        guard let saved else { return self }
        var copy = self
        copy.detectedLMStudio = saved.detectedLMStudio
        copy.detectedOllama = saved.detectedOllama
        copy.detectedBaseURL = saved.detectedBaseURL
        copy.detectionVersion = saved.detectionVersion
        return copy
    }

    /// Forgets what was learned from the server (and its LM Studio model metadata): used when
    /// the base URL changes, since a new URL can be a different server.
    public mutating func clearServerDetection() {
        detectedLMStudio = nil
        detectedOllama = nil
        detectedBaseURL = nil
        detectionVersion = nil
        modelToolSupport = nil
        liveModelCapabilities = nil
    }

    /// Which provider rules apply: Ollama when the server said so, otherwise from the URL's
    /// host and path (never its port).
    public var apiProvider: RemoteAPIProvider {
        if currentOllamaDetection == true { return .ollama }
        return OpenAICompatibleAPI.detectProvider(baseURL: trimmedBaseURL)
    }

    /// Read-only "Server" line on the connection page. Nil when nothing is checked (cloud rows).
    public var detectedServerLabel: String? {
        if currentOllamaDetection == true { return "Ollama" }
        switch currentLMStudioDetection {
        case true?: return "LM Studio"
        case false?: return "OpenAI-compatible (not LM Studio)"
        case nil:
            if encoding == .automatic || encoding == .lmStudioHarmony { return "LM Studio (from Tool Format) · not checked yet" }
            return mayServeLMStudio ? "Not checked yet" : nil
        }
    }

    /// Whether a model refresh should ask this server what it is: LM Studio presets, and any
    /// OpenAI-style server on this device or the local network, whatever its port. LM Studio on
    /// a public hostname needs the Automatic Tool Format to be checked.
    public var mayServeLMStudio: Bool {
        guard encoding.offersToolFormatPicker, !usesChatGPTAccount else { return false }
        if encoding == .automatic || encoding == .lmStudioHarmony { return true }
        return OpenAICompatibleAPI.isPrivateNetworkHost(trimmedBaseURL)
    }

    /// Replaces the cached model list after a refresh while retaining the saved
    /// default whenever the provider still offers it.
    public mutating func replaceAvailableModels(with modelIDs: [String]) {
        replaceAvailableModels(with: modelIDs.map { RemoteModelDescriptor(id: $0) })
    }

    public mutating func replaceAvailableModels(with models: [RemoteModelDescriptor]) {
        guard !models.isEmpty else { return }
        availableModels = models.map(\.id)
        var created: [String: Int] = [:]
        var tools: [String: Bool] = [:]
        var live: [String: LiveModelCapabilities] = [:]
        for model in models {
            if let timestamp = model.created {
                created[model.id] = timestamp
            }
            if let supportsTools = model.supportsTools {
                tools[model.id] = supportsTools
            }
            let snapshot = LiveModelCapabilities(descriptor: model)
            if !snapshot.isEmpty {
                live[model.id] = snapshot
            }
        }
        modelCreatedAt = created.isEmpty ? nil : created
        modelToolSupport = tools.isEmpty ? nil : tools
        liveModelCapabilities = live.isEmpty ? nil : live
        if trimmedModel.isEmpty || !availableModels.contains(trimmedModel) {
            defaultModel = availableModels[0]
        }
    }
}

public extension RemoteConnection {
    static let defaultLMStudioBaseURL = "http://localhost:1234/v1"
    static let defaultOpenAIBaseURL = OpenAICompatibleAPI.defaultBaseURL
    static let defaultGeminiBaseURL = ProviderSettings.defaultGeminiBaseURL

    static let defaultXAIBaseURL = "https://api.x.ai/v1"

    static func chatGPTPreset(name: String = "ChatGPT") -> RemoteConnection {
        RemoteConnection(
            name: name,
            apiBaseURL: defaultOpenAIBaseURL,
            defaultModel: "gpt-6.1-sol",
            availableModels: ModelCapabilityCatalog.bundledOpenAIModelIDs,
            encoding: .openAIChatCompletions
        )
    }

    static func openAIPreset(name: String = "OpenAI") -> RemoteConnection {
        RemoteConnection(
            name: name,
            apiBaseURL: defaultOpenAIBaseURL,
            defaultModel: ModelCapabilityCatalog.astraModelID,
            availableModels: ModelCapabilityCatalog.bundledOpenAIModelIDs,
            encoding: .openAIChatCompletions
        )
    }

    static func xAIPreset(name: String = "xAI") -> RemoteConnection {
        RemoteConnection(
            name: name,
            apiBaseURL: defaultXAIBaseURL,
            defaultModel: "grok-4.7",
            availableModels: ModelCapabilityCatalog.bundledXAIChatModelIDs
                + ModelCapabilityCatalog.bundledXAIImageModelIDs,
            encoding: .openAIChatCompletions
        )
    }

    static func geminiPreset(name: String = "Gemini", apiKey: String = "", model: String? = nil) -> RemoteConnection {
        RemoteConnection(
            name: name,
            apiBaseURL: defaultGeminiBaseURL,
            apiKey: apiKey,
            defaultModel: model ?? ProviderSettings.defaultGeminiModel,
            encoding: .geminiOpenAI
        )
    }

    static func lmStudioPreset(name: String = "LM Studio") -> RemoteConnection {
        RemoteConnection(
            name: name,
            apiBaseURL: defaultLMStudioBaseURL,
            encoding: .automatic
        )
    }

    static func anthropicPreset(name: String = "Claude", apiKey: String = "") -> RemoteConnection {
        RemoteConnection(
            name: name,
            apiBaseURL: "https://api.anthropic.com/v1",
            apiKey: apiKey,
            defaultModel: "claude-3-5-sonnet-latest",
            encoding: .anthropicMessages
        )
    }
}
