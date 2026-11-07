// SPDX-License-Identifier: MIT
import Foundation

/// How a provider stream event should update the assembled assistant text.
public enum StreamTextKind: String, Sendable, Equatable {
    /// Incremental slice — append. A cumulative payload that already starts
    /// with the assembled text is treated as a snapshot instead.
    case delta
    /// Full text so far — replace.
    case snapshot
    /// End of a part or response. Apply the text if we have nothing, or if it
    /// extends the assembled text. Never append a duplicate of what we have.
    case done
}

public struct StreamTextUpdate: Equatable, Sendable {
    public var kind: StreamTextKind
    public var text: String

    public init(kind: StreamTextKind, text: String) {
        self.kind = kind
        self.text = text
    }

    public static func delta(_ text: String) -> StreamTextUpdate {
        StreamTextUpdate(kind: .delta, text: text)
    }

    public static func snapshot(_ text: String) -> StreamTextUpdate {
        StreamTextUpdate(kind: .snapshot, text: text)
    }

    public static func done(_ text: String) -> StreamTextUpdate {
        StreamTextUpdate(kind: .done, text: text)
    }
}

/// Assembles assistant text from mixed delta / snapshot / done events.
///
/// Deltas append (unless the payload is actually a growing snapshot).
/// Snapshots replace. Done events fill gaps without duplicating.
public struct StreamTextAccumulator: Equatable, Sendable {
    public private(set) var text: String

    public init(text: String = "") {
        self.text = text
    }

    /// Applies `update` and returns the incremental slice a UI should append.
    /// Empty when the event added no new characters (duplicate snapshot/done).
    @discardableResult
    public mutating func apply(_ update: StreamTextUpdate) -> String {
        let incoming = update.text
        switch update.kind {
        case .delta:
            return applyDelta(incoming)
        case .snapshot:
            return applySnapshot(incoming)
        case .done:
            return applyDone(incoming)
        }
    }

    public mutating func apply(json: String) -> String {
        guard let update = StreamTextCodec.classify(json) else { return "" }
        return apply(update)
    }

    /// Fold a growing snapshot only after the assembled text is already a
    /// phrase. Short prefixes (`to` / `today`) and repeats (`the` / `the`)
    /// must append — they are real LM Studio / OpenAI-compatible deltas.
    public static let growingSnapshotMinAssembledCount = 16

    private mutating func applyDelta(_ incoming: String) -> String {
        if incoming.isEmpty { return "" }
        if text.count >= Self.growingSnapshotMinAssembledCount,
           incoming.count > text.count,
           incoming.hasPrefix(text) {
            let increment = String(incoming.dropFirst(text.count))
            text = incoming
            return increment
        }
        text += incoming
        return incoming
    }

    private mutating func applySnapshot(_ incoming: String) -> String {
        if incoming == text { return "" }
        if incoming.isEmpty { return "" }
        if incoming.hasPrefix(text) {
            let increment = String(incoming.dropFirst(text.count))
            text = incoming
            return increment
        }
        if text.hasPrefix(incoming) {
            return ""
        }
        text = incoming
        return incoming
    }

    private mutating func applyDone(_ incoming: String) -> String {
        let trimmed = incoming
        if trimmed.isEmpty { return "" }
        if trimmed == text { return "" }
        if text.hasPrefix(trimmed) { return "" }
        if trimmed.hasPrefix(text) {
            let increment = String(trimmed.dropFirst(text.count))
            text = trimmed
            return increment
        }
        if text.isEmpty {
            text = trimmed
            return trimmed
        }
        return ""
    }
}

/// Classifies one provider JSON payload (Responses, Chat Completions, Anthropic).
public enum StreamTextCodec {
    public static func classify(_ json: String) -> StreamTextUpdate? {
        let payload = ssePayload(json) ?? stripSSEPrefix(json)
        guard !payload.isEmpty, payload != "[DONE]" else { return nil }
        guard let object = jsonObject(payload) else { return nil }
        if let update = classifyResponses(object) { return update }
        if let update = classifyChatCompletions(object) { return update }
        if let update = classifyAnthropic(object) { return update }
        return nil
    }

    /// LM Studio / OpenAI `delta.reasoning_content` or `delta.reasoning`.
    public static func classifyReasoning(_ json: String) -> String? {
        let payload = ssePayload(json) ?? stripSSEPrefix(json)
        guard !payload.isEmpty, payload != "[DONE]" else { return nil }
        guard let object = jsonObject(payload) else { return nil }
        let choices = object["choices"] as? [[String: Any]]
        let first = choices?.first
        if let delta = first?["delta"] as? [String: Any],
           let text = extractReasoning(from: delta), !text.isEmpty {
            return text
        }
        if let message = first?["message"] as? [String: Any],
           let text = extractReasoning(from: message), !text.isEmpty {
            return text
        }
        let type = object["type"] as? String ?? ""
        if type == "response.reasoning_summary_text.delta" || type == "response.reasoning_summary.delta" {
            if let text = object["delta"] as? String, !text.isEmpty { return text }
            if let delta = object["delta"] as? [String: Any], let text = delta["text"] as? String, !text.isEmpty {
                return text
            }
        }
        return nil
    }

    /// One SSE line → JSON payload, or `nil` for comments, `[DONE]`, and blanks.
    /// Accepts `data:` with or without a space and `\r\n` endings.
    public static func ssePayload(_ line: String) -> String? {
        var trimmed = line
        if trimmed.hasSuffix("\r") {
            trimmed.removeLast()
        }
        trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.hasPrefix(":") {
            return nil
        }
        if trimmed.hasPrefix("data:") {
            trimmed = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        }
        if trimmed.isEmpty || trimmed == "[DONE]" {
            return nil
        }
        return trimmed
    }

