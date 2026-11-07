// SPDX-License-Identifier: MIT
import XCTest
@testable import AIConnect
import AIModelOptions

/// PR #229 review (B4): a Standard row on :1234 saved before server detection existed got
/// LM Studio's settings from its port (#219). Without the port it must get them from the server,
/// before the agent's first turn of a launch.
@MainActor
final class LegacyLMStudioRowTests: XCTestCase {
    private let qwen = "qwen/qwen3.8-27b"

    private func settings() -> ProviderSettings {
        ProviderSettings(defaults: UserDefaults(suiteName: "legacy-\(UUID().uuidString)")!,
                         apiKeyStore: RemoteAPIKeyStore(secureStore: MemorySecureStore()))
    }

    func testAnOldStandardRowOn1234KeepsLMStudioSettingsAfterTheLaunchCheck() async throws {
        let s = settings()
        let c = RemoteConnection(name: "LM Studio", apiBaseURL: "http://127.0.0.1:1234/v1",
                                 availableModels: [qwen], encoding: .openAIChatCompletions)
        s.updateConnection(c)
        XCTAssertNil(s.connection(id: c.id)?.detectedLMStudio, "saved by build 54 or earlier")
        ModelsListStub.bodies = ["/v1/models": LMStudioAnyPortToolCheckTests.openAIList,
                                 "/api/v1/models": LMStudioAnyPortToolCheckTests.v1Models]
        await RemoteLLMService(settings: s, session: ModelsListStub.session).detectServersIfNeeded()
        let saved = try XCTUnwrap(s.connection(id: c.id))
        XCTAssertTrue(saved.servesLMStudioTools)
        XCTAssertTrue(LocalChatHistoryPolicy.sendsToolArgumentsAsObjects(connection: saved, modelID: qwen, usesResponsesAPI: false))
        XCTAssertTrue(LocalChatHistoryPolicy.sendsReasoningContent(connection: saved, usesResponsesAPI: false))
        XCTAssertEqual(saved.detectedServerLabel, "LM Studio")
    }

    func testTheLaunchCheckSkipsRowsAlreadyCheckedAtTheirURL() async throws {
        let s = settings()
        var c = RemoteConnection(name: "LM Studio", apiBaseURL: "http://127.0.0.1:1234/v1", encoding: .openAIChatCompletions)
        c.recordServer(isLMStudio: true, isOllama: false)
        s.updateConnection(c)
        ModelsListStub.bodies = ["/v1/models": LMStudioAnyPortToolCheckTests.openAIList]
        await RemoteLLMService(settings: s, session: ModelsListStub.session).detectServersIfNeeded()
        XCTAssertEqual(s.connection(id: c.id)?.detectedLMStudio, true, "no second check this launch")
    }

    func testAnUnreachableServerChangesNothing() async throws {
        let s = settings()
        var c = RemoteConnection(name: "LM Studio", apiBaseURL: "http://127.0.0.1:1234/v1", encoding: .openAIChatCompletions)
        c.recordServer(isLMStudio: true, isOllama: false)
        s.updateConnection(c)
        ModelsListStub.bodies = [:]
        ModelsListStub.unreachable = true
        defer { ModelsListStub.unreachable = false }
        _ = await RemoteLLMService(settings: s, session: ModelsListStub.session).detectServer(for: c.id)
        XCTAssertEqual(s.connection(id: c.id)?.detectedLMStudio, true, "a timeout is not an answer")
    }
}
