// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import XCTest
import AnAIOdysseyAI
import AIModelOptions

@MainActor
final class ConfiguredModelRegistryTests: XCTestCase {
    func testAvailableChoicesOmitLocalMLXWhenNotOffered() {
        let settings = ProviderSettings()
        settings.remoteConnections = [
            RemoteConnection(
                id: "openai",
                name: "OpenAI",
                apiBaseURL: "https://api.openai.com/v1",
                apiKey: "secret",
                defaultModel: "gpt-4o-mini",
                encoding: .openAIChatCompletions
            ),
        ]

        let choices = ConfiguredModelRegistry.availableChoices(
            providerSettings: settings,
            offerLocalMLX: false,
            offerAppleFoundation: false
        )
        XCTAssertFalse(choices.contains { $0.backend == .localMLX })
        XCTAssertFalse(choices.contains { $0.backend == .appleFoundation })
        XCTAssertTrue(choices.contains { $0.backend == .remote })
    }

    func testAvailableChoicesIncludeAppleFoundationWhenOffered() {
        let settings = ProviderSettings()
        let choices = ConfiguredModelRegistry.availableChoices(
            providerSettings: settings,
            offerLocalMLX: false,
            offerAppleFoundation: true
        )
        XCTAssertEqual(choices.first?.backend, .appleFoundation)
        XCTAssertEqual(choices.first?.id, AppleFoundationModel.modelID)
        XCTAssertEqual(choices.first?.displayName, "Apple On-Device")
        XCTAssertEqual(choices.first?.pickerLabel, "Apple On-Device")
        XCTAssertEqual(choices.first?.selectionKey, "appleFoundation|apple_foundation")
        XCTAssertFalse(choices.contains { $0.backend == .localMLX })
    }

    func testChatGPTConnectionIsConfiguredOnlyWhenPlanEligible() {
        let settings = ProviderSettings()
        var connection = RemoteConnection.chatGPTPreset()
        connection.chatgptIssuedClientID = "oaiapp_test"
        connection.chatgptPlanEligible = false
        XCTAssertTrue(connection.usesChatGPTAccount)
        XCTAssertFalse(settings.adapter(for: connection).isConfigured(connection: connection))
        XCTAssertEqual(
            settings.adapter(for: connection).configurationHint(connection: connection),
            ChatGPTOAuthCodec.ineligibleUserMessage
        )

        connection.chatgptPlanEligible = true
        XCTAssertTrue(settings.adapter(for: connection).isConfigured(connection: connection))
    }

    func testAvailableChoicesIncludeLocalAndRemoteModels() {
        let settings = ProviderSettings()
        settings.remoteConnections = [
            RemoteConnection(
                id: "openai",
                name: "OpenAI",
                apiBaseURL: "https://api.openai.com/v1",
                apiKey: "secret",
                defaultModel: "gpt-4o-mini",
                encoding: .openAIChatCompletions
            ),
        ]

        let choices = ConfiguredModelRegistry.availableChoices(providerSettings: settings)
        XCTAssertTrue(settings.isRemoteConfigured)
        XCTAssertGreaterThan(choices.count, LLMModelCatalog.models.count)
        XCTAssertTrue(choices.contains { $0.backend == .localMLX })
        XCTAssertTrue(choices.contains { $0.backend == .remote })
    }

    func testInferredBackendUsesCatalogForLocalModels() {
        let settings = ProviderSettings()
        XCTAssertEqual(
            ConfiguredModelRegistry.inferredBackend(
                for: LLMModelCatalog.defaultModelID,
                providerSettings: settings
            ),
            .localMLX
        )
    }

    func testInferredBackendUsesRemoteForRemoteModelName() {
        let settings = ProviderSettings()
        settings.remoteConnections = [
            RemoteConnection(
                name: "OpenAI",
                apiBaseURL: "https://api.openai.com/v1",
                apiKey: "secret",
                defaultModel: "gpt-4o-mini",
                encoding: .openAIChatCompletions
            ),
        ]

        XCTAssertEqual(
            ConfiguredModelRegistry.inferredBackend(for: "gpt-4o-mini", providerSettings: settings),
            .remote
        )
    }

