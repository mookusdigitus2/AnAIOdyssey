// SPDX-License-Identifier: MIT
import Foundation

/// Fields from LM Studio `GET /api/v1/models` (and the older v0 list).
public enum LMStudioModelRecord {
    /// Loaded instance `config.context_length`, else `max_context_length`.
    public static func contextLength(in row: [String: Any]) -> Int? {
        if let loaded = row["loaded_instances"] as? [[String: Any]] {
            for instance in loaded {
                if let config = instance["config"] as? [String: Any],
                   let length = intValue(config["context_length"]), length > 0 {
                    return length
                }
                if let length = intValue(instance["context_length"]), length > 0 {
                    return length
                }
            }
        }
        if let length = intValue(row["max_context_length"]), length > 0 {
            return length
        }
        if let length = intValue(row["context_length"]), length > 0 {
            return length
        }
        return nil
    }

    public static func supportsVision(in row: [String: Any]) -> Bool? {
        if let type = (row["type"] as? String)?.lowercased(), type == "vlm" {
            return true
        }
        if let capabilities = row["capabilities"] as? [String: Any],
           let vision = capabilities["vision"] as? Bool {
            return vision
        }
        return nil
    }

    public static func reasoningEfforts(in row: [String: Any]) -> [ReasoningEffort] {
        guard let names = reasoningOptionNames(in: row) else { return [] }
        return names.compactMap { ReasoningEffort(rawValue: $0) }
    }

    public static func defaultReasoningEffort(in row: [String: Any]) -> ReasoningEffort? {
        guard let reasoning = capabilityObject(row)?["reasoning"] as? [String: Any],
              let name = reasoning["default"] as? String else {
            return nil
        }
        return ReasoningEffort(rawValue: name)
    }

    public static func reasoningOptionNames(in row: [String: Any]) -> [String]? {
        guard let reasoning = capabilityObject(row)?["reasoning"] as? [String: Any],
              let options = reasoning["allowed_options"] as? [String] else {
            return nil
        }
        return options
    }

    private static func capabilityObject(_ row: [String: Any]) -> [String: Any]? {
        row["capabilities"] as? [String: Any]
    }

    private static func intValue(_ raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let value = raw as? Double { return Int(value) }
        if let number = raw as? NSNumber { return number.intValue }
        if let text = raw as? String { return Int(text) }
        return nil
    }
}

/// Provider-reported limits and flags for one model id, persisted on the connection.
public struct LiveModelCapabilities: Equatable, Sendable, Codable, Hashable {
    public var contextWindowTokens: Int?
    public var supportsVision: Bool?
    public var supportsTools: Bool?
    public var reasoningEfforts: [ReasoningEffort]
    public var defaultReasoningEffort: ReasoningEffort?

    public init(
        contextWindowTokens: Int? = nil,
        supportsVision: Bool? = nil,
        supportsTools: Bool? = nil,
        reasoningEfforts: [ReasoningEffort] = [],
        defaultReasoningEffort: ReasoningEffort? = nil
    ) {
        self.contextWindowTokens = contextWindowTokens
        self.supportsVision = supportsVision
        self.supportsTools = supportsTools
        self.reasoningEfforts = reasoningEfforts
        self.defaultReasoningEffort = defaultReasoningEffort
    }

    public var isEmpty: Bool {
        contextWindowTokens == nil
            && supportsVision == nil
            && supportsTools == nil
            && reasoningEfforts.isEmpty
            && defaultReasoningEffort == nil
    }

    public init(descriptor: RemoteModelDescriptor) {
        self.init(
            contextWindowTokens: descriptor.contextWindowTokens,
            supportsVision: descriptor.supportsVision,
            supportsTools: descriptor.supportsTools,
            reasoningEfforts: descriptor.reasoningEfforts,
            defaultReasoningEffort: descriptor.defaultReasoningEffort
        )
    }
}
