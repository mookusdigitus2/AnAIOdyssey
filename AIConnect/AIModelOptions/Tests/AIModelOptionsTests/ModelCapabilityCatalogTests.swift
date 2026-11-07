// SPDX-License-Identifier: MIT
import XCTest
@testable import AIModelOptions

final class ModelCapabilityCatalogTests: XCTestCase {
    func testAstraCapabilities() {
        let caps = ModelCapabilityCatalog.capabilities(
            forModelID: "gpt-6-astra",
            backend: .remote
        )
        XCTAssertEqual(caps.displayName, "GPT-6 Astra")
        XCTAssertEqual(caps.contextWindowTokens, 1_050_000)
        XCTAssertEqual(caps.maxOutputTokens, 128_000)
        XCTAssertEqual(caps.supportedReasoningEfforts, [.low, .medium, .high, .xhigh, .max])
        XCTAssertEqual(caps.defaultReasoningEffort, .medium)
        XCTAssertTrue(caps.alwaysSendsReasoningEffort)
        XCTAssertTrue(caps.supportsRememberThinking)
        XCTAssertTrue(caps.prefersResponsesAPI)
        XCTAssertTrue(caps.requiresResponsesAPIForTools)
        XCTAssertFalse(caps.supportedReasoningEfforts.contains(.minimal))
    }

    func testNamespacedAstraUsesSameLimits() {
        let caps = ModelCapabilityCatalog.capabilities(
            forModelID: "openai/gpt-6-astra",
            backend: .remote
        )
        XCTAssertEqual(caps.contextWindowTokens, 1_050_000)
        XCTAssertEqual(caps.displayName, "GPT-6 Astra")
    }

    func testAppleFoundationHasNoThinkingAndSmallContext() {
        let caps = ModelCapabilityCatalog.capabilities(
            forModelID: ModelCapabilityCatalog.appleFoundationModelID,
            backend: .appleFoundation
        )
        XCTAssertEqual(caps.displayName, "Apple On-Device")
        XCTAssertEqual(caps.contextWindowTokens, 4096)
        XCTAssertFalse(caps.supportsThinking)
        XCTAssertFalse(caps.supportsRememberThinking)
        XCTAssertFalse(caps.isLocalMLX)
    }

    func testLocalMLXHasNoThinking() {
        let caps = ModelCapabilityCatalog.capabilities(
            forModelID: "llama3_2_1B_4bit",
            backend: .localMLX
        )
        XCTAssertTrue(caps.isLocalMLX)
        XCTAssertFalse(caps.supportsThinking)
        XCTAssertFalse(caps.supportsRememberThinking)
        XCTAssertEqual(
            ModelCapabilityCatalog.sanitizedReasoningEffort(.high, capabilities: caps),
            nil
        )
    }

    func testClassicChatModelHasNoThinking() {
        let caps = ModelCapabilityCatalog.capabilities(forModelID: "gpt-4o", backend: .remote)
        XCTAssertFalse(caps.supportsThinking)
        XCTAssertFalse(caps.prefersResponsesAPI)
        XCTAssertEqual(caps.contextWindowTokens, 128_000)
    }

    func testGPT5ThinkingIncludesMinimalButNotRequired() {
        let caps = ModelCapabilityCatalog.capabilities(forModelID: "gpt-5", backend: .remote)
        XCTAssertTrue(caps.supportedReasoningEfforts.contains(.minimal))
        XCTAssertTrue(caps.supportedReasoningEfforts.contains(.xhigh))
        XCTAssertFalse(caps.alwaysSendsReasoningEffort)
        XCTAssertEqual(
            ModelCapabilityCatalog.sanitizedReasoningEffort(nil, capabilities: caps),
            nil
        )
        XCTAssertEqual(
            ModelCapabilityCatalog.sanitizedReasoningEffort(.high, capabilities: caps),
            .high
        )
    }

    func testGPT56SolSupportsNoneNotMinimal() {
        let caps = ModelCapabilityCatalog.capabilities(forModelID: "gpt-5.6-sol", backend: .remote)
        XCTAssertEqual(caps.displayName, "GPT-5.6 Sol")
        XCTAssertTrue(caps.supportedReasoningEfforts.contains(.none))
        XCTAssertFalse(caps.supportedReasoningEfforts.contains(.minimal))
        XCTAssertTrue(caps.supportsReasoningMode)
        XCTAssertTrue(caps.prefersResponsesAPI)
    }

    func testGPT61SolAndLunaMatchDocs() {
        let sol = ModelCapabilityCatalog.capabilities(forModelID: "gpt-6.1-sol", backend: .remote)
        XCTAssertEqual(sol.displayName, "GPT-6.1 Sol")
        XCTAssertFalse(sol.supportedReasoningEfforts.contains(.none))
        XCTAssertFalse(sol.supportedReasoningEfforts.contains(.minimal))
        XCTAssertTrue(sol.requiresResponsesAPIForTools)

        let luna = ModelCapabilityCatalog.capabilities(forModelID: "gpt-6-luna", backend: .remote)
        XCTAssertEqual(luna.displayName, "GPT-6 Luna")
        XCTAssertTrue(luna.supportedReasoningEfforts.contains(.none))
        XCTAssertTrue(luna.supportedReasoningEfforts.contains(.max))
    }

