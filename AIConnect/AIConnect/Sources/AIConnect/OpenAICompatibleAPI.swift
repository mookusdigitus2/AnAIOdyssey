// SPDX-License-Identifier: MIT
import Foundation
import AIModelOptions

/// The remote providers AIConnect knows how to talk to over an OpenAI-ish HTTP API.
///
/// Detected heuristically from the base URL so the request layer can apply the
/// right endpoint paths, headers, and quirks per provider.
public enum RemoteAPIProvider: String, Sendable {
    case openAICompatible
    case openRouter
    case ollama
    case anthropic
    case gemini
    case lmStudio
    case xAI

    /// Friendly provider name shown in pickers and labels.
    public var displayName: String {
        switch self {
        case .openAICompatible: "OpenAI / ChatGPT"
        case .openRouter: "OpenRouter"
        case .ollama: "Ollama"
        case .anthropic: "Claude"
        case .gemini: "Gemini"
        case .lmStudio: "LM Studio"
        case .xAI: "xAI"
        }
    }
}

/// Pure helpers for building requests to and parsing responses from
/// OpenAI-compatible chat APIs (OpenAI, OpenRouter, Ollama, Gemini, and—partially—Anthropic).
///
/// This type holds no state: every function is a deterministic transformation of
/// its inputs, which keeps URL construction, header assembly, payload shaping,
/// and response parsing testable and shared across `RemoteLLMService` and the
/// settings layer. Provider-specific behavior is centralized here so the
/// networking code stays uniform.
public enum OpenAICompatibleAPI {
    /// Endpoint assumed when the user hasn't configured one.
    public static let defaultBaseURL = "https://api.openai.com/v1"
    /// Model assumed when the user hasn't picked one.
    public static let defaultRemoteModel = "gpt-4o-mini"

    /// Reduces a user-entered URL to a clean base by stripping trailing slashes and known endpoint suffixes.
    ///
    /// Users often paste a full endpoint (e.g. `.../v1/chat/completions` or an
    /// Ollama `/api/chat`); this trims those back to the base so the app can
    /// re-derive the correct paths itself.
    public static func normalizeBaseURL(_ raw: String) -> String {
        // Trim whitespace and any trailing slashes first.
        var url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while url.hasSuffix("/") {
            url.removeLast()
        }

        // Strip OpenAI-style endpoint suffixes a user may have pasted.
        let suffixes = [
            "/models",
            "/chat/completions",
            "/completions",
            "/v1/messages",
            "/responses",
        ]
        for suffix in suffixes {
            if url.hasSuffix(suffix) {
                url = String(url.dropLast(suffix.count))
                while url.hasSuffix("/") {
                    url.removeLast()
                }
            }
        }

        // Strip Ollama-style endpoint suffixes, leaving the trailing `/api` intact.
        for suffix in ["/chat", "/tags", "/generate"] {
            if url.hasSuffix("/api" + suffix) {
                url = String(url.dropLast(suffix.count))
                while url.hasSuffix("/") {
                    url.removeLast()
                }
            }
        }

        return url
    }

    /// Infers the provider from host/path patterns in the base URL so the correct request shape can be chosen.
    public static func detectProvider(baseURL: String) -> RemoteAPIProvider {
        let normalized = normalizeBaseURL(baseURL).lowercased()
        if normalized.contains("openrouter.ai") {
            return .openRouter
        }
        if normalized.contains("api.x.ai") {
            return .xAI
        }
        if normalized.contains("anthropic.com") {
            return .anthropic
        }
        if normalized.contains("generativelanguage.googleapis.com") {
            return .gemini
        }
        // LM Studio runs on any port, so only a host named for it says so here; the server's
        // own model list is what marks a connection as LM Studio (RemoteConnection.detectedLMStudio).
        if normalized.contains("lmstudio") {
            return .lmStudio
        }
        // Ollama by its `/api` base or its hosted domain. Never by port: a server that answers
        // Ollama's `/api/version` is marked on the connection (RemoteConnection.apiProvider).
        if normalized.hasSuffix("/api")
            || normalized.contains("ollama.com") {
            return .ollama
        }
        return .openAICompatible
    }

    /// Builds the chat endpoint URL for the detected provider, accounting for each one's path conventions.
    public static func buildChatCompletionsURL(baseURL: String) -> URL? {
        buildChatCompletionsURL(baseURL: baseURL, provider: detectProvider(baseURL: baseURL))
    }

