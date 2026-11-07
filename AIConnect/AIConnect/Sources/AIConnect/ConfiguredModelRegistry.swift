// SPDX-License-Identifier: MIT
import Foundation
import AIModelOptions
import SwiftUI

/// A concrete, pickable model+backend pairing for the model selector UI.
///
/// Because the same model id can exist on more than one backend, a choice is
/// identified by the composite `selectionKey` (backend + id) rather than the id
/// alone, so the picker can disambiguate (e.g. local vs remote).
public struct ConfiguredModelChoice: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let backend: LLMBackendPreference
    public let providerLabel: String
    /// Remote connections only — disambiguates which endpoint serves this model.
    public let connectionID: String?

    public init(
        id: String,
        displayName: String,
        backend: LLMBackendPreference,
        providerLabel: String? = nil,
        connectionID: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.backend = backend
        self.providerLabel = providerLabel ?? backend.title
        self.connectionID = connectionID
    }

    /// Stable composite key (`backend|connection|id` for remote) used to persist selections.
    public var selectionKey: String {
        if backend == .remote, let connectionID {
            return "\(backend.rawValue)|\(connectionID)|\(id)"
        }
        return "\(backend.rawValue)|\(id)"
    }

    /// Label combining model and provider for display in a picker row.
    public var pickerLabel: String {
        if providerLabel == displayName {
            return displayName
        }
        return "\(displayName) · \(providerLabel)"
    }
}

/// Parsed workspace model selection key.
public struct ParsedModelSelection: Sendable {
    public let modelID: String
    public let backend: LLMBackendPreference
    public let connectionID: String?
}

/// Builds the list of selectable model choices by merging the static local
/// catalog with any models discovered from the configured remote provider.
///
/// This is the bridge between raw backends and the model-picker UI: it knows how
/// to enumerate, look up, and infer the backend for a given model id.
@MainActor
public enum ConfiguredModelRegistry {
    /// All choices the user can pick right now: every local model, plus remote models when a provider is configured.
    ///
    /// When `downloadedLocalModelIDs` is provided, local MLX models are filtered to
    /// only those whose weights are actually present on disk. Local MLX rows are
    /// omitted unless `offerLocalMLX` is true. Apple's Foundation Model is listed
    /// when `offerAppleFoundation` is true (runtime `.available` only).
    public enum PickerScope: Sendable {
        /// Local MLX plus the 10 newest chat models per remote connection.
        case chatRecent
        /// Image-generation models only.
        case imageOnly
        /// Every conversational and image model (Compare).
        case unfiltered
    }

    public static func availableChoices(
        providerSettings: ProviderSettings,
        downloadedLocalModelIDs: Set<String>? = nil,
        scope: PickerScope = .chatRecent,
        offerLocalMLX: Bool = OnDeviceLanguageModelSupport.shouldOfferLocalMLX,
        offerAppleFoundation: Bool = OnDeviceLanguageModelSupport.shouldOfferAppleFoundation
    ) -> [ConfiguredModelChoice] {
        var choices: [ConfiguredModelChoice] = []
        if scope != .imageOnly, offerAppleFoundation {
            choices.append(AppleFoundationModel.choice)
        }
        if scope != .imageOnly, offerLocalMLX {
            let localOptions = downloadedLocalModelIDs.map { downloaded in
                LLMModelCatalog.models.filter { downloaded.contains($0.id) }
            } ?? LLMModelCatalog.models
            choices.append(contentsOf: localOptions.map(localChoice(for:)))
        }

        for connection in providerSettings.remoteConnections {
            guard isUsableRemoteConnection(connection, providerSettings: providerSettings) else { continue }
            let label = remoteProviderLabel(for: connection)
            for modelID in remoteModelIDs(for: connection, scope: scope) {
                let key = selectionKey(modelID: modelID, backend: .remote, connectionID: connection.id)
                if !choices.contains(where: { $0.selectionKey == key }) {
                    choices.append(
                        ConfiguredModelChoice(
                            id: modelID,
                            displayName: ModelCapabilityCatalog.displayName(
                                forModelID: modelID,
                                backend: .remote
                            ),
                            backend: .remote,
                            providerLabel: label,
                            connectionID: connection.id
                        )
                    )
                }
            }
        }

        return choices
    }

