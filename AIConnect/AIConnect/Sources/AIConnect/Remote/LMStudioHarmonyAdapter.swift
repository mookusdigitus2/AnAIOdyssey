// SPDX-License-Identifier: MIT
import Foundation
import AIModelOptions

/// LM Studio with GPT-OSS / Harmony models: same HTTP as OpenAI but different text framing.
struct LMStudioHarmonyAdapter: RemoteLLMProtocolAdapter {
    let encoding: RemoteProtocolEncoding = .lmStudioHarmony
    private let transport = OpenAIChatCompletionsAdapter()

    func isConfigured(connection: RemoteConnection) -> Bool {
        transport.isConfigured(connection: connection)
    }

    func configurationHint(connection: RemoteConnection) -> String {
        transport.configurationHint(connection: connection)
    }

    func buildChatURL(baseURL: String) -> URL? {
        transport.buildChatURL(baseURL: baseURL)
    }

    func buildModelsURL(baseURL: String) -> URL? {
        transport.buildModelsURL(baseURL: baseURL)
    }

    func requestHeaders(connection: RemoteConnection, streaming: Bool) -> [String: String] {
        transport.requestHeaders(connection: connection, streaming: streaming)
    }

    func chatPayload(model: String, messages: [[String: String]], stream: Bool) -> [String: Any] {
        transport.chatPayload(model: model, messages: messages, stream: stream)
    }

    func parseCompletionResponse(data: Data) throws -> String {
        let raw = try transport.parseCompletionResponse(data: data)
        return sanitizeAssistantText(raw)
    }

    func parseStreamingChunk(json: String) -> String? {
        transport.parseStreamingChunk(json: json)
    }

    func parseModelsResponse(data: Data) throws -> [String] {
        try transport.parseModelsResponse(data: data)
    }

    func sanitizeAssistantText(_ text: String) -> String {
        HarmonyResponseCodec.sanitizeAssistantText(text)
    }

    func parseToolBlocks(from text: String, tags: Set<String>) -> [ToolCallBlock] {
        var blocks = ToolCallParsing.parseToolBlocks(from: text, tags: tags)
        blocks.append(contentsOf: HarmonyResponseCodec.parseHarmonyToolCalls(from: text, tags: tags))
        // When LM Studio cannot parse a call, the Qwen or default format stays in content.
        for call in LMStudioToolProtocol.calls(inContent: text) {
            guard let tag = tags.first(where: { $0.lowercased() == call.name.lowercased() }) else { continue }
            blocks.append(ToolCallBlock(toolType: tag.lowercased(), content: call.argumentsJSON))
        }
        return blocks
    }

    func stripToolBlocks(from text: String, tags: Set<String>) -> String {
        // The Harmony sanitizer drops tool-call messages (they carry a `to=`
        // recipient). Qwen `<tool_call>` and default `[TOOL_REQUEST]` blocks
        // are stripped before that, so a leaked call is not shown as the reply.
        let strippedFenced = ToolCallParsing.stripToolBlocks(from: text, tags: tags)
        return sanitizeAssistantText(LMStudioToolProtocol.prose(from: strippedFenced))
    }

    func streamingDelta(accumulated: String, chunk: String) -> String {
        RemoteAdapterSupport.defaultStreamingDelta(accumulated: accumulated, chunk: chunk)
    }
}

/// Decodes the GPT-OSS **Harmony** response format sometimes leaked verbatim by
/// LM Studio (and other self-hosted runtimes) instead of being parsed server-side.
///
/// Harmony frames every message as
/// `<|start|>{header}<|message|>{body}` terminated by `<|end|>`, `<|call|>`
/// (tool call), or `<|return|>` (end of completion). The header carries the
/// role, a channel (`analysis` = chain of thought, `commentary` = tool calls
/// and preambles, `final` = the user-facing answer), an optional recipient
/// (`to=functions.name`) and an optional content type (`<|constrain|>json`).
///
/// Per the spec only `final`-channel text should be shown to users, tool calls
/// are addressed with `to=` recipients on the `commentary` (or, for built-in
/// tools, `analysis`) channel, and analysis text must not be presented as the
/// answer.
enum HarmonyResponseCodec {
    /// One parsed Harmony message.
    struct HarmonyMessage: Equatable {
        /// `analysis`, `commentary`, or `final` when a channel was declared.
        var channel: String?
        /// `to=` recipient (e.g. `functions.create_note`); tool calls have one.
        var recipient: String?
        /// Raw header text (role, channel, recipient, constrain type).
        var header: String
        /// Message body (prose, chain of thought, or tool-call arguments).
        var body: String