    public static func isSSEDone(_ line: String) -> Bool {
        var trimmed = line
        if trimmed.hasSuffix("\r") {
            trimmed.removeLast()
        }
        trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("data:") {
            trimmed = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        }
        return trimmed == "[DONE]"
    }

    /// Incremental `delta.tool_calls[]` fragments (`name` / `arguments`).
    public static func toolCallFragments(_ json: String) -> [(index: Int, name: String?, arguments: String)] {
        let payload = ssePayload(json) ?? stripSSEPrefix(json)
        guard let object = jsonObject(payload),
              let choices = object["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any],
              let toolCalls = delta["tool_calls"] as? [[String: Any]] else {
            return []
        }
        return toolCalls.map { call in
            let index = call["index"] as? Int ?? 0
            let function = call["function"] as? [String: Any]
            return (
                index: index,
                name: function?["name"] as? String,
                arguments: (function?["arguments"] as? String) ?? ""
            )
        }
    }

    public static func apply(jsonLines: [String]) -> String {
        var accumulator = StreamTextAccumulator()
        for line in jsonLines {
            _ = accumulator.apply(json: line)
        }
        return accumulator.text
    }

    public static func update(fromResponses event: ResponsesStreamEvent) -> StreamTextUpdate? {
        if let delta = event.textDelta, !delta.isEmpty {
            return .delta(delta)
        }
        if let completed = event.completedOutputText, !completed.isEmpty {
            return event.isTerminal ? .done(completed) : .done(completed)
        }
        return nil
    }

    public static func stripSSEPrefix(_ line: String) -> String {
        ssePayload(line) ?? line.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Responses

    private static func classifyResponses(_ object: [String: Any]) -> StreamTextUpdate? {
        let type = object["type"] as? String ?? ""
        guard type.hasPrefix("response.") || type == "error" else { return nil }
        switch type {
        case "response.output_text.delta":
            if let text = object["delta"] as? String, !text.isEmpty {
                return .delta(text)
            }
        case "response.content_part.delta":
            if let delta = object["delta"] as? [String: Any],
               let text = delta["text"] as? String, !text.isEmpty {
                return .delta(text)
            }
            if let text = object["delta"] as? String, !text.isEmpty {
                return .delta(text)
            }
        case "response.output_text.done":
            if let text = object["text"] as? String, !text.isEmpty {
                return .done(text)
            }
        case "response.content_part.done":
            if let part = object["part"] as? [String: Any],
               let text = part["text"] as? String, !text.isEmpty {
                return .done(text)
            }
            if let text = object["text"] as? String, !text.isEmpty {
                return .done(text)
            }
        case "response.output_item.done", "response.output_item.added":
            if type == "response.output_item.added" { return nil }
            if let text = messageText(fromItem: object["item"] as? [String: Any]), !text.isEmpty {
                return .done(text)
            }
        case "response.completed":
            let response = object["response"] as? [String: Any]
            if let text = (response?["output_text"] as? String) ?? (object["output_text"] as? String),
               !text.isEmpty {
                return .done(text)
            }
            if let text = messageText(fromOutput: response?["output"] as? [[String: Any]]),
               !text.isEmpty {
                return .done(text)
            }
        default:
            break
        }
        return nil
    }

    // MARK: - Chat Completions / Ollama / xAI chat

    private static func classifyChatCompletions(_ object: [String: Any]) -> StreamTextUpdate? {
        guard let choices = object["choices"] as? [[String: Any]],
              let first = choices.first else {
            return nil
        }
        if let delta = first["delta"] as? [String: Any],
           let text = extractChatText(from: delta), !text.isEmpty {
            return .delta(text)
        }
        if let message = first["message"] as? [String: Any],
           let text = extractChatText(from: message), !text.isEmpty {
            return .snapshot(text)
        }
        if let text = first["text"] as? String, !text.isEmpty {
            return .delta(text)
        }
        return nil
    }

    // MARK: - Anthropic

    private static func classifyAnthropic(_ object: [String: Any]) -> StreamTextUpdate? {
        switch object["type"] as? String {
        case "content_block_delta":
            if let delta = object["delta"] as? [String: Any],
               delta["type"] as? String == "text_delta",
               let text = delta["text"] as? String, !text.isEmpty {
                return .delta(text)
            }
        case "message_delta":
            if let delta = object["delta"] as? [String: Any],
               let text = delta["text"] as? String, !text.isEmpty {
                return .delta(text)
            }
        case "content_block_stop", "message_stop":
            if let text = object["text"] as? String, !text.isEmpty {
                return .done(text)
            }
        default:
            break
        }
        return nil
    }

    // MARK: - Helpers

    private static func extractChatText(from container: [String: Any]) -> String? {
        if let content = container["content"] as? String, !content.isEmpty {
            return content
        }
        if let parts = container["content"] as? [[String: Any]] {
            let joined = parts.compactMap { $0["text"] as? String }.joined()
            return joined.isEmpty ? nil : joined
        }
        if let text = container["text"] as? String, !text.isEmpty {
            return text
        }
        return nil
    }

    private static func extractReasoning(from container: [String: Any]) -> String? {
        if let text = container["reasoning_content"] as? String, !text.isEmpty {
            return text
        }
        if let text = container["reasoning"] as? String, !text.isEmpty {
            return text
        }
        return nil
    }

    private static func messageText(fromItem item: [String: Any]?) -> String? {
        guard let item, item["type"] as? String == "message" else { return nil }
        return messageText(fromOutput: [item])
    }

    private static func messageText(fromOutput output: [[String: Any]]?) -> String? {
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
                   let text = block["text"] as? String, !text.isEmpty {
                    parts.append(text)
                }
            }
        }
        let joined = parts.joined()
        return joined.isEmpty ? nil : joined
    }

    private static func jsonObject(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