    func testPreferredResearchDefaultsToRemoteWhenConfigured() {
        let settings = ProviderSettings()
        settings.remoteConnections = [
            RemoteConnection(
                name: "OpenAI",
                apiBaseURL: "https://api.openai.com/v1",
                apiKey: "secret",
                defaultModel: "gpt-4o-mini",
                encoding: .openAIChatCompletions
            ),
        ]

        let config = LLMModelPreparer.defaultResearchConfiguration(providerSettings: settings)
        XCTAssertEqual(config.backend, .remote)
        XCTAssertEqual(config.modelID, "gpt-4o-mini")
    }

    func testPreferredResearchUsesAutoWhenChatLocalMLXSelected() {
        let settings = ProviderSettings()
        let config = LLMModelPreparer.preferredResearchConfiguration(
            providerSettings: settings,
            chatModelID: LLMModelCatalog.defaultModelID,
            chatBackend: .localMLX,
            useChatModel: true,
            dedicatedModelID: LLMModelCatalog.defaultModelID,
            dedicatedBackend: .auto
        )
        XCTAssertEqual(config.backend, .auto)
    }

    func testAvailableChoicesIncludeQueriedRemoteModels() {
        let settings = ProviderSettings()
        settings.remoteConnections = [
            RemoteConnection(
                name: "LAN",
                apiBaseURL: "http://192.168.1.100:11435/v1",
                defaultModel: "gpt-oss-120b",
                availableModels: ["gpt-oss-120b", "openai/gpt-oss-120b", "qwen/qwen3-coder-next"],
                encoding: .openAIChatCompletions
            ),
        ]

        let choices = ConfiguredModelRegistry.availableChoices(providerSettings: settings)
        XCTAssertTrue(choices.contains { $0.id == "gpt-oss-120b" && $0.backend == .remote })
        XCTAssertTrue(choices.contains { $0.id == "openai/gpt-oss-120b" && $0.backend == .remote })
    }

    func testChoiceForSelectionKeyMatchesAvailableChoicesWithoutRebuildingTheList() {
        let settings = ProviderSettings()
        settings.remoteConnections = [
            RemoteConnection(
                id: "openai",
                name: "OpenAI",
                apiBaseURL: "https://api.openai.com/v1",
                apiKey: "secret",
                defaultModel: "gpt-4o-mini",
                availableModels: ["gpt-4o-mini", "gpt-4o", "text-embedding-3-small"],
                encoding: .openAIChatCompletions
            ),
            RemoteConnection(
                id: "disabled",
                name: "Off",
                apiBaseURL: "https://example.invalid/v1",
                apiKey: "secret",
                defaultModel: "hidden-model",
                availableModels: ["hidden-model"],
                encoding: .openAIChatCompletions,
                isEnabled: false
            ),
        ]

        let choices = ConfiguredModelRegistry.availableChoices(providerSettings: settings)
        XCTAssertFalse(choices.isEmpty)
        for choice in choices {
            XCTAssertEqual(
                ConfiguredModelRegistry.choice(
                    forSelectionKey: choice.selectionKey,
                    providerSettings: settings
                ),
                choice
            )
        }

        XCTAssertNil(
            ConfiguredModelRegistry.choice(
                forSelectionKey: "remote|openai|text-embedding-3-small",
                providerSettings: settings
            )
        )
        XCTAssertNil(
            ConfiguredModelRegistry.choice(
                forSelectionKey: "remote|disabled|hidden-model",
                providerSettings: settings
            )
        )
        XCTAssertNil(
            ConfiguredModelRegistry.choice(
                forSelectionKey: "remote|missing|gpt-4o-mini",
                providerSettings: settings
            )
        )
        XCTAssertEqual(
            ConfiguredModelRegistry.choice(
                for: "gpt-4o-mini",
                providerSettings: settings
            )?.backend,
            .remote
        )
        XCTAssertEqual(
            ConfiguredModelRegistry.choice(
                for: LLMModelCatalog.defaultModelID,
                providerSettings: settings
            )?.backend,
            .localMLX
        )
    }

