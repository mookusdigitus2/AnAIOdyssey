// SPDX-License-Identifier: MIT
import Foundation
import AIModelOptions

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Identifiers for Apple's on-device model picker row.
public enum AppleFoundationModel {
    public static let modelID = ModelCapabilityCatalog.appleFoundationModelID
    public static let displayName = LocalOnDevicePolicy.appleOnDevicePickerLabel
    public static let providerLabel = LocalOnDevicePolicy.appleOnDevicePickerLabel

    public static var option: LLMModelOption {
        LLMModelOption(id: modelID, displayName: displayName, estimatedMemoryGB: 0)
    }

    public static var choice: ConfiguredModelChoice {
        ConfiguredModelChoice(
            id: modelID,
            displayName: displayName,
            backend: .appleFoundation,
            providerLabel: providerLabel
        )
    }
}

/// Chat backend for `SystemLanguageModel` on Apple Intelligence devices.
@MainActor
public final class AppleFoundationLLMService: LLMServiceProtocol {
    public var selectedModelID: String = AppleFoundationModel.modelID
    public private(set) var isModelLoaded = false
    public private(set) var loadProgress: Double?
    public var loadStatus = "Apple On-Device not loaded"
    public let usesMLXBackend = false

    public init() {}

    public func availableModels() -> [LLMModelOption] {
        [AppleFoundationModel.option]
    }

    public func loadSelectedModel() async throws {
        switch OnDeviceLanguageModelSupport.appleFoundationAvailability {
        case .available:
            isModelLoaded = true
            loadProgress = nil
            loadStatus = "\(AppleFoundationModel.displayName) ready"
        case .appleIntelligenceNotEnabled:
            isModelLoaded = false
            throw LLMServiceError.generationFailed(
                LocalOnDevicePolicy.appleFoundationUserMessage(.appleIntelligenceNotEnabled)
            )
        case .modelNotReady:
            isModelLoaded = false
            throw LLMServiceError.generationFailed(
                LocalOnDevicePolicy.appleFoundationUserMessage(.modelNotReady)
            )
        case .deviceNotEligible:
            isModelLoaded = false
            throw LLMServiceError.generationFailed(
                LocalOnDevicePolicy.appleFoundationUserMessage(.deviceNotEligible)
            )
        case .unsupportedOS:
            isModelLoaded = false
            throw LLMServiceError.generationFailed(
                LocalOnDevicePolicy.appleFoundationUserMessage(.unsupportedOS)
            )
        }
    }

    public func streamResponse(to prompt: String, history: [LLMChatTurn]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    guard isModelLoaded else {
                        throw LLMServiceError.modelNotLoaded
                    }
                    #if canImport(FoundationModels)
                    if #available(iOS 26.0, macOS 26.0, *) {
                        try await Self.streamFoundationResponse(
                            prompt: prompt,
                            history: history,
                            continuation: continuation
                        )
                    } else {
                        throw LLMServiceError.generationFailed(
                            LocalOnDevicePolicy.appleFoundationUserMessage(.unsupportedOS)
                        )
                    }
                    #else
                    throw LLMServiceError.generationFailed(
                        LocalOnDevicePolicy.appleFoundationUserMessage(.unsupportedOS)
                    )
                    #endif
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

    #if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, *)
    private static func streamFoundationResponse(
        prompt: String,
        history: [LLMChatTurn],
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        let composed = compose(prompt: prompt, history: history)
        let session: LanguageModelSession
        if let instructions = composed.instructions, !instructions.isEmpty {
            session = LanguageModelSession(instructions: instructions)
        } else {
            session = LanguageModelSession()
        }
        var previous = ""
        let stream = session.streamResponse(to: composed.userPrompt)
        for try await snapshot in stream {
            try Task.checkCancellation()
            let current = snapshot.content
            if current.hasPrefix(previous) {
                let delta = String(current.dropFirst(previous.count))
                if !delta.isEmpty {
                    continuation.yield(delta)
                }
            } else if !current.isEmpty {
                continuation.yield(current)
            }
            previous = current
        }
    }
    #endif

    private static func compose(
        prompt: String,
        history: [LLMChatTurn]
    ) -> (instructions: String?, userPrompt: String) {
        let system = history
            .filter { $0.role == "system" }
            .map(\.content)
            .joined(separator: "\n")
        let dialogue = history
            .filter { $0.role != "system" }
            .map { "\($0.role): \($0.content)" }
            .joined(separator: "\n")
        let userPrompt: String
        if dialogue.isEmpty {
            userPrompt = prompt
        } else {
            userPrompt = dialogue + "\nuser: \(prompt)"
        }
        return (system.isEmpty ? nil : system, userPrompt)
    }
}
