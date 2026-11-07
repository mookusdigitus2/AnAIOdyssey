// SPDX-License-Identifier: MIT
import XCTest
@testable import AIConnect
import AIModelOptions

/// User report: "it refuses to even try because it already shows an error." / "I deleted and created a new
/// connection and it didn't fix anything. that code is broken.."
///
/// The LM Studio here is `http://192.168.1.100:41234/v1`, not the default port 1234, and a connection
/// made with Add Custom Connection gets the Standard Tool Format. LM Studio was only recognised by
/// Tool Format Automatic or port 1234, so LM Studio's own `trained_for_tool_use: false` (default
/// tool use, not "no tools") could mark qwen/qwen3.8-27b "Doesn't support tools" and hide the test.
final class LMStudioAnyPortToolCheckTests: XCTestCase {
    private let qwen = "qwen/qwen3.8-27b"
    private let url = "http://192.168.1.100:41234/v1"
    private let toolCapableEncodings: Set<RemoteProtocolEncoding> = [.automatic, .openAIChatCompletions, .geminiOpenAI, .lmStudioHarmony]

    private func choice(_ id: String, on c: RemoteConnection) -> ConfiguredModelChoice {
        ConfiguredModelChoice(id: id, displayName: id, backend: .remote, providerLabel: c.trimmedName, connectionID: c.id)
    }

    private func freshDefaults(_ tag: String = "anyport") -> UserDefaults {
        UserDefaults(suiteName: "\(tag)-\(UUID().uuidString)")!
    }

    /// LM Studio's `/api/v1/models` row for the user's model: an llm whose template isn't tool-trained.
    static let v1Models = """
    {"models":[
      {"type":"llm","publisher":"qwen","key":"qwen/qwen3.8-27b","display_name":"Qwen3.8 27B","architecture":"qwen3",
       "max_context_length":262144,"format":"gguf",
       "loaded_instances":[{"id":"qwen/qwen3.8-27b","config":{"context_length":32768}}],
       "capabilities":{"vision":false,"trained_for_tool_use":false}},
      {"type":"embedding","publisher":"nomic-ai","key":"text-embedding-nomic-embed-text-v1.5","display_name":"Nomic Embed Text v1.5"}
    ]}
    """
    static let openAIList = #"{"object":"list","data":[{"id":"qwen/qwen3.8-27b","object":"model","owned_by":"organization_owner"},{"id":"text-embedding-nomic-embed-text-v1.5","object":"model","owned_by":"organization_owner"}]}"#

    func testANewCustomConnectionGetsTheStandardToolFormat() {
        let c = RemoteConnection(name: "LM Studio", apiBaseURL: url)
        XCTAssertEqual(c.encoding, .openAIChatCompletions, "Add Custom Connection starts on Standard, not Automatic")
        XCTAssertEqual(RemoteConnection.lmStudioPreset().encoding, .automatic)
    }

    /// The red case: port 41234, Standard Tool Format, LM Studio reported trained_for_tool_use=false.
    func testPort41234WithTrainedForToolUseFalseIsNeverMarkedWithoutTools() {
        var c = RemoteConnection(name: "LM Studio", apiBaseURL: url)
        c.availableModels = [qwen]
        c.modelToolSupport = [qwen: false]
        XCTAssertNotEqual(ModelToolSupportCatalog.support(modelID: qwen, connection: c), .unsupported)
        let state = ToolModelPolicy.availability(of: choice(qwen, on: c), connection: c,
                                                 store: ToolCallVerificationStore(defaults: freshDefaults()),
                                                 usableEncodings: toolCapableEncodings)
        XCTAssertNotEqual(state, .unavailable(ToolModelPolicy.noToolsReason))
        XCTAssertTrue(state.isSelectable, "the Test Tool Calls button and the picker stay usable")
    }

    func testAPassedTestBeatsTheProvidersMetadata() {
        var c = RemoteConnection(name: "Router", apiBaseURL: "https://router.test/api/v1")
        c.availableModels = [qwen]
        c.modelToolSupport = [qwen: false]
        let store = ToolCallVerificationStore(defaults: freshDefaults())
        store.record(passed: true, for: choice(qwen, on: c).selectionKey)
        XCTAssertEqual(ToolModelPolicy.availability(of: choice(qwen, on: c), connection: c, store: store,
                                                    usableEncodings: toolCapableEncodings), .ready)
    }

