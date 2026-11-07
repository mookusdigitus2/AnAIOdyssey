// SPDX-License-Identifier: MIT
import Foundation

/// The user's choice of which inference backend to use for chat/research.
///
/// Persisted as a raw string in `UserDefaults`. `.auto` lets the app pick the
/// best available option at load time (try local MLX, then remote), while the
/// explicit cases pin behavior to a single backend.
public enum LLMBackendPreference: String, CaseIterable, Identifiable, Sendable {
    case auto
    case localMLX
    case appleFoundation
    case remote

    public var id: String { rawValue }

    /// Short label for the preference, shown in settings pickers.
    public var title: String {
        switch self {
        case .auto: "Automatic"
        case .localMLX: "Local (MLX)"
        case .appleFoundation: "Apple On-Device"
        case .remote: "Remote API"
        }
    }

    /// Longer explanatory text describing the trade-offs of each preference.
    public var subtitle: String {
        switch self {
        case .auto: "Try on-device models, then remote if configured"
        case .localMLX: "On-device MLX models only"
        case .appleFoundation: "On-device AI for summarizing and rewriting"
        case .remote: "OpenAI-compatible HTTP API"
        }
    }

    /// MLX or Apple Foundation — both run on the device.
    public var isOnDevice: Bool {
        switch self {
        case .localMLX, .appleFoundation: true
        case .auto, .remote: false
        }
    }

    /// `UserDefaults` keys, namespaced to avoid collisions with other settings.
    private enum Keys {
        static let preference = "anaiodyssey.chat.backendPreference"
    }

    /// Reads the stored chat backend preference, defaulting to `.auto` when unset or corrupt.
    public static func loadStored(defaults: UserDefaults = .standard) -> LLMBackendPreference {
        guard let raw = defaults.string(forKey: Keys.preference),
              let value = LLMBackendPreference(rawValue: raw) else {
            return .auto
        }
        return value
    }

    /// Persists this preference as the chat backend choice.
    public func store(defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Keys.preference)
    }
}

/// Refinement of `LLMServiceProtocol` for backends that can switch between
/// multiple underlying providers (i.e. the composite service).
///
/// Adds the ability to read/change the active preference and to inspect which
/// concrete backend is currently serving requests, which the settings UI uses
/// to show the live state and whether remote is even an option.
@MainActor
public protocol LLMBackendSelectable: LLMServiceProtocol {
    /// The currently selected backend preference; changing it affects the next load.
    var backendPreference: LLMBackendPreference { get set }
    /// Label for the backend actually serving requests right now (e.g. "MLX", "Remote", "Mock").
    var activeBackendLabel: String { get }
    /// Whether a remote provider is configured and could be used.
    var isRemoteAvailable: Bool { get }
}

/// Composite LLM services that route remote traffic through a specific connection.
@MainActor
public protocol RemoteConnectionSelectable: LLMBackendSelectable {
    var selectedRemoteConnectionID: String? { get set }
}
