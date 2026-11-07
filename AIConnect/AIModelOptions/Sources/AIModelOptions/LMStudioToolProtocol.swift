// SPDX-License-Identifier: MIT
import Foundation

/// LM Studio's published tool protocol.
///
/// Tool use is `POST /v1/chat/completions` with an OpenAI `tools` array
/// (https://lmstudio.ai/docs/developer/openai-compat/tools). The docs say every
/// model LM Studio chats with supports tool use. Two levels:
/// - Native: the chat template was trained for tools (`trained_for_tool_use: true`,
///   or v0 `capabilities` contains `"tool_use"`). Qwen 2.5 / 3.0 templates emit
///   `<tool_call>{"name","arguments"}</tool_call>`; Qwen3.5 / 3.6 / 3.8 and Qwen3-Coder emit
///   XML: `<tool_call>\n<function=NAME>\n<parameter=K>\nV\n</parameter>\n</function>\n</tool_call>`.
/// - Default: everyone else still gets a `[TOOL_REQUEST]...[END_TOOL_REQUEST]`
///   prompt, and LM Studio still parses a well-formed call into `tool_calls`.
///
/// `trained_for_tool_use: false` and a v0 capabilities array without `tool_use`
/// mean default tool use, not "this model cannot call tools". Embedding and
/// decision models are the rows with no tool use (`GET /api/v1/models`).
public enum LMStudioToolProtocol {
    public struct Call: Equatable, Sendable {
        public var id: String
        public var name: String
        public var argumentsJSON: String

        public init(id: String, name: String, argumentsJSON: String) {
            self.id = id
            self.name = name
            self.argumentsJSON = argumentsJSON
        }
    }

    /// Whether this `/api/v1/models` or `/api/v0/models` row can call tools.
    /// Nil when the row is not an LM Studio model record.
    public static func supportsTools(in row: [String: Any]) -> Bool? {
        if let type = (row["type"] as? String)?.lowercased() {
            switch type {
            case "embedding", "embeddings", "decision":
                return false
            case "llm", "vlm":
                return true
            default:
                break
            }
        }
        // Present on LM Studio llm capabilities. False is default tool use.
        if let capabilities = row["capabilities"] as? [String: Any],
           (capabilities["trained_for_tool_use"] as? Bool) != nil {
            return true
        }
        return nil
    }

    /// `choices[0].message`: structured `tool_calls` when LM Studio parsed them, otherwise the
    /// documented text formats left in the answer (`content` after the thinking).
    ///
    /// When the model gave no answer at all (`content` empty after the thinking, the
    /// lmstudio-bug-tracker #1870 case), the call may be in the thinking. Then only the **last**
    /// call there is taken, only from one source (a `<think>` block in `content`, else
    /// `reasoning_content` / `reasoning`), and only when it names an offered tool, so drafts,
    /// the template's `example_function_name` and duplicates never run.
    ///
    /// `tools` maps tool name to its parameters JSON Schema, used to type XML parameters.
    public static func calls(in message: [String: Any], tools: [String: String] = [:]) -> [Call] {
        let structured = calls(fromToolCalls: message["tool_calls"] as? [[String: Any]] ?? [])
        if !structured.isEmpty { return structured }
        let content = contentText(message["content"])
        let answerText = strippingThinking(content)
        let answer = scan(answerText, tools: tools).calls
        if !answer.isEmpty { return answer }
        guard answerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !tools.isEmpty,
              let thinking = thinking(in: content) ?? reasoningText(in: message),
              let last = scan(thinking, tools: tools).calls.last(where: { tools[$0.name] != nil }) else { return [] }
        return [Call(id: "content-tool-1", name: last.name, argumentsJSON: last.argumentsJSON)]
    }

