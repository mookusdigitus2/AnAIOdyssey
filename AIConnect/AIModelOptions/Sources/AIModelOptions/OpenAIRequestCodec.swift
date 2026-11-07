// SPDX-License-Identifier: MIT
import Foundation

/// Which OpenAI conversation endpoint a payload is destined for.
public enum OpenAIConversationAPI: String, Sendable {
    case chatCompletions
    case responses
}

/// Parsed native function call from Chat Completions or Responses.
public struct EncodedFunctionCall: Equatable, Sendable, Codable {
    public var name: String
    public var arguments: String
    public var callID: String?

    public init(name: String, arguments: String, callID: String? = nil) {
        self.name = name
        self.arguments = arguments
        self.callID = callID
    }

    /// Responses API item to send back after the application ran this call.
    public func functionCallOutputItem(output: String) -> [String: Any]? {
        guard let callID, !callID.isEmpty else { return nil }
        return EncodedFunctionCallOutput(callID: callID, output: output).item
    }

    /// Responses `function_call` input item. Required ahead of each
    /// `function_call_output` when the request is not chained with
    /// `previous_response_id`.
    public var functionCallItem: [String: Any]? {
        guard let callID, !callID.isEmpty else { return nil }
        return [
            "type": "function_call",
            "call_id": callID,
            "name": name,
            "arguments": ToolCallArgumentsJSON.normalized(arguments),
        ]
    }
}

/// Documented Responses `function_call_output` input item.
public struct EncodedFunctionCallOutput: Equatable, Sendable {
    public var callID: String
    public var output: String

    public init(callID: String, output: String) {
        self.callID = callID
        self.output = output
    }

    public var item: [String: Any] {
        [
            "type": "function_call_output",
            "call_id": callID,
            "output": output,
        ]
    }
}

/// One `/v1/models` row, including the provider `created` timestamp when present.
public struct RemoteModelDescriptor: Equatable, Sendable {
    public var id: String
    public var created: Int?
    /// Tool calling as the provider reports it (OpenRouter `supported_parameters`,
    /// LM Studio `capabilities`). Nil when the provider doesn't say.
    public var supportsTools: Bool?
    /// Loaded instance context, else `max_context_length`.
    public var contextWindowTokens: Int?
    public var supportsVision: Bool?
    public var reasoningEfforts: [ReasoningEffort]
    public var defaultReasoningEffort: ReasoningEffort?

    public init(
        id: String,
        created: Int? = nil,
        supportsTools: Bool? = nil,
        contextWindowTokens: Int? = nil,
        supportsVision: Bool? = nil,
        reasoningEfforts: [ReasoningEffort] = [],
        defaultReasoningEffort: ReasoningEffort? = nil
    ) {
        self.id = id
        self.created = created
        self.supportsTools = supportsTools
        self.contextWindowTokens = contextWindowTokens
        self.supportsVision = supportsVision
        self.reasoningEfforts = reasoningEfforts
        self.defaultReasoningEffort = defaultReasoningEffort
    }
}

/// Parsed Responses SSE `data:` payload.
public struct ResponsesStreamEvent: Equatable, Sendable {
    public var type: String
    public var textDelta: String?
    public var errorMessage: String?
    public var responseID: String?
    public var completedOutputText: String?
    public var isTerminal: Bool
    public var citations: [ChatWebSearchCitation]
    public var isWebSearchActivity: Bool
    public var termination: StreamTermination?
    public var reasoningDelta: String?
    public var usage: TokenUsage?

    public init(
        type: String,
        textDelta: String? = nil,
        errorMessage: String? = nil,
        responseID: String? = nil,
        completedOutputText: String? = nil,
        isTerminal: Bool = false,
        citations: [ChatWebSearchCitation] = [],
        isWebSearchActivity: Bool = false,
        termination: StreamTermination? = nil,
        reasoningDelta: String? = nil,
        usage: TokenUsage? = nil
    ) {
        self.type = type
        self.textDelta = textDelta
        self.errorMessage = errorMessage
        self.responseID = responseID
        self.completedOutputText = completedOutputText
        self.isTerminal = isTerminal
        self.citations = citations
        self.isWebSearchActivity = isWebSearchActivity
        self.termination = termination
        self.reasoningDelta = reasoningDelta
        self.usage = usage
    }
}

/// Pure request/response helpers for Chat Completions and the Responses API.
public enum OpenAIRequestCodec {
    public static func isOfficialOpenAIHost(_ baseURL: String) -> Bool {
        host(of: baseURL) == "api.openai.com"
    }

