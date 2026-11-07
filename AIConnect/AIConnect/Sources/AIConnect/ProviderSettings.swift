// SPDX-License-Identifier: MIT
import Foundation
import AIModelOptions

/// Remote LLM provider credentials: connection metadata in UserDefaults, API keys in Keychain.
@MainActor
public final class ProviderSettings: ObservableObject {
    public static let shared = ProviderSettings()

    private enum Keys {
        static let connections = "anaiodyssey.remote.connections"
        static let apiBaseURL = "anaiodyssey.remote.apiBaseURL"
        static let remoteModel = "anaiodyssey.remote.model"
        static let remoteAvailableModels = "anaiodyssey.remote.availableModels"
    }

    public static let defaultBaseURL = OpenAICompatibleAPI.defaultBaseURL
    public static let defaultRemoteModel = OpenAICompatibleAPI.defaultRemoteModel
    nonisolated public static let defaultGeminiBaseURL = "https://generativelanguage.googleapis.com/v1beta/openai"
    nonisolated public static let defaultGeminiModel = "gemini-2.0-flash"

    @Published public var remoteConnections: [RemoteConnection] {
        didSet { schedulePersistConnections() }
    }

    @Published public var apiBaseURL: String {
        didSet {
            UserDefaults.standard.set(apiBaseURL, forKey: Keys.apiBaseURL)
            syncLegacyFieldsToFirstConnection()
        }
    }

    @Published public var apiKey: String {
        didSet {
            syncLegacyFieldsToFirstConnection()
            schedulePersistConnections()
        }
    }

    @Published public var remoteModel: String {
        didSet {
            UserDefaults.standard.set(remoteModel, forKey: Keys.remoteModel)
            syncLegacyFieldsToFirstConnection()
        }
    }

    @Published public var remoteAvailableModels: [String] {
        didSet {
            UserDefaults.standard.set(remoteAvailableModels, forKey: Keys.remoteAvailableModels)
            syncLegacyFieldsToFirstConnection()
        }
    }

    private let defaults: UserDefaults
    private let apiKeyStore: RemoteAPIKeyStore
    private var cloudSyncObserver: NSObjectProtocol?
    private var persistDebounceTask: Task<Void, Never>?

    public init(defaults: UserDefaults = .standard, apiKeyStore: RemoteAPIKeyStore = RemoteAPIKeyStore()) {
        self.defaults = defaults
        self.apiKeyStore = apiKeyStore
        apiKeyStore.migrateLegacyKeysIfNeeded()

        let loadedBaseURL = defaults.string(forKey: Keys.apiBaseURL) ?? Self.defaultBaseURL
        let loadedModel = defaults.string(forKey: Keys.remoteModel) ?? Self.defaultRemoteModel
        let loadedModels = defaults.stringArray(forKey: Keys.remoteAvailableModels) ?? []

        let loadedConnections: [RemoteConnection]
        var needsPersist = defaults.data(forKey: Keys.connections) == nil
        if let data = defaults.data(forKey: Keys.connections),
           let decoded = try? JSONDecoder().decode([RemoteConnection].self, from: data) {
            let hydrated = Self.hydrateAPIKeys(decoded, store: apiKeyStore)
            let migrated = RemoteConnection.migrateToolFormat(hydrated)
            loadedConnections = migrated
            needsPersist = migrated != hydrated
        } else {
            loadedConnections = RemoteConnection.migrateToolFormat(
                Self.migrateLegacyConnection(
                    apiBaseURL: loadedBaseURL,
                    apiKey: apiKeyStore.apiKey(for: "legacy-remote"),
                    remoteModel: loadedModel,
                    availableModels: loadedModels
                )
            )
            needsPersist = !loadedConnections.isEmpty
        }

        remoteConnections = loadedConnections

        apiBaseURL = loadedBaseURL
        apiKey = loadedConnections.first.map { apiKeyStore.apiKey(for: $0.id) } ?? ""
        remoteModel = loadedModel
        remoteAvailableModels = loadedModels

        if needsPersist, !loadedConnections.isEmpty {
            persistConnections()
        }

        observeCloudSync()
    }

    deinit {
        if let cloudSyncObserver {
            NotificationCenter.default.removeObserver(cloudSyncObserver)
        }
        persistDebounceTask?.cancel()
    }

    private static func hydrateAPIKeys(_ connections: [RemoteConnection], store: RemoteAPIKeyStore) -> [RemoteConnection] {
        connections.map { connection in
            var copy = connection
            copy.apiKey = store.apiKey(for: connection.id)
            return copy
        }
    }