    /// Builds the chat endpoint URL using an explicit provider (from connection encoding).
    public static func buildChatCompletionsURL(baseURL: String, provider: RemoteAPIProvider) -> URL? {
        let base = normalizeBaseURL(baseURL)
        guard !base.isEmpty else { return nil }

        switch provider {
        case .ollama:
            return URL(string: base + "/chat")
        case .anthropic:
            let root = base.lowercased().hasSuffix("/v1")
                ? String(base.dropLast(3)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                : base
            return URL(string: root + "/v1/messages")
        case .openRouter, .openAICompatible, .gemini, .lmStudio, .xAI:
            return URL(string: base + "/chat/completions")
        }
    }

    /// Official OpenAI Responses API endpoint (`/v1/responses`).
    public static func buildResponsesURL(baseURL: String) -> URL? {
        let base = normalizeBaseURL(baseURL)
        guard !base.isEmpty else { return nil }
        return URL(string: OpenAIRequestCodec.responsesPath(normalizedBase: base))
    }

    /// Conversation URL: Responses for official OpenAI reasoning/tool requests.
    public static func buildConversationURL(
        baseURL: String,
        model: String,
        hasTools: Bool,
        provider: RemoteAPIProvider
    ) -> URL? {
        if (provider == .openAICompatible || provider == .xAI),
           OpenAIRequestCodec.shouldUseResponsesAPI(baseURL: baseURL, model: model, hasTools: hasTools) {
            return buildResponsesURL(baseURL: baseURL)
        }
        return buildChatCompletionsURL(baseURL: baseURL, provider: provider)
    }

    /// Builds the model-listing endpoint URL for the detected provider.
    public static func buildModelsURL(baseURL: String) -> URL? {
        buildModelsURL(baseURL: baseURL, provider: detectProvider(baseURL: baseURL))
    }

    /// Builds the model-listing endpoint URL using an explicit provider.
    public static func buildModelsURL(baseURL: String, provider: RemoteAPIProvider) -> URL? {
        let base = normalizeBaseURL(baseURL)
        guard !base.isEmpty else { return nil }

        switch provider {
        case .ollama:
            return URL(string: base + "/tags")
        case .anthropic:
            let root = base.lowercased().hasSuffix("/v1")
                ? String(base.dropLast(3)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                : base
            return URL(string: root + "/v1/models")
        case .openRouter, .openAICompatible, .gemini, .lmStudio, .xAI:
            return URL(string: base + "/models")
        }
    }

    // MARK: - Image generation

    /// The decoded result of an image-generation response: raw bytes when the
    /// provider inlines base64, or a URL the caller must download.
    public enum GeneratedImagePayload: Equatable, Sendable {
        case imageData(Data)
        case remoteURL(URL)
    }

    /// Whether the model id names an image-generation model (OpenAI `dall-e-*`
    /// and `gpt-image-*` / `chatgpt-image-*` families), which must be called
    /// through the `/images/generations` endpoint — sending them a chat
    /// completion fails.
    public static func isImageGenerationModel(_ model: String) -> Bool {
        ModelCapabilityCatalog.isImageGenerationModel(model)
    }

    /// GPT Image models (`gpt-image-1`, `gpt-image-1.5`, `chatgpt-image-latest`, …).
    public static func isGPTImageFamily(_ model: String) -> Bool {
        let leaf = (model.lowercased() as NSString).lastPathComponent
        return leaf.hasPrefix("gpt-image") || leaf.hasPrefix("chatgpt-image")
    }

    /// Whether the model can take a source image plus a prompt (`/images/edits`).
    /// `dall-e-3` generates only; `dall-e-2` and GPT Image models support edits.
    public static func isImageEditModel(_ model: String) -> Bool {
        let leaf = (model.lowercased() as NSString).lastPathComponent
        return isGPTImageFamily(leaf) || leaf.hasPrefix("dall-e-2")
    }

    /// MIME type for an image filename, used when posting `/images/edits`.
    public static func imageMIMEType(for filename: String) -> String {
        switch (filename as NSString).pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        case "gif": return "image/gif"
        default: return "image/png"
        }
    }

    /// Whether the model id names an API-listed model that can never answer a
    /// chat (or image) request: embeddings, speech synthesis/recognition,
    /// moderation, realtime, and legacy completions-only models. These are
    /// filtered out of conversational model pickers so users can't select a
    /// model that will not respond.
    public static func isNonConversationalModel(_ model: String) -> Bool {
        let leaf = (model.lowercased() as NSString).lastPathComponent
        if isImageGenerationModel(leaf) { return false }
        let excludedFragments = [
            "embed",
            "tts", "whisper", "transcribe",
            "moderation", "realtime",
            "babbage", "davinci",
        ]
        return excludedFragments.contains { leaf.contains($0) }
    }

    /// Builds the image-generation endpoint URL for providers that expose the
    /// OpenAI-style `/images/generations` route. Returns `nil` for providers
    /// without one so callers can surface a clear "unsupported" error.
    public static func buildImagesGenerationsURL(
        baseURL: String,
        provider: RemoteAPIProvider
    ) -> URL? {
        let base = normalizeBaseURL(baseURL)
        guard !base.isEmpty else { return nil }
        switch provider {
        case .ollama, .anthropic, .gemini:
            return nil
        case .openRouter, .openAICompatible, .lmStudio, .xAI:
            return URL(string: base + "/images/generations")
        }
    }

    /// Builds the image-edits endpoint URL for providers that expose the
    /// OpenAI-style `/images/edits` route. Returns `nil` when unsupported.
    public static func buildImagesEditsURL(
        baseURL: String,
        provider: RemoteAPIProvider
    ) -> URL? {
        let base = normalizeBaseURL(baseURL)
        guard !base.isEmpty else { return nil }
        switch provider {
        case .ollama, .anthropic, .gemini:
            return nil
        case .openRouter, .openAICompatible, .lmStudio, .xAI:
            return URL(string: base + "/images/edits")
        }
    }

    /// Multipart body for `/images/edits`: prompt + model + source image file.
    public static func imageEditFormBody(
        model: String,
        prompt: String,
        imageData: Data,
        filename: String,
        mimeType: String,
        size: String = "1024x1024"
    ) -> (data: Data, contentType: String) {
        let boundary = "AIConnectBoundary\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        var body = Data()
        func appendField(name: String, value: String) {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.append("\(value)\r\n")
        }
        appendField(name: "model", value: model)
        appendField(name: "prompt", value: prompt)
        appendField(name: "n", value: "1")
        appendField(name: "size", value: size)
        if isGPTImageFamily(model) {
            appendField(name: "output_format", value: "png")
        } else {
            appendField(name: "response_format", value: "b64_json")
        }
        // GPT Image models expect array-style `image[]`; dall-e-2 uses `image`.
        let imageField = isGPTImageFamily(model) ? "image[]" : "image"
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"\(imageField)\"; filename=\"\(filename)\"\r\n")
        body.append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(imageData)
        body.append("\r\n")
        body.append("--\(boundary)--\r\n")
        return (body, "multipart/form-data; boundary=\(boundary)")
    }