    func testNewestChatModelsSortByReleaseDate() {
        let models = [
            RemoteModelDescriptor(id: "gpt-4o-mini"),
            RemoteModelDescriptor(id: "gpt-6-astra"),
            RemoteModelDescriptor(id: "gpt-6-luna"),
            RemoteModelDescriptor(id: "gpt-5.6-sol"),
            RemoteModelDescriptor(id: "dall-e-3"),
            RemoteModelDescriptor(id: "gpt-6.1-sol"),
        ]
        XCTAssertEqual(
            ModelCapabilityCatalog.newestChatModels(models, limit: 10),
            ["gpt-6-luna", "gpt-6-astra", "gpt-6.1-sol", "gpt-5.6-sol", "gpt-4o-mini"]
        )
        XCTAssertEqual(
            ModelCapabilityCatalog.newestChatModels(models, limit: 3),
            ["gpt-6-luna", "gpt-6-astra", "gpt-6.1-sol"]
        )
    }

    func testNewestChatModelsPreferProviderCreatedTimestamp() {
        let models = [
            RemoteModelDescriptor(id: "older-new-id", created: 10),
            RemoteModelDescriptor(id: "brand-new", created: 99),
            RemoteModelDescriptor(id: "mid", created: 50),
        ]
        XCTAssertEqual(
            ModelCapabilityCatalog.newestChatModels(models, limit: 2),
            ["brand-new", "mid"]
        )
    }

    func testGrokReasoningAndImagineFromDocs() {
        let grok = ModelCapabilityCatalog.capabilities(forModelID: "grok-4.7", backend: .remote)
        XCTAssertEqual(grok.displayName, "Grok 4.7")
        XCTAssertEqual(grok.defaultReasoningEffort, .high)
        XCTAssertEqual(grok.supportedReasoningEfforts, [.low, .medium, .high, .xhigh])
        XCTAssertTrue(grok.alwaysSendsReasoningEffort)
        XCTAssertTrue(ModelCapabilityCatalog.isImageGenerationModel("grok-imagine-image-2.0"))
        XCTAssertFalse(ModelCapabilityCatalog.isChatModel("grok-imagine-image-2.0"))
    }

    func testAstraRejectsMinimalAndNoneEquivalents() {
        let caps = ModelCapabilityCatalog.capabilities(forModelID: "gpt-6-astra", backend: .remote)
        XCTAssertEqual(
            ModelCapabilityCatalog.sanitizedReasoningEffort(.minimal, capabilities: caps),
            .medium
        )
        XCTAssertEqual(
            ModelCapabilityCatalog.sanitizedReasoningEffort(nil, capabilities: caps),
            .medium
        )
        XCTAssertEqual(
            ModelCapabilityCatalog.sanitizedReasoningEffort(.max, capabilities: caps),
            .max
        )
        XCTAssertEqual(
            ModelCapabilityCatalog.sanitizedReasoningEffort(.xhigh, capabilities: caps),
            .xhigh
        )
    }

    func testContextClamping() {
        let caps = ModelCapabilityCatalog.capabilities(forModelID: "gpt-6-astra", backend: .remote)
        XCTAssertNil(ModelCapabilityCatalog.clampContextTokens(nil, capabilities: caps))
        XCTAssertEqual(
            ModelCapabilityCatalog.clampContextTokens(2_000_000, capabilities: caps),
            1_050_000
        )
        XCTAssertEqual(
            ModelCapabilityCatalog.clampContextTokens(32_768, capabilities: caps),
            32_768
        )
        XCTAssertEqual(
            ModelCapabilityCatalog.clampContextTokens(0, capabilities: caps),
            1
        )

        let gpt4o = ModelCapabilityCatalog.capabilities(forModelID: "gpt-4o", backend: .remote)
        XCTAssertEqual(
            ModelCapabilityCatalog.clampContextTokens(1_050_000, capabilities: gpt4o),
            128_000
        )
    }

    func testContextChoicesStayWithinLimit() {
        let astra = ModelCapabilityCatalog.capabilities(forModelID: "gpt-6-astra", backend: .remote)
        let astraChoices = ModelCapabilityCatalog.contextChoices(for: astra)
        XCTAssertTrue(astraChoices.contains(1_050_000))
        XCTAssertEqual(astraChoices.last, 1_050_000)
        XCTAssertEqual(ModelCapabilityCatalog.contextLabel(tokens: 1_050_000), "1.05M")

        let gpt4o = ModelCapabilityCatalog.capabilities(forModelID: "gpt-4o", backend: .remote)
        let gpt4oChoices = ModelCapabilityCatalog.contextChoices(for: gpt4o)
        XCTAssertEqual(gpt4oChoices.last, 128_000)
        XCTAssertFalse(gpt4oChoices.contains(1_050_000))
        XCTAssertEqual(ModelCapabilityCatalog.contextLabel(tokens: 128_000), "128K")
    }

    func testContextLabelUsesKilobytesForBinaryPresets() {
        XCTAssertEqual(ModelCapabilityCatalog.contextLabel(tokens: 1_024), "1K")
        XCTAssertEqual(ModelCapabilityCatalog.contextLabel(tokens: 4_096), "4K")
        XCTAssertEqual(ModelCapabilityCatalog.contextLabel(tokens: 8_192), "8K")
        XCTAssertEqual(ModelCapabilityCatalog.contextLabel(tokens: 16_384), "16K")
        XCTAssertEqual(ModelCapabilityCatalog.contextLabel(tokens: 32_768), "32K")
        XCTAssertEqual(ModelCapabilityCatalog.contextLabel(tokens: 65_536), "64K")
        XCTAssertEqual(ModelCapabilityCatalog.contextLabel(tokens: 131_072), "128K")
    }
}