    /// Picker rows for a control, plus the stored selection when the truncated
    /// (10-newest) list dropped it but the catalog still recognizes it.
    public static func pickerChoices(
        providerSettings: ProviderSettings,
        downloadedLocalModelIDs: Set<String>? = nil,
        scope: PickerScope = .chatRecent,
        selectionKey: String = "",
        offerLocalMLX: Bool = OnDeviceLanguageModelSupport.shouldOfferLocalMLX,
        offerAppleFoundation: Bool = OnDeviceLanguageModelSupport.shouldOfferAppleFoundation
    ) -> [ConfiguredModelChoice] {
        var choices = availableChoices(
            providerSettings: providerSettings,
            downloadedLocalModelIDs: downloadedLocalModelIDs,
            scope: scope,
            offerLocalMLX: offerLocalMLX,
            offerAppleFoundation: offerAppleFoundation
        )
        let recognized: Bool
        if let current = choice(forSelectionKey: selectionKey, providerSettings: providerSettings) {
            switch current.backend {
            case .localMLX: recognized = offerLocalMLX
            case .appleFoundation: recognized = offerAppleFoundation
            case .remote, .auto: recognized = true
            }
        } else {
            recognized = false
        }
        let keys = PickerSelectionPolicy.visibleKeys(
            listed: choices.map(\.selectionKey),
            stored: selectionKey,
            storedIsRecognized: recognized
        )
        if keys.first == selectionKey,
           !choices.contains(where: { $0.selectionKey == selectionKey }),
           let current = choice(forSelectionKey: selectionKey, providerSettings: providerSettings) {
            choices.insert(current, at: 0)
        }
        return choices
    }

    /// Keep a valid stored picker key; snap only when it is empty or invalid.
    public static func resolvedPickerSelection(
        stored: String,
        choices: [ConfiguredModelChoice]
    ) -> String {
        PickerSelectionPolicy.resolvedKey(
            stored: stored,
            visible: choices.map(\.selectionKey),
            fallback: choices.first?.selectionKey
        )
    }

    /// First runnable choice. Apple On-Device is listed when Intelligence is off
    /// or still preparing, but it is not the default until `.available`.
    public static func defaultChoice(providerSettings: ProviderSettings) -> ConfiguredModelChoice {
        let choices = availableChoices(providerSettings: providerSettings)
        if OnDeviceLanguageModelSupport.appleFoundationIsReady,
           let apple = choices.first(where: { $0.backend == .appleFoundation }) {
            return apple
        }
        if let other = choices.first(where: { $0.backend != .appleFoundation }) {
            return other
        }
        if OnDeviceLanguageModelSupport.shouldOfferLocalMLX {
            return ConfiguredModelChoice(
                id: LLMModelCatalog.defaultModelID,
                displayName: "Llama 3.2 1B (4-bit)",
                backend: .localMLX
            )
        }
        return ConfiguredModelChoice(
            id: "",
            displayName: "No model",
            backend: .remote
        )
    }

