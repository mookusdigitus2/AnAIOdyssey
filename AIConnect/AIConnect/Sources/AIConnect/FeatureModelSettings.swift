// SPDX-License-Identifier: MIT
import Foundation

/// AI workspaces that can pin a default model in Settings.
public enum WorkspaceFeature: String, CaseIterable, Identifiable, Sendable {
    case chat
    case documents
    case research
    case email
    case tasks

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .chat: "Chat"
        case .documents: "Documents"
        case .research: "Research"
        case .email: "Email"
        case .tasks: "Tasks"
        }
    }
}

/// Persisted default model selections for each AI feature tab.
///
/// Resolution order for a feature tab:
/// 1. Per-tab override (when set and still valid)
/// 2. Global default for all tabs (when set and still valid)
/// 3. Controller agent default from Settings → Agents & Controller
@MainActor
public final class FeatureModelSettings: ObservableObject {
    private enum Keys {
        static let prefix = "anaiodyssey.featureModel."
        static let global = "anaiodyssey.featureModel.global"
    }

    private let defaults: UserDefaults
    private var cloudSyncObserver: NSObjectProtocol?

    /// Bumped whenever a stored default changes so open tabs can reload.
    @Published public private(set) var settingsRevision = 0

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        cloudSyncObserver = NotificationCenter.default.addObserver(
            forName: AIConnectSync.settingsChangedExternally,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.settingsRevision += 1
                self?.objectWillChange.send()
            }
        }
    }

    deinit {
        if let cloudSyncObserver {
            NotificationCenter.default.removeObserver(cloudSyncObserver)
        }
    }

    /// Stored global default for all tabs, if any.
    public func globalSelectionKey() -> String? {
        storedSelectionKey(forKey: Keys.global)
    }

    /// Persists the global default applied to every tab without its own override.
    public func setGlobalSelectionKey(_ selectionKey: String) {
        defaults.set(selectionKey, forKey: Keys.global)
        bumpRevision()
    }

    /// Clears the global default so tabs fall back to the controller agent.
    public func clearGlobalSelectionKey() {
        defaults.removeObject(forKey: Keys.global)
        bumpRevision()
    }

    public var hasGlobalOverride: Bool {
        globalSelectionKey() != nil
    }

    /// Returns the stored per-tab selection key, if any.
    public func selectionKey(for feature: WorkspaceFeature) -> String? {
        storedSelectionKey(forKey: storageKey(for: feature))
    }

    public func hasFeatureOverride(for feature: WorkspaceFeature) -> Bool {
        selectionKey(for: feature) != nil
    }

    /// Persists a per-tab override.
    public func setSelectionKey(_ selectionKey: String, for feature: WorkspaceFeature) {
        defaults.set(selectionKey, forKey: storageKey(for: feature))
        bumpRevision()
    }

    /// Clears a per-tab override so the tab uses the global default (or controller agent).
    public func clearSelectionKey(for feature: WorkspaceFeature) {
        defaults.removeObject(forKey: storageKey(for: feature))
        bumpRevision()
    }

    /// Repairs stored keys that reference removed models or deleted remote connections.
    public func syncDefaultsIfNeeded(providerSettings: ProviderSettings) {
        if let global = globalSelectionKey(),
           !isValidSelectionKey(global, providerSettings: providerSettings) {
            clearGlobalSelectionKey()
        }
        for feature in WorkspaceFeature.allCases {
            guard let stored = selectionKey(for: feature) else { continue }
            if !isValidSelectionKey(stored, providerSettings: providerSettings) {
                clearSelectionKey(for: feature)
            }
        }
    }

    /// Drops stored keys that pointed at a deleted remote connection.
    public func removeReferences(toConnectionID connectionID: String) {
        if let global = globalSelectionKey(),
           referencesConnection(connectionID, in: global) {
            clearGlobalSelectionKey()
        }
        for feature in WorkspaceFeature.allCases {
            guard let stored = selectionKey(for: feature),
                  referencesConnection(connectionID, in: stored) else {
                continue
            }
            clearSelectionKey(for: feature)
        }
        bumpRevision()
    }

    private func storedSelectionKey(forKey key: String) -> String? {
        guard let value = defaults.string(forKey: key), !value.isEmpty else { return nil }
        return value
    }

    private func storageKey(for feature: WorkspaceFeature) -> String {
        Keys.prefix + feature.rawValue
    }

    public func isValidSelectionKey(
        _ selectionKey: String,
        providerSettings: ProviderSettings
    ) -> Bool {
        ConfiguredModelRegistry.choice(forSelectionKey: selectionKey, providerSettings: providerSettings) != nil
    }

    private func referencesConnection(_ connectionID: String, in selectionKey: String) -> Bool {
        ConfiguredModelRegistry.parseSelectionKey(selectionKey)?.connectionID == connectionID
    }

    private func bumpRevision() {
        settingsRevision += 1
        objectWillChange.send()
    }
}