    func testChatRecentPickerShowsTenNewestChatModelsNewestFirst() {
        let settings = ProviderSettings()
        var created: [String: Int] = [:]
        var available = ["dall-e-3", "text-embedding-3-small"]
        for index in 1...12 {
            let id = "custom-chat-\(index)"
            available.append(id)
            created[id] = index
        }
        settings.remoteConnections = [
            RemoteConnection(
                id: "lan",
                name: "LAN",
                apiBaseURL: "http://127.0.0.1:11435/v1",
                defaultModel: "custom-chat-1",
                availableModels: available,
                encoding: .openAIChatCompletions,
                modelCreatedAt: created
            ),
        ]

        let choices = ConfiguredModelRegistry.availableChoices(
            providerSettings: settings,
            downloadedLocalModelIDs: [],
            scope: .chatRecent
        )
        let remoteIDs = choices.filter { $0.backend == .remote }.map(\.id)
        XCTAssertEqual(remoteIDs, [
            "custom-chat-12",
            "custom-chat-11",
            "custom-chat-10",
            "custom-chat-9",
            "custom-chat-8",
            "custom-chat-7",
            "custom-chat-6",
            "custom-chat-5",
            "custom-chat-4",
            "custom-chat-3",
        ])
        XCTAssertFalse(remoteIDs.contains("dall-e-3"))
        XCTAssertFalse(remoteIDs.contains("text-embedding-3-small"))
        XCTAssertFalse(remoteIDs.contains("custom-chat-1"))
        XCTAssertFalse(remoteIDs.contains("custom-chat-2"))

        let storedKey = ConfiguredModelRegistry.selectionKey(
            modelID: "custom-chat-1",
            backend: .remote,
            connectionID: "lan"
        )
        let pickerRows = ConfiguredModelRegistry.pickerChoices(
            providerSettings: settings,
            downloadedLocalModelIDs: [],
            scope: .chatRecent,
            selectionKey: storedKey,
            offerLocalMLX: false,
            offerAppleFoundation: false
        )
        XCTAssertEqual(pickerRows.first?.id, "custom-chat-1")
        XCTAssertEqual(
            ConfiguredModelRegistry.resolvedPickerSelection(stored: storedKey, choices: pickerRows),
            storedKey
        )
    }

    func testResolvedPickerSelectionSnapsEmptyOrInvalidKeysOnly() {
        let settings = ProviderSettings()
        settings.remoteConnections = [
            RemoteConnection(
                id: "openai",
                name: "OpenAI",
                apiBaseURL: "https://api.openai.com/v1",
                apiKey: "secret",
                defaultModel: "gpt-4o-mini",
                availableModels: ["gpt-4o-mini", "gpt-4o"],
                encoding: .openAIChatCompletions
            ),
        ]
        let choices = ConfiguredModelRegistry.pickerChoices(
            providerSettings: settings,
            downloadedLocalModelIDs: [],
            offerLocalMLX: false,
            offerAppleFoundation: false
        )
        XCTAssertFalse(choices.isEmpty)
        let first = choices[0].selectionKey
        XCTAssertEqual(
            ConfiguredModelRegistry.resolvedPickerSelection(stored: "", choices: choices),
            first
        )
        XCTAssertEqual(
            ConfiguredModelRegistry.resolvedPickerSelection(
                stored: "remote|missing|nope",
                choices: choices
            ),
            first
        )
        XCTAssertEqual(
            ConfiguredModelRegistry.resolvedPickerSelection(stored: first, choices: choices),
            first
        )
    }

    func testImageOnlyPickerListsImageModelsIncludingGrokImagine() {
        let settings = ProviderSettings()
        settings.remoteConnections = [
            RemoteConnection.xAIPreset(),
        ]
        settings.remoteConnections[0].apiKey = "secret"

        let choices = ConfiguredModelRegistry.availableChoices(
            providerSettings: settings,
            downloadedLocalModelIDs: [],
            scope: .imageOnly
        )
        XCTAssertEqual(choices.map(\.id), ["grok-imagine-image-2.0"])
        XCTAssertTrue(choices.allSatisfy { $0.backend == .remote })
    }

    func testUnfilteredComparePickerIncludesChatAndImage() {
        let settings = ProviderSettings()
        settings.remoteConnections = [
            RemoteConnection.xAIPreset(),
        ]
        settings.remoteConnections[0].apiKey = "secret"

        let choices = ConfiguredModelRegistry.availableChoices(
            providerSettings: settings,
            downloadedLocalModelIDs: [],
            scope: .unfiltered
        )
        XCTAssertTrue(choices.contains { $0.id == "grok-4.7" })
        XCTAssertTrue(choices.contains { $0.id == "grok-imagine-image-2.0" })
    }