        /// Tool calls are messages addressed to a non-assistant recipient.
        var isToolCall: Bool {
            guard let recipient else { return false }
            return recipient.lowercased() != "assistant"
        }
    }

    private static let controlTokens = [
        "<|start|>", "<|channel|>", "<|constrain|>", "<|message|>",
        "<|end|>", "<|call|>", "<|return|>",
    ]

    static func containsHarmonyTokens(_ text: String) -> Bool {
        controlTokens.contains { text.contains($0) }
    }

    /// Splits raw text into Harmony messages. Tolerates the partial framings
    /// real runtimes emit: completions that begin mid-message (no `<|start|>`),
    /// headers introduced only by `<|channel|>`, and missing terminators.
    static func parseMessages(_ text: String) -> [HarmonyMessage] {
        var messages: [HarmonyMessage] = []
        var header = ""
        var body = ""
        var inHeader = false
        var hasContent = false

        func closeMessage() {
            let trimmedHeader = header.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasBody = !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if hasContent && (hasBody || !trimmedHeader.isEmpty) {
                messages.append(makeMessage(header: trimmedHeader, body: body))
            }
            header = ""
            body = ""
            inHeader = false
            hasContent = false
        }

        var index = text.startIndex
        while index < text.endIndex {
            var next: (range: Range<String.Index>, token: String)?
            for token in controlTokens where token.hasPrefix("<|") {
                if let range = text.range(of: token, range: index..<text.endIndex),
                   next == nil || range.lowerBound < next!.range.lowerBound {
                    next = (range, token)
                }
            }

            guard let (range, token) = next else {
                let rest = String(text[index...])
                if inHeader { header += rest } else { body += rest }
                hasContent = hasContent || !rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                break
            }

            let leading = String(text[index..<range.lowerBound])
            if !leading.isEmpty {
                if inHeader { header += leading } else { body += leading }
                hasContent = hasContent || !leading.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }

            switch token {
            case "<|start|>":
                closeMessage()
                inHeader = true
                hasContent = true
            case "<|channel|>":
                // A channel token outside a header opens a new message (the
                // common LM Studio leak starts completions this way).
                if !inHeader {
                    closeMessage()
                    inHeader = true
                }
                hasContent = true
                header += " "
            case "<|constrain|>":
                if inHeader { header += " " }
            case "<|message|>":
                inHeader = false
                hasContent = true
            case "<|end|>", "<|call|>", "<|return|>":
                closeMessage()
            default:
                break
            }
            index = range.upperBound
        }
        closeMessage()
        return messages
    }

    private static func makeMessage(header: String, body: String) -> HarmonyMessage {
        let lowered = header.lowercased()
        var channel: String?
        for name in ["analysis", "commentary", "final"] {
            // Match whole words so a role or tool name can't false-positive.
            if lowered.range(of: #"\b\#(name)\b"#, options: .regularExpression) != nil {
                channel = name
                break
            }
        }
        var recipient: String?
        if let match = lowered.range(of: #"to=([^\s<{]+)"#, options: .regularExpression) {
            recipient = String(lowered[match]).replacingOccurrences(of: "to=", with: "")
        }
        return HarmonyMessage(channel: channel, recipient: recipient, header: header, body: body)
    }