    /// xAI Grok OpenAI-compatible API (`https://api.x.ai/v1`).
    public static func isXAIHost(_ baseURL: String) -> Bool {
        host(of: baseURL) == "api.x.ai"
    }

    /// Official OpenAI and xAI use Responses for reasoning models and tool calling.
    /// Other OpenAI-compatible hosts stay on Chat Completions.
    /// Hosted `web_search` always forces Responses on those two hosts.
    public static func shouldUseResponsesAPI(
        baseURL: String,
        model: String,
        hasTools: Bool,
        hasHostedWebSearch: Bool = false
    ) -> Bool {
        let official = isOfficialOpenAIHost(baseURL)
        let xai = isXAIHost(baseURL)
        guard official || xai else { return false }
        let caps = ModelCapabilityCatalog.capabilities(forModelID: model, backend: .remote)
        if caps.isLocalMLX { return false }
        if ModelCapabilityCatalog.isImageGenerationModel(model) { return false }
        if hasHostedWebSearch { return true }
        if hasTools { return official || caps.prefersResponsesAPI }
        return caps.prefersResponsesAPI
    }

    /// Hosted Responses search tool (`{"type":"web_search"}`), not a local function.
    public static func containsHostedWebSearch(_ tools: [[String: Any]]) -> Bool {
        tools.contains { tool in
            let type = (tool["type"] as? String) ?? ""
            return (type == "web_search" || type == "web_search_preview")
                && tool["function"] == nil
        }
    }

    public static func responsesPath(normalizedBase: String) -> String {
        normalizedBase + "/responses"
    }

    public static func responsesPayload(
        model: String,
        messages: [[String: String]],
        stream: Bool,
        tools: [[String: Any]] = [],
        previousResponseID: String? = nil,
        functionCalls: [EncodedFunctionCall] = [],
        functionCallOutputs: [EncodedFunctionCallOutput] = []
    ) -> [String: Any] {
        responsesPayload(
            model: model,
            typedMessages: ChatCompletionMessage.from(messages),
            stream: stream,
            tools: tools,
            previousResponseID: previousResponseID,
            functionCalls: functionCalls,
            functionCallOutputs: functionCallOutputs
        )
    }

    /// Builds a Responses body from typed history. When the request is not
    /// chained (`previous_response_id` omitted), every earlier tool round's
    /// `function_call` item is resent immediately before its
    /// `function_call_output`. Chained turns only send the new outputs —
    /// the stored response already has the matching calls.
    public static func responsesPayload(
        model: String,
        typedMessages: [ChatCompletionMessage],
        stream: Bool,
        tools: [[String: Any]] = [],
        previousResponseID: String? = nil,
        functionCalls: [EncodedFunctionCall] = [],
        functionCallOutputs: [EncodedFunctionCallOutput] = []
    ) -> [String: Any] {
        let chaining = !(previousResponseID ?? "").isEmpty
        var instructions: [String] = []
        var input: [[String: Any]] = []
        var sentCalls = Set<String>()
        for message in typedMessages {
            if message.role == "system" {
                if !message.content.isEmpty { instructions.append(message.content) }
                continue
            }
            if message.role == "tool" {
                if let callID = message.toolCallID, !callID.isEmpty {
                    // Unchained, every output needs its call in front of it.
                    if !chaining, !sentCalls.contains(callID),
                       let item = functionCalls.first(where: { $0.callID == callID })?.functionCallItem {
                        input.append(item)
                        sentCalls.insert(callID)
                    }
                    input.append(EncodedFunctionCallOutput(callID: callID, output: message.content).item)
                }
                continue
            }
            let content = message.content
            if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                input.append([
                    "role": message.role == "assistant" ? "assistant" : "user",
                    "content": content,
                ])
            }
            if !chaining {
                for call in message.toolCalls {
                    if let item = call.encoded.functionCallItem {
                        input.append(item)
                        if !call.id.isEmpty { sentCalls.insert(call.id) }
                    }
                }
            }
        }
        appendFunctionCallOutputs(
            functionCalls: functionCalls,
            functionCallOutputs: functionCallOutputs,
            chaining: chaining,
            to: &input
        )

