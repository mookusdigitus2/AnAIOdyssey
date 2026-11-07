// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import XCTest
import AnAIOdysseyAI
import AnAIOdysseyMLX

@MainActor
final class LLMServiceTests: XCTestCase {
    func testLLMServiceMockStreaming() async throws {
        let service = MockLLMService()
        try await service.loadSelectedModel()

        var tokens = ""
        let stream = service.streamResponse(to: "Hello", history: [])
        for try await chunk in stream {
            tokens += chunk
        }
        XCTAssertFalse(tokens.isEmpty)
        XCTAssertTrue(tokens.contains("Hello"))
    }

    func testModelCachePathExists() {
        AnAIOdysseyAI.ensureModelCacheDirectoryExists()
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: AnAIOdysseyAI.modelCacheDirectory.path,
            isDirectory: &isDirectory
        )
        XCTAssertTrue(exists)
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testAppleFoundationLoadReportsAvailability() async {
        let service = AppleFoundationLLMService()
        do {
            try await service.loadSelectedModel()
            XCTAssertTrue(service.isModelLoaded)
            XCTAssertEqual(OnDeviceLanguageModelSupport.appleFoundationAvailability, .available)
        } catch {
            XCTAssertFalse(service.isModelLoaded)
            XCTAssertNotEqual(OnDeviceLanguageModelSupport.appleFoundationAvailability, .available)
            XCTAssertTrue(error is LLMServiceError)
        }
    }

    func testAppleFoundationChoiceIsOnDevice() {
        XCTAssertEqual(AppleFoundationModel.choice.backend, .appleFoundation)
        XCTAssertEqual(AppleFoundationModel.choice.id, "apple_foundation")
        XCTAssertEqual(AppleFoundationModel.choice.displayName, "Apple On-Device")
        XCTAssertEqual(AppleFoundationModel.choice.pickerLabel, "Apple On-Device")
        XCTAssertEqual(AppleFoundationModel.choice.backend.title, "Apple On-Device")
        XCTAssertTrue(AppleFoundationModel.choice.backend.isOnDevice)
    }

    func testMLXMemoryGuard() async {
        let service = MLXLLMService()
        service.selectedModelID = "nonexistent-model"
        do {
            try await service.loadSelectedModel()
            XCTFail("Expected unsupported model error")
        } catch {
            XCTAssertTrue(error is LLMServiceError)
        }
    }

    func testMLXLoadAndGenerate() async throws {
        guard ProcessInfo.processInfo.environment["MLX_DEVICE_TESTS"] == "1" else {
            throw XCTSkip("MLX device integration tests require MLX_DEVICE_TESTS=1")
        }

        let service = MLXLLMService()
        service.selectedModelID = "llama3_2_1B_4bit"
        try await service.loadSelectedModel()

        var output = ""
        let stream = service.streamResponse(to: "Say hi in one sentence.", history: [])
        for try await chunk in stream {
            output += chunk
        }
        XCTAssertFalse(output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func testRefreshAllConnectionModelsPreservesCachedModelsOnFailure() async {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defer { defaults.removePersistentDomain(forName: defaults.description) }

        let settings = ProviderSettings(defaults: defaults)
        settings.remoteConnections = [
            RemoteConnection(
                id: "offline",
                name: "Offline",
                apiBaseURL: "http://127.0.0.1:9",
                apiKey: "test-key",
                defaultModel: "model-a",
                availableModels: ["cached-model"],
                encoding: .openAIChatCompletions
            ),
        ]

        let service = RemoteLLMService(settings: settings)
        await service.refreshAllConnectionModels()

        XCTAssertEqual(settings.remoteConnections.first?.availableModels, ["cached-model"])
    }

    func testLoadSelectedModelUsesPersistedModelsWhenQueryFails() async throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defer { defaults.removePersistentDomain(forName: defaults.description) }

        let settings = ProviderSettings(defaults: defaults)
        settings.remoteConnections = [
            RemoteConnection(
                id: "offline",
                name: "Offline",
                apiBaseURL: "http://127.0.0.1:9",
                apiKey: "test-key",
                defaultModel: "model-a",
                availableModels: ["cached-model"],
                encoding: .openAIChatCompletions
            ),
        ]

        let service = RemoteLLMService(settings: settings)
        service.setActiveConnection(id: "offline", modelID: "cached-model")
        try await service.loadSelectedModel()

        XCTAssertTrue(service.isModelLoaded)
        XCTAssertEqual(service.selectedModelID, "cached-model")
    }
}
