// SPDX-License-Identifier: MIT
import Foundation
import XCTest
@testable import AIModelOptions

final class ModelOptionsFormattingTests: XCTestCase {
    func testPerTabOptionsStayReadOnlyUntilOwnModel() {
        XCTAssertFalse(ModelOptionsFormatting.shouldShowEditableOptions(hasOwnModelSelection: false))
        XCTAssertTrue(ModelOptionsFormatting.shouldShowEditableOptions(hasOwnModelSelection: true))
    }

    func testDefaultThinkingPickerLabel() {
        XCTAssertEqual(
            ModelOptionsFormatting.thinkingPickerLabel(.medium, defaultEffort: .medium),
            "Medium (Default)"
        )
        XCTAssertEqual(
            ModelOptionsFormatting.thinkingPickerLabel(.high, defaultEffort: .medium),
            "High"
        )
        XCTAssertEqual(
            ModelOptionsFormatting.thinkingPickerLabel(.max, defaultEffort: .max),
            "Max (Default)"
        )
    }

    func testInheritedLineUsesActualGlobalValues() {
        let caps = ModelCapabilityCatalog.capabilities(forModelID: "gpt-6-astra", backend: .remote)
        XCTAssertEqual(
            ModelOptionsFormatting.usingGlobalDefaultLine(
                options: ModelGenerationOptions(),
                capabilities: caps
            ),
            "Using global default: Medium thinking, Auto context"
        )
        XCTAssertEqual(
            ModelOptionsFormatting.usingGlobalDefaultLine(
                options: ModelGenerationOptions(
                    reasoningEffort: .high,
                    maxOutputTokens: 8_192,
                    contextWindowTokens: 128_000
                ),
                capabilities: caps
            ),
            "Using global default: High thinking, 128K context, 8K max output"
        )
    }

    func testLocalMLXInheritedLineOmitsThinking() {
        let caps = ModelCapabilityCatalog.capabilities(
            forModelID: "llama3_2_1B_4bit",
            backend: .localMLX
        )
        XCTAssertEqual(
            ModelOptionsFormatting.usingGlobalDefaultLine(
                options: ModelGenerationOptions(),
                capabilities: caps
            ),
            "Using global default: Auto context"
        )
    }

    func testRememberThinkingDefaultsOnForReasoningModels() {
        let astra = ModelCapabilityCatalog.capabilities(forModelID: "gpt-6-astra", backend: .remote)
        XCTAssertTrue(
            ModelOptionsFormatting.resolvedRememberThinking(
                options: ModelGenerationOptions(),
                capabilities: astra
            )
        )
        XCTAssertFalse(
            ModelOptionsFormatting.resolvedRememberThinking(
                options: ModelGenerationOptions(rememberThinking: false),
                capabilities: astra
            )
        )

        let mlx = ModelCapabilityCatalog.capabilities(
            forModelID: "llama3_2_1B_4bit",
            backend: .localMLX
        )
        XCTAssertFalse(
            ModelOptionsFormatting.resolvedRememberThinking(
                options: ModelGenerationOptions(),
                capabilities: mlx
            )
        )
    }

    func testMissingRememberThinkingDecodesAsNil() throws {
        let json = """
        {"reasoningEffort":"high","maxOutputTokens":8192}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ModelGenerationOptions.self, from: json)
        XCTAssertNil(decoded.rememberThinking)
        XCTAssertEqual(decoded.maxOutputTokens, 8_192)
        XCTAssertEqual(decoded.reasoningEffort, .high)
        let astra = ModelCapabilityCatalog.capabilities(forModelID: "gpt-6-astra", backend: .remote)
        XCTAssertTrue(
            ModelOptionsFormatting.resolvedRememberThinking(options: decoded, capabilities: astra)
        )
    }

    func testExplicitFalseRememberThinkingStaysOff() throws {
        let json = """
        {"rememberThinking":false}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ModelGenerationOptions.self, from: json)
        XCTAssertEqual(decoded.rememberThinking, false)
        let astra = ModelCapabilityCatalog.capabilities(forModelID: "gpt-6-astra", backend: .remote)
        XCTAssertFalse(
            ModelOptionsFormatting.resolvedRememberThinking(options: decoded, capabilities: astra)
        )
    }

    func testMaxOutputClampingAndChoices() {
        let astra = ModelCapabilityCatalog.capabilities(forModelID: "gpt-6-astra", backend: .remote)
        XCTAssertNil(ModelOptionsFormatting.clampMaxOutputTokens(nil, capabilities: astra))
        XCTAssertEqual(
            ModelOptionsFormatting.clampMaxOutputTokens(1_000_000, capabilities: astra),
            128_000
        )
        XCTAssertEqual(
            ModelOptionsFormatting.clampMaxOutputTokens(8_192, capabilities: astra),
            8_192
        )
        XCTAssertTrue(ModelOptionsFormatting.maxOutputChoices(for: astra).contains(128_000))

        let gpt4o = ModelCapabilityCatalog.capabilities(forModelID: "gpt-4o", backend: .remote)
        XCTAssertEqual(
            ModelOptionsFormatting.clampMaxOutputTokens(128_000, capabilities: gpt4o),
            16_384
        )
        XCTAssertEqual(ModelOptionsFormatting.maxOutputChoices(for: gpt4o).last, 16_384)
    }

    func testPersistingThinkingKeepsStoredMaxOutput() {
        let caps = ModelCapabilityCatalog.capabilities(forModelID: "gpt-6-astra", backend: .remote)
        let persisted = ModelOptionsFormatting.optionsToPersist(
            thinking: .high,
            contextWindowTokens: nil,
            maxOutputTokens: 8_192,
            rememberThinking: true,
            capabilities: caps
        )
        XCTAssertEqual(persisted.reasoningEffort, .high)
        XCTAssertEqual(persisted.maxOutputTokens, 8_192)
        XCTAssertNil(persisted.contextWindowTokens)
        XCTAssertEqual(persisted.rememberThinking, true)
    }

    func testPersistingDoesNotSendUnsupportedEffort() {
        let caps = ModelCapabilityCatalog.capabilities(forModelID: "gpt-6-astra", backend: .remote)
        let persisted = ModelOptionsFormatting.optionsToPersist(
            thinking: .minimal,
            contextWindowTokens: 2_000_000,
            maxOutputTokens: 999_999,
            rememberThinking: true,
            capabilities: caps
        )
        XCTAssertEqual(persisted.reasoningEffort, .medium)
        XCTAssertEqual(persisted.contextWindowTokens, 1_050_000)
        XCTAssertEqual(persisted.maxOutputTokens, 128_000)
    }
}