    /// Extracts the user-visible reply from a raw Harmony transcript.
    ///
    /// Selection order follows the spec, then degrades gracefully for leaky
    /// runtimes so the reply is never empty when the model produced text:
    /// 1. `final`-channel messages (the protocol's user-facing channel)
    /// 2. plain text with no channel framing
    /// 3. `commentary` preambles (no recipient — the spec allows showing these)
    /// 4. `analysis` chain of thought (last resort only)
    /// 5. non-JSON bodies of tool-call messages (a known LM Studio leak where
    ///    the answer lands in a `to=` message)
    static func sanitizeAssistantText(_ text: String) -> String {
        guard containsHarmonyTokens(text) else {
            return text
        }

        let messages = parseMessages(text)
        let nonTool = messages.filter { !$0.isToolCall }

        let candidates: [[String]] = [
            nonTool.filter { $0.channel == "final" }.map(\.body),
            nonTool.filter { $0.channel == nil }.map(\.body),
            nonTool.filter { $0.channel == "commentary" }.map(\.body),
            nonTool.filter { $0.channel == "analysis" }.map(\.body),
            messages.filter { $0.isToolCall }.map(\.body).filter { !looksLikeJSON($0) },
        ]

        for bodies in candidates {
            let joined = bodies
                .map { finalizeVisibleText($0) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
            if !joined.isEmpty {
                return joined
            }
        }
        return ""
    }

    /// Parses Harmony `to=` tool calls into agent tool blocks.
    ///
    /// Handles the spec shape
    /// `<|channel|>commentary to=functions.name <|constrain|>json<|message|>{args}<|call|>`
    /// (arguments in the body), the `functions.` namespace prefix, and the
    /// legacy leak where arguments appear inline in the header.
    static func parseHarmonyToolCalls(from text: String, tags: Set<String>) -> [ToolCallBlock] {
        guard containsHarmonyTokens(text) else { return [] }
        var blocks: [ToolCallBlock] = []
        for message in parseMessages(text) {
            guard let recipient = message.recipient else { continue }
            let name = normalizedToolName(recipient)
            guard let tag = tags.first(where: { $0.lowercased() == name }) else { continue }

            var content = ""
            let body = message.body.trimmingCharacters(in: .whitespacesAndNewlines)
            if let json = leadingJSONObject(in: body) {
                content = json
            } else if let inline = leadingJSONObject(in: inlineArguments(in: message.header)) {
                content = inline
            }
            blocks.append(ToolCallBlock(toolType: tag.lowercased(), content: content))
        }
        return blocks
    }

    // MARK: - Private

    /// Strips the tool namespace (`functions.`, `tools.`) from a recipient.
    private static func normalizedToolName(_ recipient: String) -> String {
        let lowered = recipient.lowercased()
        if let dot = lowered.lastIndex(of: ".") {
            return String(lowered[lowered.index(after: dot)...])
        }
        return lowered
    }

    /// Header text after the `to=` recipient — where leaky runtimes put args.
    private static func inlineArguments(in header: String) -> String {
        guard let range = header.range(of: #"to=[^\s<{]+"#, options: .regularExpression) else {
            return ""
        }
        return String(header[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The first balanced `{…}` object in `text`, or `nil`.
    private static func leadingJSONObject(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var previous: Character = " "
        for index in text.indices[start...] {
            let character = text[index]
            if inString {
                if character == "\"" && previous != "\\" { inString = false }
            } else {
                switch character {
                case "\"": inString = true
                case "{": depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 {
                        return String(text[start...index])
                    }
                default: break
                }
            }
            previous = character
        }
        return nil
    }

    private static func looksLikeJSON(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("{") || trimmed.hasPrefix("[")
    }

    /// Cleans one visible body: residual control tokens or a partial trailing
    /// token, then collapses a whole-text decode repeat. Leading digits and a
    /// repeated paragraph followed by new text are left alone.
    private static func finalizeVisibleText(_ text: String) -> String {
        var result = text
        // Residual safety net for tokens the parser did not consume.
        result = result.replacingOccurrences(
            of: #"<\|[a-z_]+\|>"#,
            with: "",
            options: .regularExpression
        )
        // A control token cut off mid-stream (e.g. "<|chan") must not flash on screen.
        result = result.replacingOccurrences(
            of: #"<\|?[a-z_]*\|?$"#,
            with: "",
            options: .regularExpression
        )
        result = collapseExactRepeats(result.trimmingCharacters(in: .whitespacesAndNewlines))
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Only collapses when the entire body is the same block repeated. A
    /// repeated prefix followed by new text is kept in full.
    ///
    /// `finalizeVisibleText` trims first, so a doubled block that ended in a
    /// space is one character short of even. Restore that space only for the
    /// comparison so `"hello hello "` still collapses after trim.
    private static func collapseExactRepeats(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 24 else { return text }

        for pad in 0...1 {
            let padded = pad == 0 ? trimmed : trimmed + " "
            guard padded.count >= 24, padded.count.isMultiple(of: 2) else { continue }
            let half = padded.index(padded.startIndex, offsetBy: padded.count / 2)
            let first = String(padded[..<half])
            if first == String(padded[half...]) {
                return collapseExactRepeats(first)
            }
        }
        return text
    }
}