    /// The fresh-connection case: delete, re-add on :41234, refresh. LM Studio has to be recognised
    /// from its own API, not the port, and its native list has to be read.
    @MainActor
    func testAFreshConnectionOnPort41234IsRecognisedAsLMStudio() async throws {
        let defaults = freshDefaults("fresh")
        let settings = ProviderSettings(defaults: defaults, apiKeyStore: RemoteAPIKeyStore(secureStore: MemorySecureStore()))
        let c = RemoteConnection(name: "LM Studio", apiBaseURL: url)
        settings.updateConnection(c)
        ModelsListStub.asked = []
        ModelsListStub.bodies = ["/v1/models": Self.openAIList, "/api/v1/models": Self.v1Models]
        let models = try await RemoteLLMService(settings: settings, session: ModelsListStub.session).queryModels(for: c.id)
        XCTAssertEqual(models.map(\.id), [qwen, "text-embedding-nomic-embed-text-v1.5"])
        XCTAssertTrue(ModelsListStub.asked.contains("http://192.168.1.100:41234/api/v1/models"), "\(ModelsListStub.asked)")
        let saved = try XCTUnwrap(settings.connection(id: c.id))
        XCTAssertTrue(saved.servesLMStudioTools, "recognised from LM Studio's own model list on any port")
        XCTAssertEqual(saved.modelToolSupport?[qwen], true)
        XCTAssertEqual(ModelToolSupportCatalog.support(modelID: qwen, connection: saved), .supported)
        XCTAssertEqual(ToolModelPolicy.availability(of: choice(qwen, on: saved), connection: saved,
                                                    store: ToolCallVerificationStore(defaults: defaults),
                                                    usableEncodings: toolCapableEncodings), .needsTest)
    }

    func testSavedFailuresFromBeforeTheFixAreClearedOnce() {
        let defaults = freshDefaults("upgrade")
        defaults.set(["remote|old|\(qwen)": false, "remote|old|grok-4": true], forKey: "aiconnect.toolCallVerification")
        let store = ToolCallVerificationStore(defaults: defaults)
        XCTAssertNil(store.result(for: "remote|old|\(qwen)"), "a failure saved by an older build is retested")
        XCTAssertEqual(store.result(for: "remote|old|grok-4"), true, "passes are kept")
        store.record(passed: false, for: "remote|old|\(qwen)")
        XCTAssertEqual(ToolCallVerificationStore(defaults: defaults).result(for: "remote|old|\(qwen)"), false,
                       "only cleared once: a new failure sticks until the next test")
    }

    func testVerdictsBelongToOneConnection() {
        let store = ToolCallVerificationStore(defaults: freshDefaults())
        let first = RemoteConnection(name: "LM Studio", apiBaseURL: url)
        let second = RemoteConnection(name: "LM Studio", apiBaseURL: url)
        XCTAssertNotEqual(choice(qwen, on: first).selectionKey, choice(qwen, on: second).selectionKey)
        store.record(passed: false, for: choice(qwen, on: first).selectionKey)
        XCTAssertNil(store.result(for: choice(qwen, on: second).selectionKey), "a recreated connection starts untested")
    }

    @MainActor
    func testDeletingAConnectionForgetsItsToolTests() {
        let defaults = freshDefaults("delete")
        let settings = ProviderSettings(defaults: defaults, apiKeyStore: RemoteAPIKeyStore(secureStore: MemorySecureStore()))
        let c = RemoteConnection(name: "LM Studio", apiBaseURL: url)
        settings.updateConnection(c)
        let store = ToolCallVerificationStore(defaults: defaults)
        store.record(passed: false, for: choice(qwen, on: c).selectionKey)
        settings.removeConnection(id: c.id)
        XCTAssertNil(ToolCallVerificationStore(defaults: defaults).result(for: choice(qwen, on: c).selectionKey))
    }
}

/// The fix's own API: Test Tool Calls offered for "Doesn't support tools", detection persisted.
final class LMStudioDetectionTests: XCTestCase {
    func testTestToolCallsIsOfferedEvenWhenMarkedWithoutTools() {
        let noTools = ToolModelAvailability.unavailable(ToolModelPolicy.noToolsReason)
        XCTAssertTrue(noTools.canRunToolTest)
        XCTAssertTrue(noTools.runsTestWhenPicked, "picking it runs the test instead of doing nothing")
        XCTAssertFalse(noTools.isSelectable, "it still can't be used before a test passes")
        for state in [ToolModelAvailability.ready, .needsTest, .failedTest] { XCTAssertTrue(state.canRunToolTest) }
        XCTAssertFalse(ToolModelAvailability.unavailable(ToolModelPolicy.protocolReason).canRunToolTest)
        XCTAssertFalse(ToolModelAvailability.unavailable("Connection missing").canRunToolTest)
    }