    /// Looks up a choice by its composite selection key.
    ///
    /// Resolves the key directly instead of rebuilding the full picker list.
    /// Settings bindings call this while scrolling, so a linear rebuild (and any
    /// work it fans out to) must not run on every body evaluation.
    public static func choice(
        forSelectionKey selectionKey: String,
        providerSettings: ProviderSettings
    ) -> ConfiguredModelChoice? {
        guard let parsed = parseSelectionKey(selectionKey) else { return nil }
        switch parsed.backend {
        case .appleFoundation:
            guard OnDeviceLanguageModelSupport.shouldOfferAppleFoundation,
                  parsed.modelID == AppleFoundationModel.modelID else { return nil }
            return AppleFoundationModel.choice
        case .localMLX:
            guard OnDeviceLanguageModelSupport.shouldOfferLocalMLX,
                  let option = LLMModelCatalog.option(for: parsed.modelID) else { return nil }
            return localChoice(for: option)
        case .remote:
            guard let connectionID = parsed.connectionID,
                  let connection = providerSettings.connection(id: connectionID),
                  isUsableRemoteConnection(connection, providerSettings: providerSettings),
                  conversationalRemoteModelIDs(for: connection).contains(parsed.modelID)
            else {
                return nil
            }
            return ConfiguredModelChoice(
                id: parsed.modelID,
                displayName: ModelCapabilityCatalog.displayName(
                    forModelID: parsed.modelID,
                    backend: .remote
                ),
                backend: .remote,
                providerLabel: remoteProviderLabel(for: connection),
                connectionID: connectionID
            )
        case .auto:
            return nil
        }
    }

    /// Builds the composite selection key, including connection id for remote backends.
    public static func selectionKey(
        modelID: String,
        backend: LLMBackendPreference,
        connectionID: String? = nil
    ) -> String {
        if backend == .remote, let connectionID {
            return "\(backend.rawValue)|\(connectionID)|\(modelID)"
        }
        return "\(backend.rawValue)|\(modelID)"
    }

    /// Splits a composite selection key back into model id, backend, and optional connection id.
    public static func parseSelectionKey(_ selectionKey: String) -> ParsedModelSelection? {
        let parts = selectionKey.split(separator: "|", maxSplits: 2).map(String.init)
        guard parts.count >= 2,
              let backend = LLMBackendPreference(rawValue: parts[0]) else {
            return nil
        }
        if backend == .remote, parts.count == 3 {
            return ParsedModelSelection(modelID: parts[2], backend: backend, connectionID: parts[1])
        }
        return ParsedModelSelection(modelID: parts[1], backend: backend, connectionID: nil)
    }

    /// Finds the first choice matching a bare model id (ignoring backend).
    ///
    /// Matches ``availableChoices`` order: local catalog first, then enabled
    /// remote connections, without allocating the combined list.
    public static func choice(
        for modelID: String,
        providerSettings: ProviderSettings
    ) -> ConfiguredModelChoice? {
        if OnDeviceLanguageModelSupport.shouldOfferAppleFoundation,
           modelID == AppleFoundationModel.modelID {
            return AppleFoundationModel.choice
        }
        if OnDeviceLanguageModelSupport.shouldOfferLocalMLX,
           let option = LLMModelCatalog.option(for: modelID) {
            return localChoice(for: option)
        }
        for connection in providerSettings.remoteConnections {
            guard isUsableRemoteConnection(connection, providerSettings: providerSettings),
                  conversationalRemoteModelIDs(for: connection).contains(modelID)
            else {
                continue
            }
            return ConfiguredModelChoice(
                id: modelID,
                displayName: ModelCapabilityCatalog.displayName(
                    forModelID: modelID,
                    backend: .remote
                ),
                backend: .remote,
                providerLabel: remoteProviderLabel(for: connection),
                connectionID: connection.id
            )
        }
        return nil
    }

    /// Local picker row for a catalog model.
    private static func localChoice(for option: LLMModelOption) -> ConfiguredModelChoice {
        ConfiguredModelChoice(
            id: option.id,
            displayName: option.displayName,
            backend: .localMLX,
            providerLabel: "Local MLX"
        )
    }

    /// Whether a connection is enabled and has enough config to appear in pickers.
    private static func isUsableRemoteConnection(
        _ connection: RemoteConnection,
        providerSettings: ProviderSettings
    ) -> Bool {
        connection.isEnabled && providerSettings.adapter(for: connection).isConfigured(connection: connection)
    }

