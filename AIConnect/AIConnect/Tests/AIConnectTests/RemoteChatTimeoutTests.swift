// SPDX-License-Identifier: MIT
import XCTest
@testable import AIConnect
import AIModelOptions

final class RemoteChatTimeoutTests: XCTestCase {
    func testDefaultsAreIdleNotATenMinuteResourceCap() {
        let defaults = UserDefaults(suiteName: "timeout-\(UUID().uuidString)")!
        XCTAssertEqual(RemoteChatTimeout.idleSeconds(defaults: defaults), 600)
        XCTAssertEqual(RemoteChatTimeout.resourceSeconds(defaults: defaults), 86_400)
    }

    func testUserDefaultsOverrideTimeouts() {
        let defaults = UserDefaults(suiteName: "timeout-\(UUID().uuidString)")!
        defaults.set(120.0, forKey: RemoteChatTimeout.idleDefaultsKey)
        defaults.set(3_600.0, forKey: RemoteChatTimeout.resourceDefaultsKey)
        XCTAssertEqual(RemoteChatTimeout.idleSeconds(defaults: defaults), 120)
        XCTAssertEqual(RemoteChatTimeout.resourceSeconds(defaults: defaults), 3_600)
    }

    func testStreamingChatPayloadOmitsHardcodedMaxTokens() {
        let payload = OpenAICompatibleAPI.chatPayload(
            model: "qwen3.8-flash-next",
            messages: [["role": "user", "content": "hi"]],
            stream: true
        )
        XCTAssertNil(payload["max_tokens"])
        XCTAssertNil(payload["max_completion_tokens"])
        XCTAssertEqual((payload["stream_options"] as? [String: Any])?["include_usage"] as? Bool, true)
    }
}

final class StreamCutoffWireTests: XCTestCase {
    @MainActor
    func testLengthFinishReasonIsSurfacedToTheCaller() async throws {
        let defaults = UserDefaults(suiteName: "cutoff-\(UUID().uuidString)")!
        let settings = ProviderSettings(defaults: defaults, apiKeyStore: RemoteAPIKeyStore(defaults: defaults, secureStore: MemorySecureStore()))
        var connection = RemoteConnection.lmStudioPreset()
        connection.apiBaseURL = "http://127.0.0.1:1234/v1"
        connection.defaultModel = "qwen3.8-flash-next"
        connection.availableModels = ["qwen3.8-flash-next"]
        settings.updateConnection(connection)
        ServiceWireStub.requests = []
        ServiceWireStub.reply = """
        data: {"choices":[{"delta":{"content":"partial"}}]}

        data: {"choices":[{"delta":{},"finish_reason":"length"}]}

        data: [DONE]

        """
        let service = RemoteLLMService(settings: settings, session: ServiceWireStub.session)
        service.setActiveConnection(id: connection.id, modelID: "qwen3.8-flash-next")
        let tool: [String: Any] = ["type": "function", "function": ["name": "lookup", "description": "d", "parameters": ["type": "object", "properties": [:]]]]
        do {
            _ = try await service.agentRound(
                history: [LLMChatTurn(role: "user", content: "hi")],
                tools: [tool],
                toolNames: ["lookup"]
            )
            XCTFail("expected a cutoff")
        } catch let error as LLMServiceError {
            guard case .replyCutOff(let message) = error else {
                return XCTFail("\(error)")
            }
            XCTAssertTrue(message.contains("cut off (length)"), message)
        }
    }
}
