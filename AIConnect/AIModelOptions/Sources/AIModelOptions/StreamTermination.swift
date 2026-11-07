// SPDX-License-Identifier: MIT
import Foundation

/// Why a provider stream ended, when it says so.
public enum StreamTermination: Equatable, Sendable {
    case stop
    case length
    case contentFilter
    case error(String)
    case incomplete(String)

    public var isCutoff: Bool {
        switch self {
        case .length, .contentFilter, .incomplete: true
        case .stop, .error: false
        }
    }

    public var isFailure: Bool {
        switch self {
        case .error: true
        case .stop, .length, .contentFilter, .incomplete: false
        }
    }

    /// Short line the UI can show next to a partial reply.
    public var userMessage: String {
        switch self {
        case .stop:
            return ""
        case .length:
            return "The reply was cut off (length). Raise Max output or ask it to continue."
        case .contentFilter:
            return "The reply was cut off (content filter)."
        case .incomplete(let reason):
            return "The reply was cut off (\(reason)). Raise Max output or ask it to continue."
        case .error(let message):
            return message
        }
    }

    public static func from(finishReason: String?) -> StreamTermination? {
        guard let raw = finishReason?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else {
            return nil
        }
        switch raw {
        case "stop", "end_turn", "tool_calls", "function_call":
            return .stop
        case "length", "max_tokens", "max_output_tokens":
            return .length
        case "content_filter", "content_filter_violation":
            return .contentFilter
        default:
            return nil
        }
    }
}

public enum StreamTextCodecTermination {
    /// Chat Completions `finish_reason`, Responses `incomplete_details`, or a mid-stream `error`.
    public static func termination(in json: String) -> StreamTermination? {
        let payload = StreamTextCodec.ssePayload(json) ?? StreamTextCodec.stripSSEPrefix(json)
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let error = object["error"] as? [String: Any] {
            let message = (error["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let message, !message.isEmpty {
                return .error(message)
            }
            return .error("The provider returned an error mid-stream.")
        }
        if let error = object["error"] as? String, !error.isEmpty {
            return .error(error)
        }
        if let choices = object["choices"] as? [[String: Any]],
           let reason = choices.first?["finish_reason"] as? String {
            return StreamTermination.from(finishReason: reason)
        }
        let type = object["type"] as? String ?? ""
        if type == "response.failed" || type == "error" {
            return .error("The Responses API request failed.")
        }
        if type == "response.incomplete" {
            let response = object["response"] as? [String: Any]
            let reason = (response?["incomplete_details"] as? [String: Any])?["reason"] as? String
                ?? (object["incomplete_details"] as? [String: Any])?["reason"] as? String
                ?? "unknown"
            if reason == "max_output_tokens" || reason == "length" {
                return .length
            }
            if reason == "content_filter" {
                return .contentFilter
            }
            return .incomplete(reason)
        }
        if let response = object["response"] as? [String: Any],
           let details = response["incomplete_details"] as? [String: Any],
           let reason = details["reason"] as? String {
            if reason == "max_output_tokens" || reason == "length" {
                return .length
            }
            if reason == "content_filter" {
                return .contentFilter
            }
            return .incomplete(reason)
        }
        return nil
    }
}
