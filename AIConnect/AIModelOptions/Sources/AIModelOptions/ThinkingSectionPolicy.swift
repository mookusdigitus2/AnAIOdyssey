// SPDX-License-Identifier: MIT
import Foundation

/// Chat Thinking disclosure: open while thoughts stream, then a timed
/// collapsed label once the first content token arrives.
public enum ThinkingSectionPolicy {
    public static let streamingTitle = "Thinking"
    public static let momentLabel = "Thought for a moment"

    public enum Presentation: Equatable, Sendable {
        case hidden
        case streaming
        case collapsed(label: String)
        case expanded(label: String)
    }

    /// `N` is first reasoning token → first content token, rounded to whole
    /// seconds. Under one second is "Thought for a moment".
    public static func durationLabel(seconds: TimeInterval) -> String {
        guard seconds >= 1 else { return momentLabel }
        let rounded = Int(seconds.rounded())
        if rounded == 1 { return "Thought for 1 second" }
        return "Thought for \(rounded) seconds"
    }

    public static func durationLabel(from start: Date, to end: Date) -> String {
        durationLabel(seconds: end.timeIntervalSince(start))
    }

    public static func persistedTitle(durationSeconds: TimeInterval?) -> String {
        guard let durationSeconds else { return streamingTitle }
        return durationLabel(seconds: durationSeconds)
    }

    public static func presentation(
        hasReasoning: Bool,
        hasContent: Bool,
        isStreaming: Bool,
        userExpanded: Bool,
        durationSeconds: TimeInterval?
    ) -> Presentation {
        guard hasReasoning else { return .hidden }
        if isStreaming && !hasContent {
            return .streaming
        }
        let label = persistedTitle(durationSeconds: durationSeconds)
        return userExpanded ? .expanded(label: label) : .collapsed(label: label)
    }

    public static func shouldForceCollapse(
        hasContent: Bool,
        userExpanded: Bool
    ) -> Bool {
        hasContent && !userExpanded
    }

    private static let reasoningMetadataKey = "assistantReasoning"
    private static let durationMetadataKey = "thoughtDurationSeconds"

    public static func mergeReasoning(
        existing: String?,
        reasoning: String?,
        durationSeconds: TimeInterval?
    ) -> String? {
        var object: [String: Any] = [:]
        if let existing,
           let data = existing.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            object = parsed
        }
        let trimmed = reasoning?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            object.removeValue(forKey: reasoningMetadataKey)
            object.removeValue(forKey: durationMetadataKey)
        } else {
            object[reasoningMetadataKey] = trimmed
            if let durationSeconds {
                object[durationMetadataKey] = durationSeconds
            } else {
                object.removeValue(forKey: durationMetadataKey)
            }
        }
        guard !object.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8)
        else {
            return existing.flatMap { $0.isEmpty ? nil : $0 }
        }
        return text
    }

    public static func reasoning(from metadata: String?) -> String? {
        guard let text = metadataObject(metadata)?[reasoningMetadataKey] as? String else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func thoughtDurationSeconds(from metadata: String?) -> TimeInterval? {
        guard let object = metadataObject(metadata) else { return nil }
        if let number = object[durationMetadataKey] as? Double { return number }
        if let number = object[durationMetadataKey] as? Int { return TimeInterval(number) }
        return nil
    }

    private static func metadataObject(_ metadata: String?) -> [String: Any]? {
        guard let metadata,
              let data = metadata.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return object
    }
}