    /// Conversational model ids a connection can offer (default or queried list).
    ///
    /// Providers list every model they serve, including ones that can never
    /// answer a conversational request (embeddings, TTS, Whisper, moderation,
    /// …). Offering those in pickers produced selections that silently failed,
    /// so they are excluded here. Image-generation models stay: chat routes
    /// them to the images endpoint.
    private static func conversationalRemoteModelIDs(for connection: RemoteConnection) -> [String] {
        remoteModelIDs(for: connection, scope: .unfiltered)
    }

    private static func remoteModelIDs(
        for connection: RemoteConnection,
        scope: PickerScope
    ) -> [String] {
        var models = connection.availableModels.isEmpty
            ? [connection.trimmedModel].filter { !$0.isEmpty }
            : connection.availableModels
        if OpenAIRequestCodec.isOfficialOpenAIHost(connection.trimmedBaseURL) {
            for bundled in ModelCapabilityCatalog.bundledOpenAIModelIDs where !models.contains(bundled) {
                models.append(bundled)
            }
        }
        if OpenAIRequestCodec.isXAIHost(connection.trimmedBaseURL) {
            let bundled = ModelCapabilityCatalog.bundledXAIChatModelIDs
                + ModelCapabilityCatalog.bundledXAIImageModelIDs
            for id in bundled where !models.contains(id) {
                models.append(id)
            }
        }
        let usable = models.filter { !$0.isEmpty && !OpenAICompatibleAPI.isNonConversationalModel($0) }
        switch scope {
        case .imageOnly:
            return usable.filter { ModelCapabilityCatalog.isImageGenerationModel($0) }
        case .unfiltered:
            return usable
        case .chatRecent:
            let chat = usable.filter { ModelCapabilityCatalog.isChatModel($0) }
            let descriptors = chat.map { id in
                RemoteModelDescriptor(id: id, created: connection.modelCreatedAt?[id])
            }
            return ModelCapabilityCatalog.newestChatModels(descriptors, limit: 10)
        }
    }

    private static func remoteProviderLabel(for connection: RemoteConnection) -> String {
        "\(connection.trimmedName) · \(connection.encoding.displayName)"
    }

    /// Best-guess backend for a bare model id when none was specified.
    ///
    /// Prefers an exact known choice, then treats catalog ids as local MLX, then
    /// assumes remote if a provider is configured, finally `.auto`.
    public static func inferredBackend(
        for modelID: String,
        providerSettings: ProviderSettings
    ) -> LLMBackendPreference {
        if let choice = choice(for: modelID, providerSettings: providerSettings) {
            return choice.backend
        }
        if OnDeviceLanguageModelSupport.shouldOfferAppleFoundation,
           modelID == AppleFoundationModel.modelID {
            return .appleFoundation
        }
        if OnDeviceLanguageModelSupport.shouldOfferLocalMLX,
           LLMModelCatalog.option(for: modelID) != nil {
            return .localMLX
        }
        if providerSettings.isRemoteConfigured {
            return .remote
        }
        return .auto
    }
}

/// Resolves a (model id, backend) request into concrete service state and loads it.
///
/// Centralizes the policy for how a requested model maps onto an actual backend
/// and model id, including the `.auto` fallback behavior, so chat/research/compare
/// all prepare models consistently.
@MainActor
public enum LLMModelPreparer {
    /// Loads the requested model, retrying once with `.auto` if a pinned backend fails.
    ///
    /// Gives the user's explicit choice priority but still degrades gracefully
    /// (e.g. remote unreachable → fall back to local/mock via `.auto`).
    public static func prepareWithFallback(
        llmService: any LLMServiceProtocol,
        providerSettings: ProviderSettings,
        modelID: String,
        backend: LLMBackendPreference,
        connectionID: String? = nil
    ) async throws {
        do {
            try await prepare(
                llmService: llmService,
                providerSettings: providerSettings,
                modelID: modelID,
                backend: backend,
                connectionID: connectionID
            )
        } catch {
            guard backend != .auto else { throw error }
            try await prepare(
                llmService: llmService,
                providerSettings: providerSettings,
                modelID: modelID,
                backend: .auto,
                connectionID: connectionID
            )
        }
    }

