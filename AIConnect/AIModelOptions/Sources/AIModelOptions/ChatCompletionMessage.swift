// SPDX-License-Identifier: MIT
import Foundation

/// One Chat Completions message. Unlike `[String: String]`, this can hold a
/// `tool_calls` array and a `tool_call_id` so multi-step native tool use
/// round-trips on `/v1/chat/completions`.
public struct ChatCompletionMessage: Equatable, Sendable, Codable {
    public var role: String
    public var content: String
    public var toolCalls: [ChatCompletionToolCall]
    public var toolCallID: String?

    public init(
        role: String,
        content: String,
        toolCalls: [ChatCompletionToolCall] = [],
        toolCallID: String? = nil
    ) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
    }

    public init(dictionary: [String: String]) {
        self.init(
            role: dictionary["role"] ?? "user",
            content: dictionary["content"] ?? "",
            toolCallID: dictionary["tool_call_id"] ?? dictionary["call_id"]
        )
    }

    /// JSON object for a Chat Completions `messages[]` item.
    public var jsonObject: [String: Any] {
        var object: [String: Any] = [
            "role": role,
            "content": content,
        ]
        if !toolCalls.isEmpty {
            object["tool_calls"] = toolCalls.map(\.jsonObject)
        }
        if let toolCallID, !toolCallID.isEmpty {
            object["tool_call_id"] = toolCallID
        }
        return object
    }

    public static func from(_ messages: [[String: String]]) -> [ChatCompletionMessage] {
        messages.map(ChatCompletionMessage.init(dictionary:))
    }
}

/// One `tool_calls[]` item (`id` + `function.name` / `function.arguments`).
public struct ChatCompletionToolCall: Equatable, Sendable, Codable {
    public var id: String
    public var name: String
    public var arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }

    public init(_ call: EncodedFunctionCall) {
        self.init(id: call.callID ?? "", name: call.name, arguments: call.arguments)
    }

    public var jsonObject: [String: Any] {
        [
            "id": id,
            "type": "function",
            "function": [
                "name": name,
                "arguments": ToolCallArgumentsJSON.normalized(arguments),
            ],
        ]
    }

    public var encoded: EncodedFunctionCall {
        EncodedFunctionCall(name: name, arguments: arguments, callID: id.isEmpty ? nil : id)
    }
}

/// Builds the Chat Completions messages for a tool round-trip: the assistant
/// turn carries `tool_calls`, and each result is `{role:"tool", tool_call_id}`.
/// The assistant turn always comes before its results, never after them: a list that
/// ends in assistant(tool_calls) is a prefill to llama.cpp and LM Studio, which refuse it.
public enum ChatCompletionToolRoundTrip {
    /// Places `functionCalls` on an assistant turn right before their results and adds one
    /// `role: tool` message per output that is not already present, right after that turn.
    ///
    /// - An assistant turn that already carries these call ids is left as it is.
    /// - Otherwise the calls go immediately before the first matching result, on the round's
    ///   own text turn when that is the message just before it, or on a new assistant turn.
    /// - With no matching result yet, they go on a trailing text-only assistant turn or a new
    ///   assistant turn at the end, followed by the outputs.
    public static func applying(
        to messages: [ChatCompletionMessage],
        functionCalls: [EncodedFunctionCall],
        functionCallOutputs: [EncodedFunctionCallOutput]
    ) -> [ChatCompletionMessage] {
        var result = messages
        var callTurn: Int?
        if !functionCalls.isEmpty {
            let calls = functionCalls.map(ChatCompletionToolCall.init)
            let ids = Set(calls.map(\.id).filter { !$0.isEmpty })
            if !ids.isEmpty, let existing = result.firstIndex(where: { message in
                message.role == "assistant" && ids.isSubset(of: Set(message.toolCalls.map(\.id)))
            }) {
                callTurn = existing
            } else if let firstResult = result.firstIndex(where: { message in
                message.role == "tool" && ids.contains(message.toolCallID ?? "")
            }) {
                let previous = firstResult - 1
                if previous >= 0, result[previous].role == "assistant", result[previous].toolCalls.isEmpty {
                    result[previous].toolCalls = calls
                    callTurn = previous
                } else {
                    result.insert(ChatCompletionMessage(role: "assistant", content: "", toolCalls: calls), at: firstResult)
                    callTurn = firstResult
                }
            } else if let last = result.indices.last, result[last].role == "assistant", result[last].toolCalls.isEmpty {
                result[last].toolCalls = calls
                callTurn = last
            } else {
                result.append(ChatCompletionMessage(role: "assistant", content: "", toolCalls: calls))
                callTurn = result.count - 1
            }
        }
        let existing = Set(result.compactMap(\.toolCallID))
        let missing = functionCallOutputs
            .filter { !existing.contains($0.callID) }
            .map { ChatCompletionMessage(role: "tool", content: $0.output, toolCallID: $0.callID) }
        guard !missing.isEmpty else { return result }
        if let callTurn {
            var index = callTurn + 1
            while index < result.count, result[index].role == "tool" {
                index += 1
            }
            result.insert(contentsOf: missing, at: index)
        } else {
            result.append(contentsOf: missing)
        }
        return result
    }
}

/// `function.arguments` as servers read it back from history: a JSON object in a string.
/// LM Studio and llama-server parse it (llama.cpp `func_args_not_string`) and answer HTTP 500 to
/// anything else, so an empty value becomes `{}` and plain text becomes `{"input": text}`.
public enum ToolCallArgumentsJSON {
    public static func normalized(_ arguments: String) -> String {
        let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "{}" }
        if (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) is [String: Any] { return trimmed }
        guard let data = try? JSONSerialization.data(withJSONObject: ["input": trimmed], options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