    public static func calls(fromToolCalls raw: [[String: Any]]) -> [Call] {
        raw.enumerated().compactMap { index, call in
            let function = (call["function"] as? [String: Any]) ?? call
            guard let name = function["name"] as? String, !name.isEmpty else { return nil }
            let id = (call["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "tool-call-\(index + 1)"
            return Call(id: id, name: name, argumentsJSON: argumentsJSON(function["arguments"]))
        }
    }

    /// Calls left as text in the answer: Qwen `<tool_call>{json}</tool_call>`, Qwen3.5+ XML
    /// `<tool_call><function=…>` (also bare `<function=…>` with no wrapper), and default
    /// `[TOOL_REQUEST]{json}[END_TOOL_REQUEST]`. Thinking up to the last `</think>` is ignored.
    /// A block that doesn't parse is left unparsed, matching LM Studio when the model emits a
    /// malformed call. XML parameters are typed from `tools` (name to parameters JSON Schema);
    /// a parameter with no schema type stays text.
    public static func calls(inContent text: String, tools: [String: String] = [:]) -> [Call] {
        scan(strippingThinking(text), tools: tools).calls
    }

    /// Reply text with parsed tool-call blocks removed. A malformed block stays, which is what
    /// LM Studio leaves in `content` when it cannot parse the call. Thinking before the last
    /// `</think>` is left as is for apps that show it.
    public static func prose(from text: String) -> String {
        let (head, answer) = splitAtThinkingEnd(text)
        return (head + scan(answer, tools: [:]).prose).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The answer after the last `</think>`. Qwen3.5+ templates open `<think>` in the prompt, so
    /// a reply often carries only the closing tag. An unclosed `<think>` is all thinking.
    public static func strippingThinking(_ text: String) -> String {
        let (head, answer) = splitAtThinkingEnd(text)
        if head.isEmpty, answer.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<think>") { return "" }
        return answer
    }

    /// The thinking a reply carries in `content` (before the last `</think>`, or an unclosed
    /// `<think>` block), without the tags. Nil when there is none.
    public static func thinking(in text: String) -> String? {
        var (head, answer) = splitAtThinkingEnd(text)
        if head.isEmpty {
            guard answer.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<think>") else { return nil }
            head = answer
        }
        let cleaned = head.replacingOccurrences(of: "<think>", with: "")
            .replacingOccurrences(of: "</think>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// `reasoning_content` (LM Studio, llama.cpp) or `reasoning` from a Chat Completions message.
    public static func reasoningText(in message: [String: Any]) -> String? {
        for key in ["reasoning_content", "reasoning"] {
            let text = contentText(message[key]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }
        return nil
    }

    /// Whether text still holds tool-call markup (a call that did not parse).
    public static func containsToolCallMarkup(_ text: String) -> Bool {
        text.contains("<tool_call>") || text.contains("<function=") || text.contains("[TOOL_REQUEST]")
    }

    /// Ids a chat request might use for one list row: `key`, loaded instance id, and variants.
    public static func aliasIDs(in row: [String: Any]) -> [String] {
        var ids: [String] = []
        func add(_ value: String?) {
            guard let value, !value.isEmpty, !ids.contains(value) else { return }
            ids.append(value)
        }
        add(row["key"] as? String)
        add(row["id"] as? String)
        add(row["selected_variant"] as? String)
        if let variants = row["variants"] as? [String] {
            for variant in variants { add(variant) }
        }
        if let loaded = row["loaded_instances"] as? [[String: Any]] {
            for instance in loaded { add(instance["id"] as? String) }
        }
        return ids
    }

    // MARK: - Private

    private static func contentText(_ content: Any?) -> String {
        if let text = content as? String { return text }
        if let parts = content as? [[String: Any]] {
            return parts.compactMap { $0["text"] as? String }.joined()
        }
        return ""
    }

    static func argumentsJSON(_ value: Any?) -> String {
        if value == nil || value is NSNull { return "{}" }
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "{}" : trimmed
        }
        if let object = value as? [String: Any], JSONSerialization.isValidJSONObject(object),
           let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
            return String(decoding: data, as: UTF8.self)
        }
        return "{}"
    }

    private static func jsonObject(_ text: String) -> [String: Any]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }

    /// Splits at the end of the thinking: the first `</think>` that ends its line outside a
    /// markdown code fence (`…\n</think>\n\n` is how Qwen and DeepSeek close thinking), else, when
    /// the reply opens with `<think>`, its last `</think>`. A `</think>` mentioned inside an answer's
    /// sentence or shown in a code block is not thinking.
    private static func splitAtThinkingEnd(_ text: String) -> (head: String, answer: String) {
        func split(_ end: Range<String.Index>) -> (head: String, answer: String) {
            (String(text[..<end.upperBound]), String(text[end.upperBound...]))
        }
        var inFence = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.drop(while: { $0 == " " || $0 == "\t" }).hasPrefix("```") { inFence.toggle(); continue }
            guard !inFence, let end = line.range(of: "</think>", options: .backwards) else { continue }
            if line[end.upperBound...].allSatisfy({ $0 == " " || $0 == "\t" || $0 == "\r" }) { return split(end) }
        }
        // A fence left open means the code-block reading can't be trusted (Qwen3.5+ thinking with
        // a lone ``` line, no opening tag): fall back to the last `</think>` that ends its line.
        if inFence {
            var searchEnd = text.endIndex
            while let end = text.range(of: "</think>", options: .backwards, range: text.startIndex..<searchEnd) {
                let restOfLine = text[end.upperBound...].prefix { $0 != "\n" }
                if restOfLine.allSatisfy({ $0 == " " || $0 == "\t" || $0 == "\r" }) { return split(end) }
                searchEnd = end.lowerBound
            }
        }
        if text.drop(while: { $0.isWhitespace }).hasPrefix("<think>"),
           let end = text.range(of: "</think>", options: .backwards) {
            return split(end)
        }
        return ("", text)
    }

    /// Whether only spaces or tabs sit between the start of its line and `index`.
    private static func startsLine(_ index: String.Index, in text: String) -> Bool {
        var i = index
        while i > text.startIndex {
            let previous = text.index(before: i)
            switch text[previous] {
            case "\n": return true
            case " ", "\t": i = previous
            default: return false
            }
        }
        return true
    }

    private static let openers = ["<tool_call>", "[TOOL_REQUEST]", "<function="]

    /// One pass over `text` in order: parsed calls, and the text with parsed blocks removed.
    /// Markdown code fences are copied as text: a call shown in a code block is an example.
    private static func scan(_ text: String, tools: [String: String]) -> (calls: [Call], prose: String) {
        var calls: [Call] = []
        var prose = ""
        var rest = text[...]
        func add(_ name: String, _ arguments: String) {
            calls.append(Call(id: "content-tool-\(calls.count + 1)", name: name, argumentsJSON: arguments))
        }
        while let (opener, start) = nextOpener(in: rest) {
            if let fence = rest.range(of: "```"), fence.lowerBound < start.lowerBound {
                // A ``` that never closes: on a line of its own it opens a code block that runs to the
                // end (a draft cut off at max tokens is an example); mid-line it's a stray mention,
                // so skip just the marker and keep reading.
                let fenceEnd = rest[fence.upperBound...].range(of: "```")?.upperBound
                    ?? (startsLine(fence.lowerBound, in: text) ? rest.endIndex : fence.upperBound)
                prose += rest[..<fenceEnd]
                rest = rest[fenceEnd...]
                continue
            }
            prose += rest[..<start.lowerBound]
            let after = rest[start.upperBound...]
            switch opener {
            case "<function=":
                // Bare XML function block with no <tool_call> wrapper.
                guard let close = after.range(of: "</function>"),
                      let call = xmlFunctionCalls(in: rest[start.lowerBound..<close.upperBound], tools: tools).first else {
                    prose += rest[start]
                    rest = after
                    continue
                }
                add(call.name, call.argumentsJSON)
                rest = after[close.upperBound...]
            default:
                let closeTag = opener == "<tool_call>" ? "</tool_call>" : "[END_TOOL_REQUEST]"
                guard let end = after.range(of: closeTag) else {
                    prose += rest[start.lowerBound...]
                    rest = rest[rest.endIndex...]
                    continue
                }
                let body = after[..<end.lowerBound]
                let xml = opener == "<tool_call>" ? xmlFunctionCalls(in: body, tools: tools) : []
                if let object = jsonObject(String(body)), let name = object["name"] as? String, !name.isEmpty {
                    add(name, argumentsJSON(object["arguments"]))
                } else if !xml.isEmpty {
                    for call in xml { add(call.name, call.argumentsJSON) }
                } else {
                    prose += rest[start.lowerBound..<end.upperBound]
                }
                rest = after[end.upperBound...]
            }
        }
        prose += rest
        return (calls, prose)
    }

    private static func nextOpener(in text: Substring) -> (String, Range<Substring.Index>)? {
        var best: (String, Range<Substring.Index>)?
        for opener in openers {
            if let range = text.range(of: opener), best.map({ range.lowerBound < $0.1.lowerBound }) ?? true {
                best = (opener, range)
            }
        }
        return best
    }

    /// Qwen3.5+ / Qwen3-Coder: `<function=NAME>` then `<parameter=K>\nV\n</parameter>` pairs, then
    /// `</function>`. A block missing its `</function>` or a parameter's close tag is malformed.
    private static func xmlFunctionCalls(in text: Substring, tools: [String: String]) -> [(name: String, argumentsJSON: String)] {
        var out: [(name: String, argumentsJSON: String)] = []
        var rest = text
        while let open = rest.range(of: "<function=") {
            guard let nameEnd = rest[open.upperBound...].range(of: ">"),
                  let close = rest[nameEnd.upperBound...].range(of: "</function>") else { return [] }
            let name = rest[open.upperBound..<nameEnd.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return [] }
            let properties = schemaProperties(tools[name])
            var body = rest[nameEnd.upperBound..<close.lowerBound]
            var args: [String: Any] = [:]
            while let p = body.range(of: "<parameter=") {
                guard let keyEnd = body[p.upperBound...].range(of: ">"),
                      let pc = body[keyEnd.upperBound...].range(of: "</parameter>") else { return [] }
                let key = body[p.upperBound..<keyEnd.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                var raw = String(body[keyEnd.upperBound..<pc.lowerBound])
                if raw.hasPrefix("\n") { raw.removeFirst() }
                if raw.hasSuffix("\n") { raw.removeLast() }
                if !key.isEmpty { args[key] = typedValue(raw, schema: properties[key]) }
                body = body[pc.upperBound...]
            }
            out.append((name, argumentsJSON(args)))
            rest = rest[close.upperBound...]
        }
        return out
    }

    private static func schemaProperties(_ parametersJSON: String?) -> [String: Any] {
        guard let parametersJSON, let schema = jsonObject(parametersJSON) else { return [:] }
        return schema["properties"] as? [String: Any] ?? [:]
    }

    /// Types an XML parameter from its JSON Schema `type`; strings (and unknown types) stay
    /// text, so `"007"` is never turned into a number (LM Studio 0.4.7 had that bug).
    private static func typedValue(_ raw: String, schema: Any?) -> Any {
        let declared: [String]
        if let type = (schema as? [String: Any])?["type"] as? String {
            declared = [type]
        } else if let types = (schema as? [String: Any])?["type"] as? [String] {
            declared = types
        } else {
            return raw
        }
        if declared.contains("string") { return raw }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if declared.contains("boolean") {
            switch trimmed.lowercased() {
            case "true": return true
            case "false": return false
            default: break
            }
        }
        if declared.contains("integer"), let value = Int(trimmed) { return value }
        if declared.contains("integer") || declared.contains("number"), let value = Double(trimmed), value.isFinite {
            if declared.contains("integer"), value.rounded() == value, abs(value) < 1e15 { return Int(value) }
            return value
        }
        if declared.contains("object") || declared.contains("array"),
           let data = trimmed.data(using: .utf8),
           let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
           value is [String: Any] || value is [Any] {
            return value
        }
        if declared.contains("null"), trimmed == "null" { return NSNull() }
        return raw
    }
}
