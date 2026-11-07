// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import MLXLLM
import MLXLMCommon
import AnAIOdysseyAI
import AIModelOptions

/// On-device LLM backend powered by Apple's MLX runtime (mlx-swift-lm).
@MainActor
public final class MLXLLMService: LLMServiceProtocol {
    public var selectedModelID: String = LLMModelCatalog.defaultModelID
    public private(set) var isModelLoaded = false
    public private(set) var loadProgress: Double?
    public var loadStatus = "MLX not loaded"
    public let usesMLXBackend = true
    public var loadedLocalModelID: String? { isModelLoaded ? selectedModelID : nil }
    public var loadingLocalModelID: String? {
        (!isModelLoaded && loadProgress != nil) ? selectedModelID : nil
    }

    private var modelContainer: MLXLMCommon.ModelContainer?

    public init() {}

    public func availableModels() -> [LLMModelOption] {
        LLMModelCatalog.models
    }

    public func loadSelectedModel() async throws {
        guard let option = LLMModelCatalog.option(for: selectedModelID) else {
            throw LLMServiceError.modelNotSupported(selectedModelID)
        }

        guard ModelCatalogService.canRun(option) else {
            throw LLMServiceError.insufficientMemory(
                requiredGB: option.estimatedMemoryGB,
                availableGB: ModelCatalogService.memoryBudgetGB()
            )
        }

        guard MLXModelCatalog.isDownloaded(selectedModelID) else {
            throw LLMServiceError.modelNotDownloaded(selectedModelID)
        }

        loadStatus = "Loading \(option.displayName)..."
        loadProgress = 0
        isModelLoaded = false
        modelContainer = nil

        // Directory-based configuration: mlx-swift-lm must not call Hub.snapshot.
        let configuration = try MLXModelCatalog.localLoadConfiguration(for: selectedModelID)
        let container = try await LLMModelFactory.shared.loadContainer(
            hub: MLXModelCatalog.hub,
            configuration: configuration
        ) { progress in
            Task { @MainActor in
                self.loadProgress = progress.fractionCompleted
            }
        }

        modelContainer = container
        isModelLoaded = true
        loadProgress = nil
        loadStatus = "Loaded"
    }

    public func unloadLocalModel(_ modelID: String) {
        guard selectedModelID == modelID || loadedLocalModelID == modelID else { return }
        modelContainer = nil
        isModelLoaded = false
        loadProgress = nil
        loadStatus = "MLX not loaded"
    }