    func testOfficialOpenAIIncludesAstraEvenBeforeQuery() {
        let settings = ProviderSettings()
        settings.remoteConnections = [
            RemoteConnection(
                id: "openai",
                name: "OpenAI",
                apiBaseURL: "https://api.openai.com/v1",
                apiKey: "secret",
                defaultModel: "gpt-4o-mini",
                encoding: .openAIChatCompletions
            ),
        ]

        let choices = ConfiguredModelRegistry.availableChoices(providerSettings: settings)
        let astra = choices.first { $0.id == "gpt-6-astra" }
        XCTAssertNotNil(astra)
        XCTAssertEqual(astra?.displayName, "GPT-6 Astra")
        XCTAssertEqual(astra?.backend, .remote)
        XCTAssertEqual(
            ConfiguredModelRegistry.choice(
                forSelectionKey: "remote|openai|gpt-6-astra",
                providerSettings: settings
            )?.id,
            "gpt-6-astra"
        )
    }
}

@MainActor
final class ImageGenerationCatalogTests: XCTestCase {
    func testAvailableModelsListsOnlyImageModels() {
        let settings = ProviderSettings()
        settings.remoteConnections = [
            RemoteConnection(
                id: "openai",
                name: "OpenAI",
                apiBaseURL: "https://api.openai.com/v1",
                apiKey: "secret",
                defaultModel: "gpt-4o-mini",
                availableModels: ["gpt-4o-mini", "dall-e-3", "gpt-image-1", "tts-1"],
                encoding: .openAIChatCompletions
            ),
        ]

        let models = ImageGenerationCatalog.availableModels(providerSettings: settings)
        XCTAssertEqual(models.map(\.modelID).sorted(), ["dall-e-3", "gpt-image-1"])
        XCTAssertTrue(models.allSatisfy { $0.connectionID == "openai" })
        let editModels = ImageGenerationCatalog.availableEditModels(providerSettings: settings)
        XCTAssertEqual(editModels.map(\.modelID), ["gpt-image-1"])
    }

    func testXAIPresetListsGrokImagineEvenBeforeQuery() {
        let settings = ProviderSettings()
        settings.remoteConnections = [RemoteConnection.xAIPreset()]
        settings.remoteConnections[0].apiKey = "secret"

        let models = ImageGenerationCatalog.availableModels(providerSettings: settings)
        XCTAssertEqual(models.map(\.modelID), ["grok-imagine-image-2.0"])
    }

    func testTTSConnectionsRequireOfficialKeys() {
        let settings = ProviderSettings()
        settings.remoteConnections = [
            RemoteConnection(
                id: "openai",
                name: "OpenAI",
                apiBaseURL: "https://api.openai.com/v1",
                apiKey: "sk-test",
                defaultModel: "gpt-4o-mini",
                encoding: .openAIChatCompletions
            ),
            RemoteConnection.xAIPreset(),
            RemoteConnection(
                id: "openrouter",
                name: "OpenRouter",
                apiBaseURL: "https://openrouter.ai/api/v1",
                apiKey: "or-test",
                encoding: .openAIChatCompletions
            ),
        ]
        settings.remoteConnections[1].apiKey = "xai-test"

        XCTAssertEqual(settings.openAITTSConnection()?.id, "openai")
        XCTAssertEqual(settings.xAITTSConnection()?.apiKey, "xai-test")
        XCTAssertTrue(settings.hasConfiguredOpenAITTSKey)
        XCTAssertTrue(settings.hasConfiguredXAITTSKey)

        settings.remoteConnections[0].apiKey = ""
        settings.remoteConnections[1].apiKey = ""
        XCTAssertNil(settings.openAITTSConnection())
        XCTAssertNil(settings.xAITTSConnection())
    }

    func testFilenameSlugsPrompt() {
        XCTAssertEqual(
            ImageGenerationCatalog.filename(for: "A pig in a meadow!"),
            "a-pig-in-a-meadow.png"
        )
        XCTAssertEqual(ImageGenerationCatalog.filename(for: "???"), "generated-image.png")
    }
}

final class WebSearchServiceTests: XCTestCase {
    @MainActor
    func testWikipediaSearchReturnsResults() async throws {
        let service = WebSearchService()
        let results = try await service.search(query: "Swift programming language", limit: 3)
        XCTAssertFalse(results.isEmpty)
        XCTAssertTrue(results.allSatisfy { !$0.title.isEmpty && !$0.url.isEmpty })
    }
}
