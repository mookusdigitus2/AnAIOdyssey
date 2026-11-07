// SPDX-License-Identifier: MIT
import Foundation

/// OpenAI-style reasoning effort levels for models that support them.
///
/// Raw values match API tokens (`reasoning.effort` / `reasoning_effort`).
/// GPT-6 Astra accepts `low`, `medium`, `high`, `xhigh`, and `max`; `none`
/// returns HTTP 400 and `minimal` is unsupported.
public enum ReasoningEffort: String, Codable, CaseIterable, Sendable, Identifiable {
    case none
    case minimal
    case low
    case medium
    case high
    case xhigh
    case max

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .none: "None"
        case .minimal: "Minimal"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .xhigh: "Extra High"
        case .max: "Max"
        }
    }
}
