// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import XCTest
import AnAIOdysseyAI
import AnAIOdysseyCore
import AIModelOptions

/// ChatGPT plan inference: Responses-only request shape, Bearer access token,
/// and the API-key fallback when the plan is not eligible.
@MainActor
final class ChatGPTPlanInferenceTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var providerSettings: ProviderSettings!
    private var accounts: ChatGPTAccountService!
    private var connectionID = ""
    private let model = "gpt-6.1-sol"

    override func setUp() async throws {
        suiteName = "siwc-inference-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        providerSettings = ProviderSettings(
            defaults: defaults,
            apiKeyStore: RemoteAPIKeyStore(defaults: defaults, secureStore: InMemoryTokenSecureStore())
        )
        providerSettings.remoteConnections = []
        SIWCMockURLProtocol.reset()
        accounts = ChatGPTAccountService(
            defaults: defaults,
            secureStore: InMemoryTokenSecureStore(),
            session: SIWCMockURLProtocol.makeSession(),
            verifySignatures: false
        )
        connectionID = "cg-\(UUID().uuidString)"
        providerSettings.updateConnection(SIWCFixtures.chatGPTConnection(id: connectionID, model: model))
        try accounts.saveCredentials(
            SIWCFixtures.credentials(expiresAt: Date().addingTimeInterval(3600)),
            connectionID: connectionID
        )
        // Options a user could set; none of them may reach the plan route.
        var options = ModelGenerationOptions()
        options.maxOutputTokens = 2048
        ModelGenerationSettings.setOptions(
            options,
            forSelectionKey: ModelGenerationSettings.remoteSelectionKey(connectionID: connectionID, modelID: model)
        )
    }

    override func tearDown() async throws {
        ModelGenerationSettings.removeOptions(connectionID: connectionID)
        SIWCMockURLProtocol.reset()
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeService() -> RemoteLLMService {
        let service = RemoteLLMService(
            settings: providerSettings,
            session: SIWCMockURLProtocol.makeSession(),
            chatGPTAccounts: accounts
        )
        service.setActiveConnection(id: connectionID, modelID: model)
        return service
    }

    private func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> String {
        var text = ""
        for try await chunk in stream { text += chunk }
        return text
    }

    private func assertPlanRequestShape(_ request: URLRequest, _ body: Data, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses", file: file, line: line)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer plan-token", file: file, line: line)
        let json = SIWCFixtures.json(body)
        XCTAssertEqual(json["stream"] as? Bool, true, "stream:true", file: file, line: line)
        XCTAssertEqual(json["store"] as? Bool, false, "store:false", file: file, line: line)
        for key in OpenAIRequestCodec.chatGPTPlanUnsupportedFields {
            XCTAssertNil(json[key], "\(key) must be omitted", file: file, line: line)
        }
        XCTAssertNil(json["previous_response_id"], file: file, line: line)
        XCTAssertNil(json["messages"], "Responses API only", file: file, line: line)
        XCTAssertNotNil(json["input"] as? [[String: Any]], file: file, line: line)
    }

    func testStreamingUsesResponsesWithPlanShape() async throws {
        SIWCMockURLProtocol.handler = { _, _ in
            .init(status: 200, headers: ["Content-Type": "text/event-stream"], body: SIWCFixtures.helloStream)
        }
        let service = makeService()
        try await service.loadSelectedModel()
        let text = try await collect(service.streamResponse(
            to: "three",
            history: [LLMChatTurn(role: "user", content: "one"), LLMChatTurn(role: "assistant", content: "two")]
        ))
        XCTAssertEqual(text, "Hello")
        let sent = try XCTUnwrap(SIWCMockURLProtocol.requests.last)
        assertPlanRequestShape(sent.request, sent.body)
        let input = SIWCFixtures.json(sent.body)["input"] as? [[String: Any]] ?? []
        XCTAssertEqual(input.compactMap { $0["content"] as? String }, ["one", "two", "three"], "Full history in input")
    }

    func testSecondTurnResendsHistoryInsteadOfPreviousResponseID() async throws {
        SIWCMockURLProtocol.handler = { _, _ in .init(status: 200, body: SIWCFixtures.helloStream) }
        let service = makeService()
        try await service.loadSelectedModel()
        _ = try await collect(service.streamResponse(to: "first", history: []))
        _ = try await collect(service.streamResponse(
            to: "second",
            history: [LLMChatTurn(role: "user", content: "first"), LLMChatTurn(role: "assistant", content: "Hello")]
        ))
        let sent = try XCTUnwrap(SIWCMockURLProtocol.requests.last)
        assertPlanRequestShape(sent.request, sent.body)
        let input = SIWCFixtures.json(sent.body)["input"] as? [[String: Any]] ?? []
        XCTAssertEqual(input.count, 3)
    }

    func testNonStreamingCallersStillStreamOnThePlanRoute() async throws {
        SIWCMockURLProtocol.handler = { _, _ in .init(status: 200, body: SIWCFixtures.helloStream) }
        let service = makeService()
        let text = try await service.completeResponse(to: "Say hello", history: [])
        XCTAssertEqual(text, "Hello")
        let sent = try XCTUnwrap(SIWCMockURLProtocol.requests.last)
        assertPlanRequestShape(sent.request, sent.body)
    }

    func testNotEligibleFallsBackToAPIKeyConnection() async throws {
        var keyConnection = RemoteConnection.openAIPreset()
        keyConnection.id = "openai-key-\(UUID().uuidString)"
        keyConnection.apiKey = "sk-test"
        keyConnection.defaultModel = model
        keyConnection.availableModels = [model]
        providerSettings.updateConnection(keyConnection)

        SIWCMockURLProtocol.handler = { request, _ in
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer plan-token" {
                return .init(
                    status: 403,
                    headers: ["x-request-id": "req_403"],
                    body: Data(#"{"error":{"code":"subscription_sharing_user_not_eligible","message":"User is not eligible.","param":null}}"#.utf8)
                )
            }
            return .init(status: 200, body: SIWCFixtures.helloStream)
        }
        let service = makeService()
        try await service.loadSelectedModel()
        let text = try await collect(service.streamResponse(to: "hi", history: []))
        XCTAssertEqual(text, "Hello")

        let auths = SIWCMockURLProtocol.requests.map { $0.request.value(forHTTPHeaderField: "Authorization") }
        XCTAssertEqual(auths, ["Bearer plan-token", "Bearer sk-test"], "One plan attempt, then the API key; no OAuth loop")
        XCTAssertEqual(providerSettings.connection(id: connectionID)?.chatgptPlanEligible, false)
        XCTAssertTrue(accounts.lastError?.contains("API key") ?? false)
        ModelGenerationSettings.removeOptions(connectionID: keyConnection.id)
    }

    func testNotEligibleWithoutAPIKeyExplainsHowToContinue() async throws {
        SIWCMockURLProtocol.handler = { _, _ in
            .init(status: 403, body: Data(#"{"error":{"code":"subscription_sharing_user_not_eligible","message":"no"}}"#.utf8))
        }
        let service = makeService()
        do {
            _ = try await service.completeResponse(to: "hi", history: [])
            XCTFail("Expected error")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("Plus or Pro"), message)
            XCTAssertTrue(message.contains("API key"), message)
        }
        XCTAssertEqual(SIWCMockURLProtocol.requests.count, 1)
        XCTAssertEqual(providerSettings.connection(id: connectionID)?.chatgptPlanEligible, false)
    }

    func testUsageLimitPointsToManageUsageWithoutSwitchingBilling() async throws {
        var keyConnection = RemoteConnection.openAIPreset()
        keyConnection.id = "openai-key-\(UUID().uuidString)"
        keyConnection.apiKey = "sk-test"
        providerSettings.updateConnection(keyConnection)
        SIWCMockURLProtocol.handler = { _, _ in
            .init(status: 429, body: Data(#"{"error":{"code":"subscription_sharing_usage_limit_exceeded","message":"limit"}}"#.utf8))
        }
        let service = makeService()
        do {
            _ = try await service.completeResponse(to: "hi", history: [])
            XCTFail("Expected error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Manage usage"))
        }
        XCTAssertEqual(SIWCMockURLProtocol.requests.count, 1)
        XCTAssertEqual(providerSettings.connection(id: connectionID)?.chatgptPlanEligible, true)
    }

    func testAgentToolRoundResendsCallItemsWithOutputs() async throws {
        let toolStream = SIWCFixtures.sse([
            #"{"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","name":"lookup","call_id":"call_1","arguments":""}}"#,
            #"{"type":"response.function_call_arguments.delta","output_index":0,"delta":"{\"q\":1}"}"#,
            #"{"type":"response.completed","response":{"id":"resp_t","output":[]}}"#,
        ])
        var round = 0
        SIWCMockURLProtocol.handler = { _, _ in
            round += 1
            return .init(status: 200, body: round == 1 ? toolStream : SIWCFixtures.helloStream)
        }
        let tools: [[String: Any]] = [[
            "type": "function",
            "function": ["name": "lookup", "description": "Look up", "parameters": ["type": "object", "properties": [:]]],
        ]]
        let service = makeService()
        let first = try await service.agentRound(
            history: [LLMChatTurn(role: "system", content: "sys"), LLMChatTurn(role: "user", content: "q")],
            tools: tools,
            toolNames: ["lookup"]
        )
        XCTAssertEqual(first.toolBlocks.count, 1)
        _ = try await service.agentRound(
            history: [
                LLMChatTurn(role: "system", content: "sys"),
                LLMChatTurn(role: "user", content: "q"),
                LLMChatTurn(role: "assistant", content: ""),
            ],
            tools: tools,
            toolNames: ["lookup"],
            previousResponseID: first.responseID,
            functionCallOutputs: [EncodedFunctionCallOutput(callID: "call_1", output: "42")]
        )
        let sent = try XCTUnwrap(SIWCMockURLProtocol.requests.last)
        assertPlanRequestShape(sent.request, sent.body)
        let json = SIWCFixtures.json(sent.body)
        XCTAssertEqual(json["instructions"] as? String, "sys")
        let input = json["input"] as? [[String: Any]] ?? []
        let types = input.map { $0["type"] as? String ?? "message" }
        XCTAssertEqual(Array(types.suffix(2)), ["function_call", "function_call_output"])
        XCTAssertEqual(input.first(where: { $0["type"] as? String == "function_call" })?["call_id"] as? String, "call_1")
        XCTAssertEqual(input.first?["content"] as? String, "q", "History is resent")
    }
}