    func testLMStudioIsRecognisedFromItsOwnListOnAnyPort() throws {
        XCTAssertTrue(LMStudioNativeModels.isLMStudioList(Data(LMStudioAnyPortToolCheckTests.v1Models.utf8)))
        let v0 = #"{"object":"list","data":[{"id":"qwen/qwen3.8-27b","object":"model","type":"llm","arch":"qwen3","compatibility_type":"gguf","state":"loaded"}]}"#
        XCTAssertTrue(LMStudioNativeModels.isLMStudioList(Data(v0.utf8)))
        XCTAssertFalse(LMStudioNativeModels.isLMStudioList(Data(LMStudioAnyPortToolCheckTests.openAIList.utf8)),
                       "a plain OpenAI list is not proof")
        XCTAssertFalse(LMStudioNativeModels.isLMStudioList(Data(#"{"models":[{"name":"llama3.2","model":"llama3.2"}]}"#.utf8)),
                       "Ollama's list is not LM Studio")

        var c = RemoteConnection(name: "LM Studio", apiBaseURL: "http://192.168.1.100:41234/v1")
        XCTAssertFalse(c.servesLMStudioTools)
        XCTAssertTrue(c.mayServeLMStudio, "a local-network server on any port is asked for LM Studio's list")
        XCTAssertFalse(LMStudioNativeModels.nativeListURLs(for: c).isEmpty)
        c.recordServer(isLMStudio: true, isOllama: false)
        XCTAssertTrue(c.servesLMStudioTools)
        let decoded = try JSONDecoder().decode(RemoteConnection.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(decoded.detectedLMStudio, true, "saved with the connection")

        let cloud = RemoteConnection(name: "Router", apiBaseURL: "https://router.test/api/v1")
        XCTAssertFalse(cloud.mayServeLMStudio)
        XCTAssertTrue(LMStudioNativeModels.nativeListURLs(for: cloud).isEmpty)
    }

    func testAConnectionSavedBeforeTheFieldExistedStillDecodes() throws {
        let old = #"{"id":"lm","name":"LM Studio","apiBaseURL":"http://192.168.1.100:41234/v1","apiKey":"","defaultModel":"qwen/qwen3.8-27b","availableModels":["qwen/qwen3.8-27b"],"encoding":"openAIChatCompletions","isEnabled":true,"modelToolSupport":{"qwen/qwen3.8-27b":false}}"#
        let c = try JSONDecoder().decode(RemoteConnection.self, from: Data(old.utf8))
        XCTAssertNil(c.detectedLMStudio)
        XCTAssertNotEqual(ModelToolSupportCatalog.support(modelID: "qwen/qwen3.8-27b", connection: c), .unsupported,
                          "A saved connection is unblocked even before its next model refresh")
    }

    /// Requirement: LM Studio can run on any port, so the port never decides. 1234, 41234 and a random
    /// port behave the same: unknown until the server answers, LM Studio once it does.
    @MainActor
    func testDetectionIsTheSameOnEveryPort() async throws {
        for port in [1234, 41234, 47_213] {
            let defaults = UserDefaults(suiteName: "port-\(port)-\(UUID().uuidString)")!
            let settings = ProviderSettings(defaults: defaults, apiKeyStore: RemoteAPIKeyStore(secureStore: MemorySecureStore()))
            var c = RemoteConnection(name: "LM Studio", apiBaseURL: "http://192.168.1.100:\(port)/v1")
            c.modelToolSupport = ["qwen/qwen3.8-27b": false]
            XCTAssertFalse(c.servesLMStudioTools, "port \(port) alone is not LM Studio")
            XCTAssertEqual(c.detectedServerLabel, "Not checked yet")
            settings.updateConnection(c)

            ModelsListStub.bodies = ["/v1/models": LMStudioAnyPortToolCheckTests.openAIList]
            let service = RemoteLLMService(settings: settings, session: ModelsListStub.session)
            _ = try await service.queryModels(for: c.id)
            XCTAssertEqual(settings.connection(id: c.id)?.detectedLMStudio, false, "port \(port): a plain OpenAI server")
            XCTAssertEqual(settings.connection(id: c.id)?.servesLMStudioTools, false)

            ModelsListStub.bodies = ["/v1/models": LMStudioAnyPortToolCheckTests.openAIList,
                                     "/api/v1/models": LMStudioAnyPortToolCheckTests.v1Models]
            let detected = await service.detectServer(for: c.id)
            XCTAssertEqual(detected, true, "port \(port)")
            let saved = try XCTUnwrap(settings.connection(id: c.id))
            XCTAssertTrue(saved.servesLMStudioTools, "port \(port)")
            XCTAssertEqual(saved.detectedServerLabel, "LM Studio")
            XCTAssertEqual(saved.modelToolSupport?["qwen/qwen3.8-27b"], true, "port \(port)")
            XCTAssertEqual(ModelToolSupportCatalog.support(modelID: "qwen/qwen3.8-27b", connection: saved), .supported)
        }
    }

    func testNoPortIsSpecialAnywhere() {
        XCTAssertEqual(OpenAICompatibleAPI.detectProvider(baseURL: "http://192.168.1.100:1234/v1"),
                       OpenAICompatibleAPI.detectProvider(baseURL: "http://192.168.1.100:41234/v1"))
        for port in [1234, 41234, 47_213] {
            let c = RemoteConnection(name: "x", apiBaseURL: "http://192.168.1.100:\(port)/v1")
            XCTAssertFalse(c.servesLMStudioTools, "\(port)")
            XCTAssertTrue(c.mayServeLMStudio, "\(port)")
        }
    }
}

