// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import SwiftUI
import AIConnect

@MainActor
public final class ResearchModelSettings: ObservableObject {
    /// Namespaced persistence keys for the research model settings.
    private enum Keys {
        static let useChatModel = "anaiodyssey.research.useChatModel"
        static let modelID = "anaiodyssey.research.modelID"
        static let backend = "anaiodyssey.research.backend"
    }

    /// When true, research reuses whatever model chat is using instead of the dedicated one.
    @Published public var useChatModel: Bool {
        didSet { defaults.set(useChatModel, forKey: Keys.useChatModel) }
    }

    /// The dedicated research model id (ignored when `useChatModel` is true).
    @Published public var modelID: String {
        didSet { defaults.set(modelID, forKey: Keys.modelID) }
    }

    /// The dedicated research backend preference.
    @Published public var backendPreference: LLMBackendPreference {
        didSet { backendPreference.store(defaults: defaults, key: Keys.backend) }
    }

    private let defaults: UserDefaults
    /// Token for the cloud-sync observer, removed on deinit.
    private var cloudSyncObserver: NSObjectProtocol?

    /// Loads persisted values (seeding sensible defaults from provider settings) and observes cloud sync.
    public init(defaults: UserDefaults = .standard, providerSettings: ProviderSettings) {
        self.defaults = defaults
        self.useChatModel = defaults.object(forKey: Keys.useChatModel) as? Bool ?? false
        let preferred = LLMModelPreparer.defaultResearchConfiguration(providerSettings: providerSettings)
        self.modelID = defaults.string(forKey: Keys.modelID) ?? preferred.modelID
        self.backendPreference = LLMBackendPreference.loadStored(
            defaults: defaults,
            key: Keys.backend,
            defaultValue: preferred.backend
        )
        cloudSyncObserver = NotificationCenter.default.addObserver(
            forName: AIConnectSync.settingsChangedExternally,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadFromDefaults() }
        }
    }

    deinit {
        if let cloudSyncObserver {
            NotificationCenter.default.removeObserver(cloudSyncObserver)
        }
    }

    /// Re-reads values from defaults after a cloud sync, only assigning changed ones to avoid redundant publishes.
    private func reloadFromDefaults() {
        let newUseChatModel = defaults.object(forKey: Keys.useChatModel) as? Bool ?? false
        if newUseChatModel != useChatModel { useChatModel = newUseChatModel }
        if let newModelID = defaults.string(forKey: Keys.modelID), newModelID != modelID {
            modelID = newModelID
        }
        if let raw = defaults.string(forKey: Keys.backend),
           let newBackend = LLMBackendPreference(rawValue: raw),
           newBackend != backendPreference {
            backendPreference = newBackend
        }
    }

    /// The model id research should actually use, accounting for the "use chat model" toggle.
    public func resolvedModelID(
        chatModelID: String,
        providerSettings: ProviderSettings
    ) -> String {
        if useChatModel { return chatModelID }
        return modelID
    }

    /// The backend research should actually use, accounting for the "use chat model" toggle.
    public func resolvedBackend(chatBackend: LLMBackendPreference) -> LLMBackendPreference {
        if useChatModel { return chatBackend }
        return backendPreference
    }

    /// Repairs a dangling dedicated model id (e.g. a remote model that's no longer configured) by snapping to a valid one.
    public func syncDefaultsIfNeeded(providerSettings: ProviderSettings) {
        let choices = ConfiguredModelRegistry.availableChoices(providerSettings: providerSettings)
        if !choices.contains(where: { $0.id == modelID }) {
            modelID = choices.first?.id ?? LLMModelCatalog.defaultModelID
        }
    }
}

/// Keyed persistence helpers so `ResearchModelSettings` can store its own backend
/// preference under a custom key (the public API in `LLMBackendPreference` is
/// hard-wired to the chat key).