        var payload: [String: Any] = [
            "model": model,
            "input": input,
            "stream": stream,
        ]
        if chaining {
            payload["previous_response_id"] = previousResponseID
        }
        if !instructions.isEmpty {
            payload["instructions"] = instructions.joined(separator: "\n\n")
        }
        if !tools.isEmpty {
            payload["tools"] = responsesTools(fromChatTools: tools)
            payload["tool_choice"] = "auto"
        }
        return payload
    }

    // MARK: ChatGPT plan usage (Sign in with ChatGPT)

    /// Responses fields the ChatGPT plan route rejects (preview limitations).
    public static let chatGPTPlanUnsupportedFields: [String] = [
        "background",
        "conversation",
        "max_output_tokens",
        "max_tool_calls",
        "metadata",
        "moderation",
        "multi_agent",
        "prompt",
        "prompt_cache_retention",
        "safety_identifier",
        "temperature",
        "top_logprobs",
        "top_p",
        "truncation",
        "user",
    ]

    /// Forces `stream:true` + `store:false` and strips everything the plan route
    /// rejects, including `previous_response_id` (history goes in `input`).
    public static func applyChatGPTPlanRequirements(to payload: inout [String: Any]) {
        for key in chatGPTPlanUnsupportedFields {
            payload.removeValue(forKey: key)
        }
        payload.removeValue(forKey: "previous_response_id")
        payload.removeValue(forKey: "include")
        payload.removeValue(forKey: "max_tokens")
        payload.removeValue(forKey: "max_completion_tokens")
        payload.removeValue(forKey: "reasoning_effort")
        payload.removeValue(forKey: "messages")
        payload["stream"] = true
        payload["store"] = false
        if var input = payload["input"] as? [[String: Any]] {
            // Explicit system message items are rejected; they belong in `instructions`.
            input.removeAll { item in (item["role"] as? String) == "system" }
            payload["input"] = input
        }
    }

    /// Full-history Responses body for ChatGPT plan usage. With `store:false`
    /// there is no server-side state, so tool rounds resend the model's
    /// `function_call` items ahead of their outputs.
    public static func chatGPTPlanPayload(
        model: String,
        messages: [[String: String]],
        tools: [[String: Any]] = [],
        functionCalls: [EncodedFunctionCall] = [],
        functionCallOutputs: [EncodedFunctionCallOutput] = []
    ) -> [String: Any] {
        // Empty assistant turns (a tool-only reply) carry nothing on a stateless route.
        let history = messages.filter { message in
            !(message["role"] == "assistant"
                && (message["content"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        var payload = responsesPayload(
            model: model,
            messages: history,
            stream: true,
            tools: tools,
            functionCalls: functionCalls,
            functionCallOutputs: functionCallOutputs
        )
        applyChatGPTPlanRequirements(to: &payload)
        return payload
    }

    /// Full-history Responses body from typed turns (tool IDs included).
    public static func chatGPTPlanPayload(
        model: String,
        typedMessages: [ChatCompletionMessage],
        tools: [[String: Any]] = [],
        functionCalls: [EncodedFunctionCall] = [],
        functionCallOutputs: [EncodedFunctionCallOutput] = []
    ) -> [String: Any] {
        let history = typedMessages.filter { message in
            !(message.role == "assistant"
                && message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && message.toolCalls.isEmpty)
        }
        var payload = responsesPayload(
            model: model,
            typedMessages: history,
            stream: true,
            tools: tools,
            functionCalls: functionCalls,
            functionCallOutputs: functionCallOutputs
        )
        applyChatGPTPlanRequirements(to: &payload)
        return payload
    }

    public static func responsesTools(fromChatTools tools: [[String: Any]]) -> [[String: Any]] {
        tools.map { tool in
            if let function = tool["function"] as? [String: Any] {
                var flattened: [String: Any] = ["type": "function"]
                if let name = function["name"] as? String { flattened["name"] = name }
                if let description = function["description"] as? String {
                    flattened["description"] = description
                }
                if let parameters = function["parameters"] {
                    flattened["parameters"] = parameters
                }
                return flattened
            }
            return tool
        }
    }

    public static func applyGenerationOptions(
        _ options: ModelGenerationOptions,
        to payload: inout [String: Any],
        model: String,
        api: OpenAIConversationAPI,
        live: LiveModelCapabilities? = nil
    ) {
        let caps = ModelCapabilityCatalog.capabilities(forModelID: model, backend: .remote, live: live)
        let effort = ModelCapabilityCatalog.sanitizedReasoningEffort(
            options.reasoningEffort,
            capabilities: caps
        ) ?? live?.defaultReasoningEffort ?? live?.reasoningEfforts.first

        if api == .responses {
            if let effort {
                var reasoning = (payload["reasoning"] as? [String: Any]) ?? [:]
                reasoning["effort"] = effort.rawValue
                if caps.supportsReasoningMode, let mode = options.reasoningMode, !mode.isEmpty {
                    reasoning["mode"] = mode
                }
                if caps.supportsReasoningSummary, effort != .none {
                    reasoning["summary"] = "auto"
                }
                payload["reasoning"] = reasoning
            }
            payload.removeValue(forKey: "reasoning_effort")
            payload.removeValue(forKey: "temperature")
            payload.removeValue(forKey: "top_p")

            if let maxTokens = resolvedMaxOutputTokens(options: options, capabilities: caps) {
                payload["max_output_tokens"] = maxTokens
                payload.removeValue(forKey: "max_tokens")
                payload.removeValue(forKey: "max_completion_tokens")
            }

            if caps.supportsRememberThinking {
                let remember = ModelOptionsFormatting.resolvedRememberThinking(
                    options: options,
                    capabilities: caps
                )
                payload["store"] = remember
                // Encrypted reasoning is needed to carry thoughts across tool
                // rounds when store is off (no previous_response_id).
                payload["include"] = ["reasoning.encrypted_content"]
            }

            if options.contextWindowTokens == nil {
                payload["truncation"] = "auto"
            }
            return
        }

        if let effort {
            payload["reasoning_effort"] = effort.rawValue
            if live != nil, !caps.supportedReasoningEfforts.isEmpty {
                var reasoning = (payload["reasoning"] as? [String: Any]) ?? [:]
                reasoning["effort"] = effort.rawValue
                payload["reasoning"] = reasoning
            }
        } else {
            payload.removeValue(forKey: "reasoning_effort")
        }

        if let maxTokens = options.maxOutputTokens, maxTokens > 0 {
            applyChatMaxTokens(maxTokens, to: &payload, capabilities: caps)
        } else if caps.alwaysSendsReasoningEffort {
            applyChatMaxTokens(caps.maxOutputTokens, to: &payload, capabilities: caps)
        }
    }

    public static func truncateMessages(
        _ messages: [[String: String]],
        contextWindowTokens: Int,
        reservedOutputTokens: Int
    ) -> [[String: String]] {
        truncateMessages(
            ChatCompletionMessage.from(messages),
            contextWindowTokens: contextWindowTokens,
            reservedOutputTokens: reservedOutputTokens
        ).map { ["role": $0.role, "content": $0.content] }
    }

    /// Tokens kept free for the reply when history is trimmed to the window. Windows under 32k
    /// reserve a quarter (at least 1k, never more than half), so a model's large max output
    /// can't take half of a small loaded context. Larger windows keep half. Never more than
    /// `maxOutputTokens`.
    public static func reservedOutputTokens(contextWindowTokens: Int, maxOutputTokens: Int) -> Int {
        let context = max(contextWindowTokens, 1)
        let share = context >= smallContextWindowTokens
            ? context / 2
            : max(context / 4, min(1024, context / 2))
        return max(min(maxOutputTokens, max(share, 1)), 0)
    }

    /// Windows below this size reserve a quarter for output instead of half.
    public static let smallContextWindowTokens = 32_768

    /// Smallest share a tool result is shortened to, even when the window is already full.
    public static let minimumToolResultTokens = 64

    /// Marks where a tool result was shortened to fit the window.
    public static let shortenedToolResultNote = "\n[... tool result shortened to fit the context window ...]\n"

    /// Trims history to `contextWindowTokens - reservedOutputTokens`.
    ///
    /// System messages are always kept. An assistant turn with `tool_calls` and the tool
    /// results that follow it are kept or dropped together, so a result never loses its call.
    /// The current turn (the latest user message and every tool round after it) is always
    /// kept: when it doesn't fit, tool results are shortened (head and tail kept), and if that
    /// still isn't enough the oldest rounds between the prompt and the latest round go.
    /// Earlier turns are then added newest first while they fit.
    public static func truncateMessages(
        _ messages: [ChatCompletionMessage],
        contextWindowTokens: Int,
        reservedOutputTokens: Int
    ) -> [ChatCompletionMessage] {
        let budget = max(contextWindowTokens - max(reservedOutputTokens, 0), 1)
        var system: [ChatCompletionMessage] = []
        var rest: [ChatCompletionMessage] = []
        for message in messages {
            if message.role == "system" {
                system.append(message)
            } else {
                rest.append(message)
            }
        }
        let units = toolRoundUnits(rest)
        guard !units.isEmpty else { return system }

        let systemTokens = estimatedTokens(in: system)
        let anchor = units.lastIndex { $0.first?.role == "user" } ?? units.count - 1
        let current = fitting(Array(units[anchor...]), into: budget - systemTokens)
        var kept = current.flatMap { $0 }
        var used = systemTokens + estimatedTokens(in: kept)
        for unit in units[..<anchor].reversed() {
            let cost = estimatedTokens(in: unit)
            if used + cost > budget {
                break
            }
            kept.insert(contentsOf: unit, at: 0)
            used += cost
        }
        return system + kept
    }

    /// Splits history into units that are kept or dropped whole: an assistant turn with
    /// `tool_calls` plus the tool results right after it, a run of tool results with no call
    /// before them, or any other single message.
    static func toolRoundUnits(_ messages: [ChatCompletionMessage]) -> [[ChatCompletionMessage]] {
        var units: [[ChatCompletionMessage]] = []
        var index = 0
        while index < messages.count {
            let message = messages[index]
            var unit = [message]
            index += 1
            if message.role == "tool" || (message.role == "assistant" && !message.toolCalls.isEmpty) {
                while index < messages.count, messages[index].role == "tool" {
                    unit.append(messages[index])
                    index += 1
                }
            }
            units.append(unit)
        }
        return units
    }

    /// Fits the current turn into `available` tokens without splitting a tool round.
    private static func fitting(_ units: [[ChatCompletionMessage]], into available: Int) -> [[ChatCompletionMessage]] {
        var units = units
        guard estimatedTokens(in: units.flatMap { $0 }) > available else { return units }

        // Share what is left after the other messages between the tool results, smallest first,
        // so a short result keeps all of its text and the long ones split the rest.
        var positions: [(unit: Int, message: Int, cost: Int)] = []
        var fixed = 0
        for (u, unit) in units.enumerated() {
            for (m, message) in unit.enumerated() {
                let cost = estimatedTokens(in: message)
                if message.role == "tool" {
                    positions.append((u, m, cost))
                } else {
                    fixed += cost
                }
            }
        }
        if !positions.isEmpty {
            var remaining = max(available - fixed, 0)
            var pending = positions.sorted { $0.cost < $1.cost }
            while let next = pending.first, next.cost <= remaining / pending.count {
                remaining -= next.cost
                pending.removeFirst()
            }
            let share = max(remaining / max(pending.count, 1), minimumToolResultTokens)
            for position in pending {
                units[position.unit][position.message] = shortenedToolResult(
                    units[position.unit][position.message],
                    toTokens: share
                )
            }
        }

        // Still over: drop the oldest rounds between the prompt and the latest round.
        while estimatedTokens(in: units.flatMap { $0 }) > available, units.count > 2 {
            units.remove(at: 1)
        }
        return units
    }

    /// Characters per token used to size a shortened tool result. Web pages, code and JSON
    /// tokenize denser than prose: LM Studio counted a 14,419-character web_search result as
    /// 4,666 tokens. Sizing at 3 keeps the shortened result inside the real window.
    public static let toolResultCharactersPerToken = 3

    /// A tool result cut to at most `maxTokens` at ``toolResultCharactersPerToken``, keeping
    /// its start and end around ``shortenedToolResultNote``.
    public static func shortenedToolResult(_ message: ChatCompletionMessage, toTokens maxTokens: Int) -> ChatCompletionMessage {
        let limit = max(maxTokens * toolResultCharactersPerToken - (message.toolCallID?.count ?? 0), 0)
        guard message.content.count > limit else { return message }
        var copy = message
        let text = message.content
        let room = limit - shortenedToolResultNote.count
        if room <= 0 {
            copy.content = String(text.prefix(limit))
        } else {
            let head = room * 2 / 3
            copy.content = String(text.prefix(head)) + shortenedToolResultNote + String(text.suffix(room - head))
        }
        return copy
    }

    /// Tokens the `tools` array takes in the prompt, estimated from its JSON. Servers render
    /// every schema into the prompt, so it comes out of the same window as the history.
    public static func estimatedTokens(inTools tools: [[String: Any]]) -> Int {
        guard !tools.isEmpty,
              JSONSerialization.isValidJSONObject(tools),
              let data = try? JSONSerialization.data(withJSONObject: tools) else {
            return 0
        }
        return (data.count + 3) / 4
    }

    static func estimatedTokens(in messages: [ChatCompletionMessage]) -> Int {
        messages.reduce(0) { $0 + estimatedTokens(in: $1) }
    }

    public static func estimatedTokens(in message: [String: String]) -> Int {
        estimatedTokens(in: ChatCompletionMessage(dictionary: message))
    }

    public static func estimatedTokens(in message: ChatCompletionMessage) -> Int {
        var chars = message.content.count
        if let toolCallID = message.toolCallID {
            chars += toolCallID.count
        }
        for call in message.toolCalls {
            chars += call.id.count + call.name.count + call.arguments.count
        }
        return max((chars + 3) / 4, 1)
    }

    public static func parseResponsesCompletion(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if object["choices"] != nil {
            return nil
        }
        let body = (object["response"] as? [String: Any]) ?? object
        if body["output_text"] == nil, body["output"] == nil, object["output_text"] == nil, object["output"] == nil {
            return nil
        }
        if responsesErrorMessage(in: object) != nil {
            return nil
        }
        if let text = body["output_text"] as? String, !text.isEmpty {
            return text
        }
        if let text = object["output_text"] as? String, !text.isEmpty {
            return text
        }
        guard let output = (body["output"] as? [[String: Any]]) ?? (object["output"] as? [[String: Any]]) else {
            return nil
        }
        var parts: [String] = []
        for item in output {
            let type = item["type"] as? String
            if type == "message" {
                if let content = item["content"] as? [[String: Any]] {
                    for block in content {
                        let blockType = block["type"] as? String
                        if blockType == "output_text" || blockType == "text",
                           let text = block["text"] as? String,
                           !text.isEmpty {
                            parts.append(text)
                        }
                    }
                }
            }
        }
        let joined = parts.joined()
        return joined.isEmpty ? nil : joined
    }

    public static func responsesCompletionError(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return responsesErrorMessage(in: object)
    }

    public static func parseResponsesStreamEvent(_ json: String) -> ResponsesStreamEvent? {
        guard let object = jsonObject(json) else { return nil }
        let type = object["type"] as? String ?? ""
        if type.isEmpty, object["choices"] != nil {
            return nil
        }
        if let error = responsesErrorMessage(in: object) {
            return ResponsesStreamEvent(type: type.isEmpty ? "error" : type, errorMessage: error, isTerminal: true)
        }
        let citations = ChatWebSearchPolicy.parseCitations(from: "", responseJSON: object)
        let isWebSearch = ChatWebSearchPolicy.isWebSearchStreamEvent(type)
        switch type {
        case "response.output_text.delta":
            let delta = object["delta"] as? String
            return ResponsesStreamEvent(type: type, textDelta: delta)
        case "response.reasoning_summary_text.delta", "response.reasoning_summary.delta":
            if let delta = object["delta"] as? String, !delta.isEmpty {
                return ResponsesStreamEvent(type: type, reasoningDelta: delta)
            }
            if let delta = object["delta"] as? [String: Any], let text = delta["text"] as? String, !text.isEmpty {
                return ResponsesStreamEvent(type: type, reasoningDelta: text)
            }
        case "response.reasoning_summary_text.done", "response.reasoning_summary.done":
            if let text = object["text"] as? String, !text.isEmpty {
                return ResponsesStreamEvent(type: type, reasoningDelta: text)
            }
        case "response.content_part.delta":
            if let delta = object["delta"] as? [String: Any],
               let text = delta["text"] as? String {
                return ResponsesStreamEvent(type: type, textDelta: text)
            }
            if let text = object["delta"] as? String {
                return ResponsesStreamEvent(type: type, textDelta: text)
            }
        case "response.output_text.done":
            if let text = object["text"] as? String, !text.isEmpty {
                return ResponsesStreamEvent(type: type, completedOutputText: text)
            }
        case "response.content_part.done":
            if let part = object["part"] as? [String: Any],
               let text = part["text"] as? String, !text.isEmpty {
                return ResponsesStreamEvent(type: type, completedOutputText: text)
            }
        case "response.output_item.done":
            if let text = outputText(fromOutput: [object["item"] as? [String: Any] ?? [:]]) {
                return ResponsesStreamEvent(
                    type: type,
                    completedOutputText: text,
                    citations: citations,
                    isWebSearchActivity: isWebSearch
                )
            }
        case "response.completed":
            let response = object["response"] as? [String: Any]
            let id = response?["id"] as? String ?? object["id"] as? String
            let text = (response?["output_text"] as? String)
                ?? object["output_text"] as? String
                ?? outputText(fromOutput: response?["output"] as? [[String: Any]])
            return ResponsesStreamEvent(
                type: type,
                responseID: id,
                completedOutputText: text,
                isTerminal: true,
                citations: citations,
                usage: TokenUsage.parse(from: object)
            )
        case "response.failed", "error":
            let message = responsesErrorMessage(in: object) ?? "The Responses API request failed."
            return ResponsesStreamEvent(
                type: type,
                errorMessage: message,
                isTerminal: true,
                termination: .error(message)
            )
        case "response.incomplete":
            let termination = StreamTextCodecTermination.termination(in: json)
                ?? .incomplete("unknown")
            return ResponsesStreamEvent(
                type: type,
                errorMessage: termination.userMessage,
                isTerminal: true,
                termination: termination
            )
        default:
            if let response = object["response"] as? [String: Any],
               let id = response["id"] as? String {
                return ResponsesStreamEvent(
                    type: type,
                    responseID: id,
                    citations: citations,
                    isWebSearchActivity: isWebSearch
                )
            }
        }
        return ResponsesStreamEvent(type: type, citations: citations, isWebSearchActivity: isWebSearch)
    }

    public static func parseResponsesStreamingDelta(_ json: String) -> String? {
        parseResponsesStreamEvent(json)?.textDelta
    }

    public static func parseModelsList(_ data: Data) throws -> [RemoteModelDescriptor] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ModelsListError.invalidJSON
        }
        if let models = object["data"] as? [[String: Any]] {
            let descriptors = models.compactMap { row -> RemoteModelDescriptor? in
                guard let id = row["id"] as? String, !id.isEmpty else { return nil }
                let created = row["created"] as? Int
                return descriptor(id: id, created: created, row: row)
            }
            if !descriptors.isEmpty { return descriptors }
        }
        if let models = object["models"] as? [[String: Any]] {
            let descriptors = models.compactMap { row -> RemoteModelDescriptor? in
                if let visibility = row["visibility"] as? String, visibility != "list" {
                    return nil
                }
                let id = (row["slug"] as? String)
                    ?? (row["id"] as? String)
                    ?? (row["key"] as? String)
                    ?? (row["name"] as? String)
                    ?? (row["model"] as? String)
                guard let id, !id.isEmpty else { return nil }
                return descriptor(id: id, created: row["created"] as? Int, row: row)
            }
            if !descriptors.isEmpty { return descriptors }
        }
        throw ModelsListError.empty
    }

    /// Reads a provider's own tool-calling flag from one `/models` row, if it has one.
    ///
    /// OpenRouter's `supported_parameters` is a full list, so a missing "tools" is a refusal.
    /// LM Studio is different: `llm` / `vlm` rows can call tools even when
    /// `trained_for_tool_use` is false (that flag is native vs the default prompt).
    /// Only embedding and decision rows cannot. A capability list that merely omits
    /// `tool_use`, with no model type, is not evidence.
    public static func toolSupport(in row: [String: Any]) -> Bool? {
        let names: Set<String> = ["tools", "tool_use", "tool_calling", "function_calling"]
        if let parameters = row["supported_parameters"] as? [String] {
            return parameters.contains { names.contains($0) }
        }
        if let lmStudio = LMStudioToolProtocol.supportsTools(in: row) { return lmStudio }
        if let capabilities = row["capabilities"] as? [String] {
            return capabilities.contains { names.contains($0) } ? true : nil
        }
        if let capabilities = row["capabilities"] as? [String: Any] {
            for name in names {
                if let flag = capabilities[name] as? Bool { return flag }
            }
        }
        return nil
    }

    public enum ModelsListError: Error {
        case invalidJSON
        case empty
    }

    public static func functionCallsFromResponsesCompletion(_ data: Data) -> [EncodedFunctionCall] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        let body = (object["response"] as? [String: Any]) ?? object
        guard let output = (body["output"] as? [[String: Any]]) ?? (object["output"] as? [[String: Any]]) else {
            return []
        }
        return output.compactMap { item in
            guard item["type"] as? String == "function_call",
                  let name = item["name"] as? String else {
                return nil
            }
            let arguments = item["arguments"] as? String ?? ""
            let callID = item["call_id"] as? String
            return EncodedFunctionCall(name: name, arguments: arguments, callID: callID)
        }
    }

    /// Accumulates streamed Responses function-call items.
    public struct ResponsesToolCallAccumulator: Sendable {
        private var entries: [Int: EncodedFunctionCall] = [:]

        public init() {}

        public mutating func append(json: String) {
            guard let object = OpenAIRequestCodec.jsonObject(json) else { return }
            let type = object["type"] as? String
            if type == "response.output_item.added" || type == "response.output_item.done" {
                guard let item = object["item"] as? [String: Any],
                      item["type"] as? String == "function_call" else {
                    return
                }
                let index = object["output_index"] as? Int ?? entries.count
                var entry = entries[index] ?? EncodedFunctionCall(name: "", arguments: "")
                if let name = item["name"] as? String, !name.isEmpty {
                    entry.name = name
                }
                if let arguments = item["arguments"] as? String {
                    entry.arguments = arguments
                }
                if let callID = item["call_id"] as? String {
                    entry.callID = callID
                }
                entries[index] = entry
            } else if type == "response.function_call_arguments.delta" {
                let index = object["output_index"] as? Int ?? 0
                var entry = entries[index] ?? EncodedFunctionCall(name: "", arguments: "")
                if let delta = object["delta"] as? String {
                    entry.arguments += delta
                }
                entries[index] = entry
            }
        }

        public func finish() -> [EncodedFunctionCall] {
            entries.keys.sorted().compactMap { index in
                let entry = entries[index]
                guard let entry, !entry.name.isEmpty else { return nil }
                return entry
            }
        }
    }

    // MARK: - Private

    /// Appends this-round outputs. When not chaining, each output is preceded
    /// by its `function_call` unless that call is already in `input`.
    private static func descriptor(id: String, created: Int?, row: [String: Any]) -> RemoteModelDescriptor {
        RemoteModelDescriptor(
            id: id,
            created: created,
            supportsTools: toolSupport(in: row),
            contextWindowTokens: LMStudioModelRecord.contextLength(in: row),
            supportsVision: LMStudioModelRecord.supportsVision(in: row),
            reasoningEfforts: LMStudioModelRecord.reasoningEfforts(in: row),
            defaultReasoningEffort: LMStudioModelRecord.defaultReasoningEffort(in: row)
        )
    }

    private static func appendFunctionCallOutputs(
        functionCalls: [EncodedFunctionCall],
        functionCallOutputs: [EncodedFunctionCallOutput],
        chaining: Bool,
        to input: inout [[String: Any]]
    ) {
        guard !functionCallOutputs.isEmpty else { return }
        let existingOutputs = Set(input.compactMap { item -> String? in
            guard item["type"] as? String == "function_call_output" else { return nil }
            return item["call_id"] as? String
        })
        let existingCalls = Set(input.compactMap { item -> String? in
            guard item["type"] as? String == "function_call" else { return nil }
            return item["call_id"] as? String
        })
        for output in functionCallOutputs where !existingOutputs.contains(output.callID) {
            if !chaining, !existingCalls.contains(output.callID) {
                if let item = functionCalls.first(where: { $0.callID == output.callID })?.functionCallItem {
                    input.append(item)
                }
            }
            input.append(output.item)
        }
    }

    private static func host(of baseURL: String) -> String? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        return URL(string: withScheme)?.host?.lowercased()
    }

    private static func responsesErrorMessage(in object: [String: Any]) -> String? {
        if let error = object["error"] as? [String: Any] {
            let message = error["message"] as? String ?? String(describing: error)
            return message.isEmpty ? "The Responses API request failed." : message
        }
        if let error = object["error"] as? String, !error.isEmpty {
            return error
        }
        if let response = object["response"] as? [String: Any] {
            if let nested = responsesErrorMessage(in: response) {
                return nested
            }
        }
        return nil
    }

    private static func outputText(fromOutput output: [[String: Any]]?) -> String? {
        guard let output else { return nil }
        var parts: [String] = []
        for item in output {
            guard item["type"] as? String == "message",
                  let content = item["content"] as? [[String: Any]] else {
                continue
            }
            for block in content {
                let blockType = block["type"] as? String
                if blockType == "output_text" || blockType == "text",
                   let text = block["text"] as? String,
                   !text.isEmpty {
                    parts.append(text)
                }
            }
        }
        let joined = parts.joined()
        return joined.isEmpty ? nil : joined
    }

    private static func resolvedMaxOutputTokens(
        options: ModelGenerationOptions,
        capabilities: ModelCapabilities
    ) -> Int? {
        if let maxTokens = options.maxOutputTokens, maxTokens > 0 {
            return min(maxTokens, capabilities.maxOutputTokens)
        }
        if capabilities.alwaysSendsReasoningEffort || capabilities.prefersResponsesAPI {
            return capabilities.maxOutputTokens
        }
        return nil
    }

    private static func applyChatMaxTokens(
        _ maxTokens: Int,
        to payload: inout [String: Any],
        capabilities: ModelCapabilities
    ) {
        if payload["max_completion_tokens"] != nil || capabilities.usesMaxCompletionTokens {
            payload.removeValue(forKey: "max_tokens")
            payload["max_completion_tokens"] = maxTokens
        } else {
            payload["max_tokens"] = maxTokens
        }
    }

    fileprivate static func jsonObject(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }
}