    private func observeCloudSync() {
        cloudSyncObserver = NotificationCenter.default.addObserver(
            forName: AIConnectSync.settingsChangedExternally,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadFromDefaults() }
        }
    }

    private func reloadFromDefaults() {
        apiKeyStore.migrateLegacyKeysIfNeeded()
        if let data = defaults.data(forKey: Keys.connections),
           let decoded = try? JSONDecoder().decode([RemoteConnection].self, from: data) {
            let hydrated = RemoteConnection.migrateToolFormat(Self.hydrateAPIKeys(decoded, store: apiKeyStore))
            if hydrated != remoteConnections { remoteConnections = hydrated }
        }
        let newBaseURL = defaults.string(forKey: Keys.apiBaseURL) ?? Self.defaultBaseURL
        if newBaseURL != apiBaseURL { apiBaseURL = newBaseURL }
        let newKey = remoteConnections.first.map { apiKeyStore.apiKey(for: $0.id) } ?? ""
        if newKey != apiKey { apiKey = newKey }
        let newModel = defaults.string(forKey: Keys.remoteModel) ?? Self.defaultRemoteModel
        if newModel != remoteModel { remoteModel = newModel }
        let newModels = defaults.stringArray(forKey: Keys.remoteAvailableModels) ?? []
        if newModels != remoteAvailableModels { remoteAvailableModels = newModels }
    }

    private func schedulePersistConnections() {
        persistDebounceTask?.cancel()
        persistDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            persistConnections()
        }
    }

    private func persistConnections() {
        for connection in remoteConnections {
            apiKeyStore.setAPIKey(connection.apiKey, for: connection.id)
        }
        var stripped = remoteConnections
        for index in stripped.indices {
            stripped[index].apiKey = ""
        }
        if let data = try? JSONEncoder().encode(stripped) {
            defaults.set(data, forKey: Keys.connections)
        }
        syncFirstConnectionToLegacyFields()
    }

    private func syncFirstConnectionToLegacyFields() {
        guard let first = remoteConnections.first else { return }
        if apiBaseURL != first.apiBaseURL { apiBaseURL = first.apiBaseURL }
        let storedKey = apiKeyStore.apiKey(for: first.id)
        if apiKey != storedKey { apiKey = storedKey }
        if remoteModel != first.defaultModel { remoteModel = first.defaultModel }
        if remoteAvailableModels != first.availableModels { remoteAvailableModels = first.availableModels }
    }

    private func syncLegacyFieldsToFirstConnection() {
        guard !remoteConnections.isEmpty else { return }
        var first = remoteConnections[0]
        first.apiBaseURL = apiBaseURL
        first.apiKey = apiKey
        first.defaultModel = remoteModel
        first.availableModels = remoteAvailableModels
        remoteConnections[0] = first
        apiKeyStore.setAPIKey(apiKey, for: first.id)
    }

    private static func migrateLegacyConnection(
        apiBaseURL: String,
        apiKey: String,
        remoteModel: String,
        availableModels: [String]
    ) -> [RemoteConnection] {
        let trimmedURL = apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { return [] }

        let encoding: RemoteProtocolEncoding
        if trimmedURL.contains("generativelanguage.googleapis.com") {
            encoding = .geminiOpenAI
        } else if trimmedURL.lowercased().contains("lmstudio") {
            encoding = .automatic
        } else if trimmedURL.hasSuffix("/api") {
            encoding = .ollamaNative
        } else {
            encoding = .openAIChatCompletions
        }

        return [
            RemoteConnection(
                id: "legacy-remote",
                name: (encoding == .automatic || encoding == .lmStudioHarmony) ? "LM Studio" : "Remote API",
                apiBaseURL: trimmedURL,
                apiKey: apiKey,
                defaultModel: remoteModel,
                availableModels: availableModels,
                encoding: encoding
            ),
        ]
    }

    /// API-key connection on the same host as a subscription sign-in, used when
    /// the plan can't serve a request (for example ChatGPT Free, or a Grok tier
    /// without API access).
    public func apiKeyFallbackConnection(for connection: RemoteConnection) -> RemoteConnection? {
        let host = URL(string: connection.trimmedBaseURL)?.host?.lowercased()
        return remoteConnections.first { candidate in
            candidate.id != connection.id
                && candidate.isEnabled
                && !candidate.usesChatGPTAccount
                && !candidate.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && URL(string: candidate.trimmedBaseURL)?.host?.lowercased() == host
        }
    }

    /// Official OpenAI remote with an API key (not Sign in with ChatGPT alone).
    public func openAITTSConnection() -> RemoteConnection? {
        remoteConnections.first { connection in
            connection.isEnabled
                && OpenAIRequestCodec.isOfficialOpenAIHost(connection.trimmedBaseURL)
                && !connection.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// xAI remote with an API key, used for Grok TTS.
    public func xAITTSConnection() -> RemoteConnection? {
        remoteConnections.first { connection in
            connection.isEnabled
                && OpenAIRequestCodec.isXAIHost(connection.trimmedBaseURL)
                && !connection.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    public var hasConfiguredOpenAITTSKey: Bool { openAITTSConnection() != nil }
    public var hasConfiguredXAITTSKey: Bool { xAITTSConnection() != nil }

    public var isRemoteConfigured: Bool {
        remoteConnections.contains { connection in
            connection.isEnabled && adapter(for: connection).isConfigured(connection: connection)
        }
    }

    public var configurationHint: String {
        guard let connection = remoteConnections.first(where: { $0.isEnabled }) else {
            return "Add a remote connection in Settings."
        }
        return adapter(for: connection).configurationHint(connection: connection)
    }

    public var normalizedBaseURL: String {
        OpenAICompatibleAPI.normalizeBaseURL(apiBaseURL)
    }

    public var chatCompletionsURL: URL? {
        guard let connection = remoteConnections.first else { return nil }
        return adapter(for: connection).buildChatURL(baseURL: connection.trimmedBaseURL)
    }

    public var modelsURL: URL? {
        guard let connection = remoteConnections.first else { return nil }
        return adapter(for: connection).buildModelsURL(baseURL: connection.trimmedBaseURL)
    }

    public var resolvedEndpointDescription: String {
        chatCompletionsURL?.absoluteString ?? "Invalid URL"
    }

    public func connection(id: String) -> RemoteConnection? {
        remoteConnections.first { $0.id == id }
    }

    public func updateConnection(_ connection: RemoteConnection) {
        apiKeyStore.setAPIKey(connection.apiKey, for: connection.id)
        if let index = remoteConnections.firstIndex(where: { $0.id == connection.id }) {
            var connection = connection
            // A new URL can be a different server: forget what the old one said it was.
            if RemoteConnection.detectionKey(remoteConnections[index].trimmedBaseURL)
                != RemoteConnection.detectionKey(connection.trimmedBaseURL) {
                connection.clearServerDetection()
            }
            remoteConnections[index] = connection
        } else {
            remoteConnections.append(connection)
        }
    }

    public func removeConnection(id: String) {
        apiKeyStore.removeAPIKey(for: id)
        ModelGenerationSettings.removeOptions(connectionID: id)
        ToolCallVerificationStore(defaults: defaults).clear(connectionID: id)
        remoteConnections.removeAll { $0.id == id }
        if remoteConnections.isEmpty {
            clearLegacyRemoteFields()
        }
    }

    private func clearLegacyRemoteFields() {
        apiBaseURL = Self.defaultBaseURL
        apiKey = ""
        remoteModel = Self.defaultRemoteModel
        remoteAvailableModels = []
    }

    public func adapter(for connection: RemoteConnection) -> RemoteLLMProtocolAdapter {
        adapter(for: connection, modelID: connection.trimmedModel)
    }

    public func adapter(for connection: RemoteConnection, modelID: String) -> RemoteLLMProtocolAdapter {
        RemoteProtocolAdapterRegistry.adapter(for: connection.resolvedEncoding(forModel: modelID))
    }

    public func adapter(for encoding: RemoteProtocolEncoding) -> RemoteLLMProtocolAdapter {
        RemoteProtocolAdapterRegistry.adapter(for: encoding)
    }

    public func enabledConnections() -> [RemoteConnection] {
        remoteConnections.filter { connection in
            connection.isEnabled
                && adapter(for: connection).isConfigured(connection: connection)
        }
    }

    public func resolvedConnection(preferredConnectionID: String? = nil) -> RemoteConnection? {
        if let preferredConnectionID,
           let preferred = connection(id: preferredConnectionID),
           preferred.isEnabled,
           adapter(for: preferred).isConfigured(connection: preferred) {
            return preferred
        }
        return enabledConnections().first
    }

    public func applyGeminiPreset(apiKey: String, model: String? = nil) {
        let preset = RemoteConnection.geminiPreset(apiKey: apiKey, model: model)
        if let index = remoteConnections.firstIndex(where: { $0.encoding == .geminiOpenAI }) {
            var existing = remoteConnections[index]
            existing.apiKey = apiKey
            if let model { existing.defaultModel = model }
            remoteConnections[index] = existing
        } else {
            remoteConnections.append(preset)
        }
    }

    public func addPresetOpenAI() {
        remoteConnections.append(.openAIPreset())
    }

    public func addPresetGemini() {
        remoteConnections.append(.geminiPreset())
    }

    public func addPresetLMStudio() {
        remoteConnections.append(.lmStudioPreset())
    }

    public func addPresetXAI() {
        remoteConnections.append(.xAIPreset())
    }

    public func addPresetAnthropic() {
        remoteConnections.append(.anthropicPreset())
    }
}
