// SPDX-License-Identifier: MIT
import Foundation

/// Last check on a request's tool rounds before it is sent.
///
/// llama.cpp (and LM Studio, which relays its errors) treats a message list that ends in an
/// assistant turn as a prefill to continue, and refuses one that carries tool calls:
/// "Cannot continue an assistant message that contains tool calls." OpenAI rejects a call
/// with no result too. The Responses API has the same rule for a trailing `function_call`.
public enum ToolRoundRequestGuard {
    // MARK: Chat Completions

    /// Moves any assistant(tool_calls) turn that comes after one of its results to just before
    /// the first of them, then drops tool calls that are left at the end with no result
    /// (the whole turn when it has no text). A valid list comes back unchanged.
    public static func repaired(_ messages: [ChatCompletionMessage]) -> [ChatCompletionMessage] {
        var result = messages
        var index = 0
        while index < result.count {
            let message = result[index]
            if message.role == "assistant", !message.toolCalls.isEmpty {
                let ids = Set(message.toolCalls.map(\.id).filter { !$0.isEmpty })
                if let earliest = result[..<index].firstIndex(where: { $0.role == "tool" && ids.contains($0.toolCallID ?? "") }) {
                    result.remove(at: index)
                    result.insert(message, at: earliest)
                }
            }
            index += 1
        }
        while let last = result.last, last.role == "assistant", !last.toolCalls.isEmpty {
            if last.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.removeLast()
            } else {
                result[result.count - 1].toolCalls = []
            }
        }
        return result
    }

    /// Why the list can't be sent as it is, or nil when it can.
    public static func problem(in messages: [ChatCompletionMessage]) -> String? {
        guard let last = messages.last, last.role == "assistant", !last.toolCalls.isEmpty else { return nil }
        return trailingCallMessage(names: last.toolCalls.map(\.name))
    }

    // MARK: Responses

    /// Moves any `function_call` that comes after its `function_call_output` to just before it,
    /// then drops `function_call` items left at the end with no output.
    public static func repairedResponsesInput(_ input: [[String: Any]]) -> [[String: Any]] {
        var result = input
        var index = 0
        while index < result.count {
            let item = result[index]
            if itemType(item) == "function_call", let callID = item["call_id"] as? String, !callID.isEmpty,
               let earliest = result[..<index].firstIndex(where: {
                   itemType($0) == "function_call_output" && ($0["call_id"] as? String) == callID
               }) {
                result.remove(at: index)
                result.insert(item, at: earliest)
            }
            index += 1
        }
        while let last = result.last, itemType(last) == "function_call" {
            result.removeLast()
        }
        return result
    }

    /// Why the Responses `input` can't be sent as it is, or nil when it can.
    public static func problem(inResponsesInput input: [[String: Any]]) -> String? {
        guard let last = input.last, itemType(last) == "function_call" else { return nil }
        return trailingCallMessage(names: [(last["name"] as? String) ?? ""])
    }

    // MARK: Private

    private static func itemType(_ item: [String: Any]) -> String {
        (item["type"] as? String) ?? ""
    }

    private static func trailingCallMessage(names: [String]) -> String {
        let named = names.filter { !$0.isEmpty }
        let label = named.isEmpty ? "a tool call" : "a tool call (\(named.joined(separator: ", ")))"
        return "The request would end with \(label) that has no result. "
            + "Servers such as LM Studio reject that as \"Cannot continue an assistant message that contains tool calls.\""
    }
}
