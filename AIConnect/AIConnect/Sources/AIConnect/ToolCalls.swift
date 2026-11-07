// SPDX-License-Identifier: MIT
import Foundation

/// One tool call a model asked for, whether it came from a native function call
/// or from a fenced code block in the reply text.
public struct ToolCallBlock: Sendable, Equatable {
    public let toolType: String
    public let content: String
    /// Responses API `call_id` when the tool came from a native `function_call`.
    public let callID: String?
    /// The model's own `arguments` JSON for a native call. `content` is only the extracted input,
    /// so history resends this instead (a server parses it as JSON).
    public let arguments: String?

    public init(toolType: String, content: String, callID: String? = nil, arguments: String? = nil) {
        self.toolType = toolType
        self.content = content
        self.callID = callID
        self.arguments = arguments
    }
}

/// Reads tool calls out of model output. The app decides which tool names exist;
/// this only finds calls to the names it is given.
public enum ToolCallParsing {
    /// Finds fenced code blocks whose language tag is one of `tags`. Each match
    /// yields the lowercased tag and the trimmed body. No tags means no tools.
    public static func parseToolBlocks(from text: String, tags: Set<String>) -> [ToolCallBlock] {
        guard let regex = fencedRegex(tags: tags, capturingBody: true) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var blocks: [ToolCallBlock] = []
        for match in regex.matches(in: text, options: [], range: range) {
            guard match.numberOfRanges >= 2,
                  let tagRange = Range(match.range(at: 1), in: text) else {
                continue
            }
            let tag = String(text[tagRange]).lowercased()
            let content: String
            if match.numberOfRanges >= 3, let contentRange = Range(match.range(at: 2), in: text) {
                content = String(text[contentRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                content = ""
            }
            blocks.append(ToolCallBlock(toolType: tag, content: content))
        }
        return blocks
    }

    /// Removes fenced tool blocks so only the model's prose is shown.
    public static func stripToolBlocks(from text: String, tags: Set<String>) -> String {
        guard let regex = fencedRegex(tags: tags, capturingBody: false) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let stripped = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Turns a native function call payload (Chat Completions or Responses) into a tool call.
    public static func toolBlock(from call: [String: Any]) -> ToolCallBlock? {
        let function: [String: Any]
        if let nested = call["function"] as? [String: Any] {
            function = nested
        } else {
            function = call
        }
        guard let name = function["name"] as? String else {
            return nil
        }
        let content = parseToolInput(from: function["arguments"])
        let rawID = (call["id"] as? String)
            ?? (call["call_id"] as? String)
            ?? (function["call_id"] as? String)
            ?? (function["id"] as? String)
        let callID = rawID.flatMap { $0.isEmpty ? nil : $0 }
        return ToolCallBlock(toolType: name.lowercased(), content: content, callID: callID,
                             arguments: rawArguments(function["arguments"]))
    }

    /// The native call's arguments as a JSON string (an object is serialized), nil if absent.
    private static func rawArguments(_ arguments: Any?) -> String? {
        if let text = arguments as? String { return text }
        if let object = arguments as? [String: Any], JSONSerialization.isValidJSONObject(object),
           let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
            return String(decoding: data, as: UTF8.self)
        }
        return nil
    }

    /// Extracts the tool body from native function-call arguments.
    public static func parseToolInput(from arguments: Any?) -> String {
        if let argsString = arguments as? String {
            let trimmed = argsString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return "" }
            if let data = trimmed.data(using: .utf8),
               let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return stringField(from: args)
            }
            if !trimmed.hasPrefix("{") {
                return trimmed
            }
            return ""
        }
        if let args = arguments as? [String: Any] {
            return stringField(from: args)
        }
        return ""
    }

    private static func stringField(from args: [String: Any]) -> String {
        for key in ["input", "query", "content", "text"] {
            if let value = args[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        for value in args.values {
            if let value = value as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return ""
    }

    private static func fencedRegex(tags: Set<String>, capturingBody: Bool) -> NSRegularExpression? {
        guard !tags.isEmpty else { return nil }
        let names = tags.sorted().map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        let body = capturingBody ? #"(?:\n([\s\S]*?))?"# : #"(?:\n[\s\S]*?)?"#
        let pattern = "```(" + names + #")\s*"# + body + "```"
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }
}
