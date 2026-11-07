// SPDX-License-Identifier: MIT
import XCTest
@testable import AIConnect
import AIModelOptions

/// PR #229 review (B2, B3): a saved "this is LM Studio" must not outlive the server it was
/// learned from, and no port number may decide what a server is.
@MainActor
final class ServerDetectionLifecycleTests: XCTestCase {
    private let qwen = "qwen/qwen3.8-27b"

    private func settings(_ tag: String) -> ProviderSettings {
        ProviderSettings(defaults: UserDefaults(suiteName: "\(tag)-\(UUID().uuidString)")!,
                         apiKeyStore: RemoteAPIKeyStore(secureStore: MemorySecureStore()))
    }

    private func objects(_ c: RemoteConnection?) -> Bool {
        guard let c else { return false }
        return LocalChatHistoryPolicy.sendsToolArgumentsAsObjects(connection: c, modelID: qwen, usesResponsesAPI: false)
    }

    private func reasoning(_ c: RemoteConnection?) -> Bool {
        guard let c else { return false }
        return LocalChatHistoryPolicy.sendsReasoningContent(connection: c, usesResponsesAPI: false)
    }

    /// B2: an LM Studio row repointed at a vLLM box must go back to string arguments.
    func testRepointingADetectedRowAtVLLMForgetsLMStudio() async throws {
        let s = settings("repoint")
        let c = RemoteConnection(name: "Box", apiBaseURL: "http://192.168.1.100:1234/v1")
        s.updateConnection(c)
        ModelsListStub.bodies = ["/v1/models": LMStudioAnyPortToolCheckTests.openAIList,
                                 "/api/v1/models": LMStudioAnyPortToolCheckTests.v1Models]
        let service = RemoteLLMService(settings: s, session: ModelsListStub.session)
        _ = try await service.queryModels(for: c.id)
        XCTAssertTrue(objects(s.connection(id: c.id)), "detected LM Studio, Standard Tool Format: objects")
        XCTAssertTrue(reasoning(s.connection(id: c.id)))

        var edited = try XCTUnwrap(s.connection(id: c.id))
        edited.apiBaseURL = "http://192.168.1.50:8000/v1"
        s.updateConnection(edited)
        let saved = try XCTUnwrap(s.connection(id: c.id))
        XCTAssertFalse(saved.servesLMStudioTools, "a new URL is a new server")
        XCTAssertFalse(objects(saved), "vLLM rejects object arguments")
        XCTAssertFalse(reasoning(saved))
    }

    /// B2: LM Studio swapped for another server on the same address is downgraded once that
    /// server answers without LM Studio's lists.
    func testADefiniteNoFromTheServerDowngradesDetection() async throws {
        let s = settings("downgrade")
        let c = RemoteConnection(name: "Box", apiBaseURL: "http://192.168.1.100:1234/v1")
        s.updateConnection(c)
        ModelsListStub.bodies = ["/v1/models": LMStudioAnyPortToolCheckTests.openAIList,
                                 "/api/v1/models": LMStudioAnyPortToolCheckTests.v1Models]
        let service = RemoteLLMService(settings: s, session: ModelsListStub.session)
        _ = try await service.queryModels(for: c.id)
        XCTAssertEqual(s.connection(id: c.id)?.detectedLMStudio, true)

        ModelsListStub.bodies = ["/v1/models": LMStudioAnyPortToolCheckTests.openAIList]
        _ = try await service.queryModels(for: c.id)
        XCTAssertEqual(s.connection(id: c.id)?.detectedLMStudio, false, "both LM Studio lists 404 now")
        XCTAssertFalse(objects(s.connection(id: c.id)))
    }

    /// B2: an Automatic row whose server says it isn't LM Studio doesn't get LM Studio's history.
    func testAnAutomaticRowOnVLLMIsNotTreatedAsLMStudio() async throws {
        let s = settings("auto-vllm")
        let c = RemoteConnection(name: "vLLM", apiBaseURL: "http://192.168.1.50:8000/v1", encoding: .automatic)
        s.updateConnection(c)
        ModelsListStub.bodies = ["/v1/models": #"{"object":"list","data":[{"id":"qwen/qwen3.8-27b","object":"model","owned_by":"vllm"}]}"#]
        _ = try await RemoteLLMService(settings: s, session: ModelsListStub.session).queryModels(for: c.id)
        XCTAssertFalse(objects(s.connection(id: c.id)))
        XCTAssertFalse(reasoning(s.connection(id: c.id)))
    }

    /// B3: Ollama is recognised from its own API on any port, not from 11434.
    func testOllamaIsRecognisedFromItsAPINotItsPort() async throws {
        XCTAssertEqual(OpenAICompatibleAPI.detectProvider(baseURL: "http://localhost:11434/v1"),
                       OpenAICompatibleAPI.detectProvider(baseURL: "http://localhost:1234/v1"),
                       "the port never decides")
        let s = settings("ollama")
        let c = RemoteConnection(name: "Ollama", apiBaseURL: "http://192.168.1.50:8080/v1", encoding: .automatic)
        s.updateConnection(c)
        ModelsListStub.bodies = ["/v1/models": #"{"object":"list","data":[{"id":"qwen3.8:27b","object":"model","owned_by":"library"}]}"#,
                                 "/api/version": #"{"version":"0.12.3"}"#,
                                 "/api/tags": #"{"models":[{"name":"qwen3.8:27b","model":"qwen3.8:27b","digest":"abc"}]}"#]
        _ = try await RemoteLLMService(settings: s, session: ModelsListStub.session).queryModels(for: c.id)
        let saved = try XCTUnwrap(s.connection(id: c.id))
        XCTAssertFalse(LocalChatHistoryPolicy.sendsToolArgumentsAsObjects(connection: saved, modelID: "qwen3.8:27b", usesResponsesAPI: false),
                       "Ollama on :8080 keeps string arguments")
    }

    /// B3: LM Studio moved to Ollama's usual port is still LM Studio.
    func testLMStudioOnPort11434GetsObjectArguments() {
        let c = RemoteConnection(name: "LM Studio", apiBaseURL: "http://localhost:11434/v1", encoding: .automatic)
        XCTAssertTrue(objects(c))
    }
}