    /// Builds the JSON request body for an image generation.
    ///
    /// `dall-e-*` models return URLs unless base64 is requested explicitly;
    /// `gpt-image-*` models always return base64 and reject `response_format`.
    public static func imageGenerationPayload(
        model: String,
        prompt: String,
        size: String = "1024x1024"
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "n": 1,
            "size": size,
        ]
        if isGPTImageFamily(model) {
            payload["output_format"] = "png"
        } else {
            payload["response_format"] = "b64_json"
        }
        return payload
    }

    /// Parses an `/images/generations` response into image bytes or a download
    /// URL, surfacing the provider's own error message on failure.
    public static func parseImageGenerationResponse(_ data: Data) throws -> GeneratedImagePayload {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMServiceError.generationFailed("Image provider returned invalid JSON.")
        }
        if let error = object["error"] as? [String: Any] {
            let message = error["message"] as? String ?? String(describing: error)
            throw LLMServiceError.generationFailed(message)
        }
        guard let items = object["data"] as? [[String: Any]], let first = items.first else {
            throw LLMServiceError.generationFailed("Image provider returned no image data.")
        }
        if let base64 = first["b64_json"] as? String,
           let imageData = Data(base64Encoded: base64),
           !imageData.isEmpty {
            return .imageData(imageData)
        }
        if let urlString = first["url"] as? String, let url = URL(string: urlString) {
            return .remoteURL(url)
        }
        throw LLMServiceError.generationFailed("Image provider returned an unrecognized image payload.")
    }

    /// Whether the URL points at the local machine (loopback or `.local`).
    public static func isLocalHost(_ baseURL: String) -> Bool {
        guard let host = URL(string: normalizeBaseURL(baseURL))?.host?.lowercased() else {
            return false
        }
        return host == "localhost"
            || host == "127.0.0.1"
            || host == "::1"
            || host.hasSuffix(".local")
    }

    /// Whether the URL targets this Mac or a private network: loopback (127/8, ::1), RFC 1918
    /// (10/8, 172.16/12, 192.168/16), carrier-grade NAT / Tailscale (100.64/10), IPv6 unique-local
    /// (fc00::/7) and link-local (fe80::/10), and `.local`, `.lan` and Tailscale `*.ts.net` names.
    ///
    /// Used to relax requirements for self-hosted servers (e.g. Ollama/LM Studio)
    /// that typically need no API key and may not expose a model list.
    public static func isPrivateNetworkHost(_ baseURL: String) -> Bool {
        guard var host = URL(string: normalizeBaseURL(baseURL))?.host?.lowercased() else {
            return false
        }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if isLocalHost(baseURL) { return true }
        if host.hasSuffix(".lan") || host.hasSuffix(".ts.net") { return true }

        if let octets = ipv4Octets(host) {
            switch (octets[0], octets[1]) {
            case (127, _), (10, _), (192, 168): return true
            case (172, 16...31): return true
            case (100, 64...127): return true
            default: return false
            }
        }

        // IPv6 literals: fc00::/7 (unique local, fd00::/8 in practice) and fe80::/10 (link local).
        if host.contains(":"), let first = host.split(separator: ":", omittingEmptySubsequences: false).first,
           let group = UInt16(first, radix: 16), !first.isEmpty {
            return group & 0xFE00 == 0xFC00 || group & 0xFFC0 == 0xFE80
        }
        return false
    }

    /// The four octets of a dotted IPv4 literal, or nil for anything else (`10.foo.com`).
    private static func ipv4Octets(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber) else { return nil }
            return Int(part).flatMap { (0...255).contains($0) ? $0 : nil }
        }
        return octets.count == 4 ? octets : nil
    }

    /// Whether an API key is mandatory. Only the known cloud providers (OpenAI, xAI, Anthropic,
    /// Gemini, OpenRouter) always need one. Every other server (LM Studio, Ollama, llama.cpp, a
    /// reverse proxy) decides for itself, wherever it is: a blank key sends no `Authorization`
    /// header, and a server that wants one answers 401. Decided by host, never by port. A URL with
    /// no host fails closed.
    public static func requiresAPIKey(baseURL: String) -> Bool {
        guard var host = URL(string: normalizeBaseURL(baseURL))?.host?.lowercased(), !host.isEmpty else {
            return true
        }
        while host.hasSuffix(".") { host.removeLast() }
        return keyRequiredDomains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// The cloud providers' own domains (and their subdomains), which always need a key.
    private static let keyRequiredDomains = [
        "openai.com",                          // OpenAI
        "x.ai",                                // xAI
        "anthropic.com",                       // Anthropic
        "generativelanguage.googleapis.com",   // Gemini
        "openrouter.ai",                       // OpenRouter
    ]

    /// Whether the given URL+key combination is complete enough to attempt requests.
    public static func isConfigured(baseURL: String, apiKey: String) -> Bool {
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty, buildChatCompletionsURL(baseURL: trimmedURL) != nil else {
            return false
        }
        if requiresAPIKey(baseURL: trimmedURL) {
            return !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    /// Assembles the HTTP headers for a request, applying each provider's auth scheme and extras.
    ///
    /// Anthropic uses `x-api-key` + a version header; OpenRouter wants referer/title
    /// attribution headers; the rest use standard `Authorization: Bearer`. When
    /// `streaming` is true, also requests an SSE response.
    public static func requestHeaders(
        baseURL: String,
        apiKey: String,
        streaming: Bool
    ) -> [String: String] {
        requestHeaders(
            baseURL: baseURL,
            apiKey: apiKey,
            streaming: streaming,
            provider: detectProvider(baseURL: baseURL)
        )
    }

  public static func requestHeaders(
        baseURL: String,
        apiKey: String,
        streaming: Bool,
        provider: RemoteAPIProvider
    ) -> [String: String] {
        var headers = ["Content-Type": "application/json"]
        if streaming {
            headers["Accept"] = "text/event-stream"
            headers["Cache-Control"] = "no-cache"
            headers["X-Accel-Buffering"] = "no"
        }

        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        switch provider {
        case .anthropic:
            if !trimmedKey.isEmpty {
                headers["x-api-key"] = trimmedKey
            }
            headers["anthropic-version"] = "2023-06-01"
        case .openRouter:
            if !trimmedKey.isEmpty {
                headers["Authorization"] = "Bearer \(trimmedKey)"
            }
            headers["HTTP-Referer"] = AIProjectHomepage.url
            headers["X-OpenRouter-Title"] = AIConnectBranding.appName
        case .ollama, .openAICompatible, .gemini, .lmStudio, .xAI:
            if !trimmedKey.isEmpty {
                headers["Authorization"] = "Bearer \(trimmedKey)"
            }
        }

        return headers
    }

    /// Builds the JSON request body for a chat completion.
    ///
    /// Omits `temperature` for newer reasoning models that reject it, and only
    /// sets `max_completion_tokens` for non-streaming requests to models that use
    /// that newer field, avoiding 400s from stricter providers.
    public static func chatPayload(
        model: String,
        messages: [[String: String]],
        stream: Bool,
        temperature: Double = 0.7
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": stream,
        ]

        // Some reasoning models reject an explicit temperature.
        if !restrictsTemperature(model) {
            payload["temperature"] = temperature
        }

        // Do not invent a max-token cap. The user-set Options value is applied later.
        if stream {
            payload["stream_options"] = ["include_usage": true]
        }

        return payload
    }

    /// OpenAI chat payload with native tool definitions.
    public static func chatPayload(
        model: String,
        messages: [[String: String]],
        stream: Bool,
        temperature: Double = 0.7,
        tools: [[String: Any]]
    ) -> [String: Any] {
        chatPayload(
            model: model,
            typedMessages: ChatCompletionMessage.from(messages),
            stream: stream,
            temperature: temperature,
            tools: tools
        )
    }

    /// Chat Completions body that can carry `tool_calls` and `tool_call_id`.
    public static func chatPayload(
        model: String,
        typedMessages: [ChatCompletionMessage],
        stream: Bool,
        temperature: Double = 0.7,
        tools: [[String: Any]] = []
    ) -> [String: Any] {
        var payload = chatPayload(
            model: model,
            messages: typedMessages.map { ["role": $0.role, "content": $0.content] },
            stream: stream,
            temperature: temperature
        )
        payload["messages"] = typedMessages.map(\.jsonObject)
        if !tools.isEmpty {
            payload["tools"] = tools
            payload["tool_choice"] = "auto"
        }
        return payload
    }

    /// Anthropic Messages API payload with top-level system and required max_tokens.
    public static func anthropicMessagesPayload(
        model: String,
        messages: [[String: String]],
        stream: Bool,
        maxTokens: Int = 4096
    ) -> [String: Any] {
        var systemParts: [String] = []
        var anthropicMessages: [[String: Any]] = []
        for message in messages {
            let role = message["role"] ?? "user"
            let content = message["content"] ?? ""
            if role == "system" {
                systemParts.append(content)
            } else {
                anthropicMessages.append([
                    "role": role == "assistant" ? "assistant" : "user",
                    "content": content,
                ])
            }
        }
        var payload: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": anthropicMessages,
            "stream": stream,
        ]
        if !systemParts.isEmpty {
            payload["system"] = systemParts.joined(separator: "\n\n")
        }
        return payload
    }

    public static func parseAnthropicCompletionResponse(_ data: Data) throws -> String {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMServiceError.generationFailed("Anthropic returned invalid JSON.")
        }
        if let error = object["error"] as? [String: Any] {
            let message = error["message"] as? String ?? String(describing: error)
            throw LLMServiceError.generationFailed(message)
        }
        if let content = object["content"] as? [[String: Any]] {
            let text = content.compactMap { block -> String? in
                guard block["type"] as? String == "text" else { return nil }
                return block["text"] as? String
            }.joined()
            if !text.isEmpty { return text }
        }
        throw LLMServiceError.generationFailed("Anthropic returned no assistant content.")
    }

    public static func parseAnthropicStreamingChunk(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        switch object["type"] as? String {
        case "content_block_delta":
            if let delta = object["delta"] as? [String: Any],
               delta["type"] as? String == "text_delta" {
                return delta["text"] as? String
            }
        case "message_delta":
            if let delta = object["delta"] as? [String: Any],
               let text = delta["text"] as? String {
                return text
            }
        default:
            break
        }
        return nil
    }

    /// Parses native `tool_calls` from a non-streaming OpenAI response.
    public static func parseStructuredToolCalls(from data: Data) -> [ToolCallBlock] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let toolCalls = message["tool_calls"] as? [[String: Any]] else {
            return []
        }
        return toolCalls.compactMap { ToolCallParsing.toolBlock(from: $0) }
    }

    /// Parses incremental `tool_calls` deltas from a streaming chunk.
    public static func parseStructuredToolCallDelta(from json: String) -> ToolCallBlock? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any],
              let toolCalls = delta["tool_calls"] as? [[String: Any]],
              let first = toolCalls.first else {
            return nil
        }
        return ToolCallParsing.toolBlock(from: ["function": first["function"] as Any])
    }

    /// Accumulates streamed `tool_calls` deltas until the full argument JSON is available.
    public struct StructuredToolCallAccumulator {
        private var entries: [Int: (id: String?, name: String?, arguments: String)] = [:]

        public init() {}

        public mutating func append(delta: [String: Any]) {
            guard let toolCalls = delta["tool_calls"] as? [[String: Any]] else { return }
            for call in toolCalls {
                let index = call["index"] as? Int ?? 0
                var entry = entries[index] ?? (id: nil, name: nil, arguments: "")
                if let id = call["id"] as? String, !id.isEmpty {
                    entry.id = id
                }
                if let function = call["function"] as? [String: Any] {
                    if let name = function["name"] as? String, !name.isEmpty {
                        entry.name = name
                    }
                    if let args = function["arguments"] as? String {
                        entry.arguments += args
                    }
                }
                entries[index] = entry
            }
        }

        public mutating func append(json: String) {
            guard let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = object["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any] else {
                return
            }
            append(delta: delta)
        }

        public func encodedCalls() -> [EncodedFunctionCall] {
            entries.keys.sorted().compactMap { index in
                guard let entry = entries[index], let name = entry.name else { return nil }
                return EncodedFunctionCall(name: name, arguments: entry.arguments, callID: entry.id)
            }
        }

        public func finish() -> [ToolCallBlock] {
            encodedCalls().compactMap { call in
                var payload: [String: Any] = [
                    "function": [
                        "name": call.name,
                        "arguments": call.arguments,
                    ] as [String: Any],
                ]
                if let callID = call.callID {
                    payload["id"] = callID
                }
                return ToolCallParsing.toolBlock(from: payload)
            }
        }
    }

    /// Converts chat history into the API's message array, appending the new user prompt unless it's already the last turn.
    ///
    /// Avoids duplicating the prompt when the caller has already included it in
    /// `history` (e.g. on a retry/fallback path).
    public static func appendUserTurn(
        history: [LLMChatTurn],
        prompt: String
    ) -> [[String: String]] {
        var messages = history.compactMap { turn -> [String: String]? in
            let content = turn.content.trimmingCharacters(in: .whitespacesAndNewlines)
            // A blank turn (an agent round's empty prompt, or a failed send
            // that was stored with no text) makes LM Studio prefill nothing
            // and return an empty completion.
            guard !content.isEmpty else { return nil }
            return ["role": turn.role, "content": content]
        }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        // Agent rounds already include the user turn and pass an empty prompt.
        if trimmed.isEmpty { return messages }
        if messages.last?["role"] == "user", messages.last?["content"] == prompt {
            return messages
        }
        messages.append(["role": "user", "content": prompt])
        return messages
    }

    /// Extracts the text delta from a single Server-Sent-Events `data:` line, or `nil` for `[DONE]`/non-data lines.
    public static func parseSSEDataLine(_ line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard payload != "[DONE]", !payload.isEmpty else { return nil }
        return parseStreamingChunk(String(payload))
    }

    /// Pulls the incremental text out of one streamed JSON chunk, tolerating the several shapes providers emit.
    ///
    /// Handles `choices[].delta` (OpenAI streaming), `choices[].message` (Ollama),
    /// and bare `choices[].text` (legacy completions). Returns `nil` for error
    /// objects or unrecognized shapes so the caller can simply skip the line.
    public static func parseStreamingChunk(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        // An error object mid-stream isn't usable text; skip it.
        if object["error"] as? [String: Any] != nil {
            return nil
        }

        guard let choices = object["choices"] as? [[String: Any]],
              let first = choices.first else {
            return nil
        }

        // Try each known location for the chunk's text.
        if let delta = first["delta"] as? [String: Any] {
            return extractText(from: delta)
        }
        if let message = first["message"] as? [String: Any] {
            return extractText(from: message)
        }
        if let text = first["text"] as? String {
            return text
        }
        return nil
    }

    /// Chain-of-thought delta from one streamed chunk.
    ///
    /// LM Studio 0.3.9+ puts DeepSeek-style thoughts in `reasoning_content`.
    /// LM Studio 0.3.23+ puts gpt-oss thoughts in `reasoning` (the o3-mini shape),
    /// on `delta` while streaming and on `message` when not.
    public static func parseStreamingReasoning(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["error"] == nil,
              let choices = object["choices"] as? [[String: Any]],
              let first = choices.first else {
            return nil
        }
        if let delta = first["delta"] as? [String: Any], let reasoning = extractReasoning(from: delta) {
            return reasoning
        }
        if let message = first["message"] as? [String: Any] {
            return extractReasoning(from: message)
        }
        return nil
    }

    /// Parses a complete (non-streamed) chat response into assistant text, throwing a descriptive error on failure.
    ///
    /// Accepts both top-level `message` (Ollama) and `choices[].message`/`text`
    /// (OpenAI-style) shapes, and surfaces provider error messages directly.
    public static func parseCompletionResponse(_ data: Data) throws -> String {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMServiceError.generationFailed("Remote provider returned invalid JSON.")
        }

        // Surface a provider-reported error before trying to read content.
        if let error = object["error"] as? [String: Any] {
            let message = error["message"] as? String ?? String(describing: error)
            throw LLMServiceError.generationFailed(message)
        }

        // Ollama-style top-level message.
        if let message = object["message"] as? [String: Any],
           let content = extractText(from: message),
           !content.isEmpty {
            return content
        }

        // OpenAI-style choices array.
        guard let choices = object["choices"] as? [[String: Any]],
              let first = choices.first else {
            throw LLMServiceError.generationFailed("Remote provider returned an unexpected response shape.")
        }

        if let message = first["message"] as? [String: Any] {
            if let content = extractText(from: message), !content.isEmpty {
                return content
            }
            // Some reasoning models finish with an empty `content` and the
            // reply (or the only text) in `reasoning` / `reasoning_content`.
            if let reasoning = extractReasoning(from: message), !reasoning.isEmpty {
                return reasoning
            }
        }

        if let text = first["text"] as? String, !text.isEmpty {
            return text
        }

        throw LLMServiceError.generationFailed("Remote provider returned no assistant content.")
    }

    public static func parseModelsResponseDescriptors(_ data: Data) throws -> [RemoteModelDescriptor] {
        try OpenAIRequestCodec.parseModelsList(data)
    }

    /// Parses a `/models` (or Ollama `/tags`) response into a sorted list of model ids.
    ///
    /// Supports OpenAI's `data[].id` shape and Ollama's `models[].name`/`model`
    /// shape; throws if neither yields any ids.
    public static func parseModelsResponse(_ data: Data) throws -> [String] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMServiceError.generationFailed("Remote provider returned invalid models JSON.")
        }

        if let descriptors = try? OpenAIRequestCodec.parseModelsList(data), !descriptors.isEmpty {
            return descriptors.map(\.id)
        }
        // OpenAI-style: { data: [ { id }, ... ] }
        if let models = object["data"] as? [[String: Any]] {
            let ids = models.compactMap { $0["id"] as? String }.filter { !$0.isEmpty }
            if !ids.isEmpty { return ids.sorted() }
        }

        // Ollama-style: { models: [ { name | model }, ... ] }
        if let models = object["models"] as? [[String: Any]] {
            let names = models.compactMap { ($0["name"] as? String) ?? ($0["model"] as? String) }
                .filter { !$0.isEmpty }
            if !names.isEmpty { return names.sorted() }
        }

        throw LLMServiceError.generationFailed("Remote provider returned no models.")
    }

    /// Maps a user-requested model name onto the closest id the provider actually serves.
    ///
    /// Providers like OpenRouter namespace ids (e.g. `openai/gpt-oss-120b`); this
    /// prefers an exact match, then a namespaced suffix match, then a last-path
    /// component match, before finally returning the requested name unchanged.
    public static func resolvedModelID(requested: String, available: [String]) -> String {
        let trimmed = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return requested }

        // Exact match exists — but prefer a namespaced variant if one is also offered.
        if available.contains(trimmed) {
            if let namespaced = available.first(where: { $0.hasSuffix("/\(trimmed)") && $0 != trimmed }) {
                return namespaced
            }
            return trimmed
        }

        // Requested a bare name; find a namespaced id ending in it.
        if let namespaced = available.first(where: { $0.hasSuffix("/\(trimmed)") }) {
            return namespaced
        }

        // Fall back to matching just the last path component.
        if let leaf = available.first(where: { ($0 as NSString).lastPathComponent == trimmed }) {
            return leaf
        }

        return trimmed
    }

    /// Formats an HTTP failure into a concise, user-readable message, preferring the provider's own error text.
    public static func formatHTTPError(statusCode: Int, body: String) -> String {
        // Prefer the structured { error: { message } } if present.
        if let data = body.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = object["error"] as? [String: Any],
           let message = error["message"] as? String {
            return "HTTP \(statusCode): \(message)"
        }
        // Otherwise fall back to the system status description or a truncated body.
        if body.isEmpty {
            return "HTTP \(statusCode): \(HTTPURLResponse.localizedString(forStatusCode: statusCode))"
        }
        return "HTTP \(statusCode): \(body.prefix(400))"
    }

    /// Extracts displayable text from a message object across the variants providers use.
    ///
    /// Handles plain string content, `reasoning_content` (reasoning models), and
    /// the array-of-parts content shape, concatenating any `text` parts.
    private static func extractText(from message: [String: Any]) -> String? {
        if let content = message["content"] as? String, !content.isEmpty {
            return content
        }
        if let parts = message["content"] as? [[String: Any]] {
            let text = parts.compactMap { part -> String? in
                guard part["type"] as? String == "text" else { return nil }
                return part["text"] as? String
            }.joined()
            return text.isEmpty ? nil : text
        }
        return nil
    }

    /// Reasoning-model chain-of-thought.
    ///
    /// `reasoning_content` is the DeepSeek / LM Studio 0.3.9 field.
    /// `reasoning` is the LM Studio 0.3.23 gpt-oss field (same shape as o3-mini).
    public static func extractReasoning(from message: [String: Any]) -> String? {
        if let reasoning = message["reasoning_content"] as? String, !reasoning.isEmpty {
            return reasoning
        }
        if let reasoning = message["reasoning"] as? String, !reasoning.isEmpty {
            return reasoning
        }
        return nil
    }

    /// Whether the model rejects an explicit `temperature` (OpenAI o1/o3, gpt-5, gpt-6).
    private static func restrictsTemperature(_ model: String) -> Bool {
        ModelCapabilityCatalog.capabilities(forModelID: model, backend: .remote).rejectsTemperature
    }

    private static func usesMaxCompletionTokens(_ model: String) -> Bool {
        ModelCapabilityCatalog.capabilities(forModelID: model, backend: .remote).usesMaxCompletionTokens
    }

    /// Whether the model accepts a reasoning effort parameter.
    public static func supportsReasoningEffort(_ model: String) -> Bool {
        ModelCapabilityCatalog.capabilities(forModelID: model, backend: .remote).supportsThinking
    }

    /// Applies user-tuned generation options on top of an adapter-built payload.
    public static func applyGenerationOptions(
        _ options: ModelGenerationOptions,
        to payload: inout [String: Any],
        model: String,
        api: OpenAIConversationAPI = .chatCompletions
    ) {
        OpenAIRequestCodec.applyGenerationOptions(options, to: &payload, model: model, api: api)
    }
}

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