    public func streamResponse(to prompt: String, history: [LLMChatTurn]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let modelContainer else {
                        throw LLMServiceError.modelNotLoaded
                    }

                    let settings = AgentGenerationSettings()
                    let chat: [Chat.Message] = history.map { turn in
                        switch turn.role {
                        case "assistant":
                            return .assistant(turn.content)
                        case "system":
                            return .system(turn.content)
                        default:
                            return .user(turn.content)
                        }
                    }
                    let userInput = UserInput(chat: chat + [.user(prompt)])
                    let prepared = try await modelContainer.prepare(input: userInput)
                    let stream = try await modelContainer.generate(
                        input: prepared,
                        parameters: GenerateParameters(
                            maxTokens: settings.maxTokens,
                            temperature: Float(settings.temperature)
                        )
                    )

                    for try await event in stream {
                        try Task.checkCancellation()
                        switch event {
                        case .chunk(let text):
                            continuation.yield(text)
                        case .toolCall, .info:
                            break
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Prefers on-device backends (MLX, then Apple Foundation), then remote, then mock.
@MainActor
public final class CompositeLLMService: RemoteConnectionSelectable, RemoteLLMCapable, AgentRemoteLLMProviding {
    private let mlxService = MLXLLMService()
    private let appleFoundationService = AppleFoundationLLMService()
    private let remoteService: RemoteLLMService
    private let mockService = MockLLMService()
    private let settings: ProviderSettings
    private let agentSettings: AgentRegistrySettings?
    private let preferMLX: Bool
    private let preferAppleFoundation: Bool
    private var active: LLMServiceProtocol

    public var backendPreference: LLMBackendPreference = LLMBackendPreference.loadStored() {
        didSet { backendPreference.store() }
    }

    public var selectedRemoteConnectionID: String?

    public var isRemoteAvailable: Bool { settings.isRemoteConfigured }

    public var activeBackendLabel: String {
        if active === remoteService { return "Remote" }
        if active === mlxService { return "MLX" }
        if active === appleFoundationService { return "Apple On-Device" }
        return "Mock"
    }

    public var selectedModelID: String {
        get { active.selectedModelID }
        set {
            mlxService.selectedModelID = newValue
            appleFoundationService.selectedModelID = newValue
            mockService.selectedModelID = newValue
            if backendPreference == .remote {
                remoteService.selectedModelID = newValue
            }
        }
    }

    public var isModelLoaded: Bool { active.isModelLoaded }
    public var loadProgress: Double? { active.loadProgress }
    public var loadStatus: String { active.loadStatus }
    public var usesMLXBackend: Bool { active.usesMLXBackend }
    public var loadedLocalModelID: String? { mlxService.loadedLocalModelID }
    public var loadingLocalModelID: String? { mlxService.loadingLocalModelID }

    public var activeConnectionID: String? {
        shouldExposeRemoteAdapter ? remoteService.activeConnectionID : nil
    }
    public var activeProtocolAdapter: RemoteLLMProtocolAdapter? {
        shouldExposeRemoteAdapter ? remoteService.activeProtocolAdapter : nil
    }

    public func setActiveConnection(id: String?, modelID: String?) {
        remoteService.setActiveConnection(id: id, modelID: modelID)
    }

    public init(
        settings: ProviderSettings,
        agentSettings: AgentRegistrySettings? = nil,
        preferMLX: Bool = true,
        preferAppleFoundation: Bool = false
    ) {
        self.settings = settings
        self.agentSettings = agentSettings
        self.preferMLX = preferMLX
        self.preferAppleFoundation = preferAppleFoundation
        self.remoteService = RemoteLLMService(settings: settings)
        if preferMLX {
            active = mlxService
        } else if preferAppleFoundation {
            active = appleFoundationService
        } else {
            active = mockService
        }
    }

    public convenience init(preferMLX: Bool = true, preferAppleFoundation: Bool = false) {
        self.init(
            settings: ProviderSettings.shared,
            preferMLX: preferMLX,
            preferAppleFoundation: preferAppleFoundation
        )
    }

    public func availableModels() -> [LLMModelOption] {
        switch backendPreference {
        case .remote where settings.isRemoteConfigured:
            return remoteService.availableModels()
        case .localMLX:
            return mlxService.availableModels()
        case .appleFoundation:
            return appleFoundationService.availableModels()
        default:
            var models: [LLMModelOption] = []
            if preferAppleFoundation {
                models.append(contentsOf: appleFoundationService.availableModels())
            }
            if preferMLX {
                models.append(contentsOf: mlxService.availableModels())
            }
            if settings.isRemoteConfigured {
                models.append(contentsOf: remoteService.availableModels())
            }
            return models
        }
    }

    public func loadSelectedModel() async throws {
        switch backendPreference {
        case .remote:
            guard let connection = resolveRemoteConnection() else {
                throw LLMServiceError.generationFailed("Configure a remote connection in Settings.")
            }
            remoteService.activate(
                connection: connection,
                modelID: selectedModelID.isEmpty ? nil : selectedModelID
            )
            try await remoteService.loadSelectedModel()
            active = remoteService
            return
        case .localMLX:
            try await mlxService.loadSelectedModel()
            active = mlxService
            return
        case .appleFoundation:
            try await appleFoundationService.loadSelectedModel()
            active = appleFoundationService
            return
        case .auto:
            try await loadWithAutomaticFallback()
        }
    }

    public func streamResponse(to prompt: String, history: [LLMChatTurn]) -> AsyncThrowingStream<String, Error> {
        active.streamResponse(to: prompt, history: history)
    }

    public func unloadLocalModel(_ modelID: String) {
        mlxService.unloadLocalModel(modelID)
    }

    /// Exposes the underlying remote service for structured agent rounds
    /// (image generation still needs this when chat is on MLX).
    public var remoteServiceForAgent: RemoteLLMService { remoteService }

    /// Remote adapters stay silent while a local backend is selected so chat
    /// cannot send Llama ids to OpenAI-compatible HTTP.
    private var shouldExposeRemoteAdapter: Bool {
        LocalModelDownloadPolicy.shouldUseRemoteHTTPAgent(
            backendRawValue: backendPreference.rawValue,
            activeBackendLabel: activeBackendLabel
        )
    }

    private func resolveRemoteConnection() -> RemoteConnection? {
        settings.resolvedConnection(
            preferredConnectionID: selectedRemoteConnectionID
        )
    }

    private func loadWithAutomaticFallback() async throws {
        var failures: [String] = []

        if preferMLX {
            do {
                try await mlxService.loadSelectedModel()
                active = mlxService
                return
            } catch {
                failures.append("MLX: \(error.localizedDescription)")
            }
        }

        if preferAppleFoundation {
            do {
                try await appleFoundationService.loadSelectedModel()
                active = appleFoundationService
                return
            } catch {
                failures.append("Apple: \(error.localizedDescription)")
            }
        }

        if let connection = resolveRemoteConnection() {
            do {
                let modelID = selectedModelID.isEmpty ? nil : selectedModelID
                remoteService.activate(
                    connection: connection,
                    modelID: modelID ?? (connection.trimmedModel.isEmpty ? nil : connection.trimmedModel)
                )
                try await remoteService.loadSelectedModel()
                active = remoteService
                if !failures.isEmpty {
                    remoteService.loadStatus += " (fallback)"
                }
                return
            } catch {
                failures.append("Remote: \(error.localizedDescription)")
            }
        }

        try await mockService.loadSelectedModel()
        mockService.loadStatus = failures.isEmpty
            ? "Mock backend ready"
            : "Mock fallback — \(failures.joined(separator: "; "))"
        active = mockService
    }
}