    /// Resolves the request to concrete backend+model, applies it to the service, and loads it.
    ///
    /// For composite services it sets `backendPreference` so the right sub-backend
    /// is selected; for simple services it only sets the model id.
    public static func prepare(
        llmService: any LLMServiceProtocol,
        providerSettings: ProviderSettings,
        modelID: String,
        backend: LLMBackendPreference,
        connectionID: String? = nil
    ) async throws {
        let resolvedBackend = resolveBackend(
            requested: backend,
            modelID: modelID,
            providerSettings: providerSettings
        )
        let resolvedModelID = resolveModelID(
            modelID: modelID,
            backend: resolvedBackend,
            providerSettings: providerSettings,
            connectionID: connectionID
        )
        let resolvedConnectionID = resolveConnectionID(
            backend: resolvedBackend,
            connectionID: connectionID,
            providerSettings: providerSettings
        )

        if let remoteCapable = llmService as? RemoteLLMCapable {
            if resolvedBackend == .remote {
                remoteCapable.setActiveConnection(id: resolvedConnectionID, modelID: resolvedModelID)
            } else {
                remoteCapable.setActiveConnection(id: nil, modelID: nil)
            }
        }

        if let selectable = llmService as? any LLMBackendSelectable {
            selectable.backendPreference = resolvedBackend
            selectable.selectedModelID = resolvedModelID
            if let connectionSelectable = llmService as? any RemoteConnectionSelectable {
                connectionSelectable.selectedRemoteConnectionID =
                    resolvedBackend == .remote ? resolvedConnectionID : nil
            }
        } else {
            llmService.selectedModelID = resolvedModelID
        }

        try await llmService.loadSelectedModel()
    }

    /// Concretizes a backend: explicit choices pass through; `.auto` is inferred from the model id and settings.
    private static func resolveBackend(
        requested: LLMBackendPreference,
        modelID: String,
        providerSettings: ProviderSettings
    ) -> LLMBackendPreference {
        switch requested {
        case .remote, .localMLX, .appleFoundation:
            return requested
        case .auto:
            return ConfiguredModelRegistry.inferredBackend(
                for: modelID,
                providerSettings: providerSettings
            )
        }
    }

    /// Picks the model id to actually load for a backend.
    ///
    /// For remote, a non-catalog id is used as-is, but a local catalog id is
    /// swapped for the configured remote model (since the local id is meaningless
    /// to a remote provider). Local/auto use the id unchanged.
    private static func resolveModelID(
        modelID: String,
        backend: LLMBackendPreference,
        providerSettings: ProviderSettings,
        connectionID: String?
    ) -> String {
        switch backend {
        case .remote:
            if LLMModelCatalog.option(for: modelID) == nil,
               modelID != AppleFoundationModel.modelID {
                return modelID
            }
            if let connectionID, let connection = providerSettings.connection(id: connectionID) {
                return connection.trimmedModel
            }
            return providerSettings.resolvedConnection()?.trimmedModel ?? modelID
        case .localMLX, .appleFoundation, .auto:
            return modelID
        }
    }

    private static func resolveConnectionID(
        backend: LLMBackendPreference,
        connectionID: String?,
        providerSettings: ProviderSettings
    ) -> String? {
        guard backend == .remote else { return nil }
        if let connectionID, providerSettings.connection(id: connectionID) != nil {
            return connectionID
        }
        return providerSettings.resolvedConnection()?.id
    }
}

extension LLMBackendPreference {
    /// Loads a backend preference from an arbitrary key, returning `defaultValue` when missing/invalid.
    public static func loadStored(
        defaults: UserDefaults,
        key: String,
        defaultValue: LLMBackendPreference
    ) -> LLMBackendPreference {
        guard let raw = defaults.string(forKey: key),
              let value = LLMBackendPreference(rawValue: raw) else {
            return defaultValue
        }
        return value
    }

    /// Stores this preference under an arbitrary key.
    public func store(defaults: UserDefaults, key: String) {
        defaults.set(rawValue, forKey: key)
    }
}
