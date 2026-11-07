// SPDX-License-Identifier: MIT
import XCTest
@testable import AIConnect
import AIModelOptions

/// PR #229 re-review at d346b72. N1: only 404/405, or a successful reply that isn't LM Studio's
/// list, says "not LM Studio"; an auth error, a rate limit, a timeout status or a server error
/// is no answer. R1: no redundant waits. R2: a refresh that raced a URL change is dropped.
@MainActor
final class ServerDetectionAnswerTests: XCTestCase {
    private let qwen = "qwen/qwen3.8-27b"
    private let native = ["/api/v1/models", "/api/v0/models"]

    override func setUp() { ModelsListStub.reset() }
    override func tearDown() { ModelsListStub.reset() }

    private func settings() -> ProviderSettings {
        ProviderSettings(defaults: UserDefaults(suiteName: "answers-\(UUID().uuidString)")!,
                         apiKeyStore: RemoteAPIKeyStore(secureStore: MemorySecureStore()))
    }

    /// A Standard row on any port that LM Studio's own list already identified.
    private func knownLMStudio(_ s: ProviderSettings, url: String = "http://192.168.1.100:1234/v1") -> RemoteConnection {
        var c = RemoteConnection(name: "LM Studio", apiBaseURL: url, availableModels: [qwen])
        c.recordServer(isLMStudio: true, isOllama: false)
        s.updateConnection(c)
        return c
    }

    private func bothNativeLists(answer status: Int) {
        ModelsListStub.bodies = ["/v1/models": LMStudioAnyPortToolCheckTests.openAIList]
        ModelsListStub.statuses = Dictionary(uniqueKeysWithValues: native.map { ($0, status) })
    }

    private func assertKeptLMStudio(after status: Int, file: StaticString = #filePath, line: UInt = #line) async throws {
        let s = settings()
        let c = knownLMStudio(s)
        bothNativeLists(answer: status)
        let service = RemoteLLMService(settings: s, session: ModelsListStub.session)
        await service.detectServer(for: c.id)
        XCTAssertEqual(s.connection(id: c.id)?.detectedLMStudio, true, "detectServer after \(status)", file: file, line: line)
        _ = try? await service.queryModels(for: c.id)
        let saved = try XCTUnwrap(s.connection(id: c.id))
        XCTAssertEqual(saved.detectedLMStudio, true, "queryModels after \(status)", file: file, line: line)
        XCTAssertTrue(LocalChatHistoryPolicy.sendsToolArgumentsAsObjects(connection: saved, modelID: qwen, usesResponsesAPI: false),
                      "\(status) must not switch LM Studio's object arguments off", file: file, line: line)
    }

    func test401IsNoAnswer() async throws { try await assertKeptLMStudio(after: 401) }
    func test403IsNoAnswer() async throws { try await assertKeptLMStudio(after: 403) }
    func test408IsNoAnswer() async throws { try await assertKeptLMStudio(after: 408) }
    func test429IsNoAnswer() async throws { try await assertKeptLMStudio(after: 429) }
    func test500IsNoAnswer() async throws { try await assertKeptLMStudio(after: 500) }
    func test502IsNoAnswer() async throws { try await assertKeptLMStudio(after: 502) }
    func test503IsNoAnswer() async throws { try await assertKeptLMStudio(after: 503) }
    func test504IsNoAnswer() async throws { try await assertKeptLMStudio(after: 504) }

    func test404And405AreANo() async throws {
        for status in [404, 405] {
            let s = settings()
            let c = knownLMStudio(s)
            bothNativeLists(answer: status)
            await RemoteLLMService(settings: s, session: ModelsListStub.session).detectServer(for: c.id)
            XCTAssertEqual(s.connection(id: c.id)?.detectedLMStudio, false, "\(status)")
        }
    }

    func testAPlainListOnBothIsANo() async throws {
        let s = settings()
        let c = knownLMStudio(s)
        ModelsListStub.bodies = Dictionary(uniqueKeysWithValues: (native + ["/v1/models"]).map { ($0, LMStudioAnyPortToolCheckTests.openAIList) })
        await RemoteLLMService(settings: s, session: ModelsListStub.session).detectServer(for: c.id)
        XCTAssertEqual(s.connection(id: c.id)?.detectedLMStudio, false)
    }

    /// A "no" saved by builds 55–58 may have come from an error status: the launch check asks again.
    func testANoSavedByAnEarlierBuildIsCheckedAgainAtLaunch() async throws {
        let s = settings()
        var c = RemoteConnection(name: "LM Studio", apiBaseURL: "http://192.168.1.100:1234/v1", encoding: .automatic)
        c.recordServer(isLMStudio: false, isOllama: false)
        // Saved by build 58: the same fields, without anything newer.
        let json = try JSONEncoder().encode(c)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        object.removeValue(forKey: "detectionVersion")
        let old = try JSONDecoder().decode(RemoteConnection.self, from: JSONSerialization.data(withJSONObject: object))
        s.updateConnection(old)
        XCTAssertTrue(s.connection(id: c.id)?.servesLMStudioTools == true, "an old \"no\" isn't trusted: the Automatic preset counts until checked")
        ModelsListStub.bodies = ["/v1/models": LMStudioAnyPortToolCheckTests.openAIList,
                                 "/api/v1/models": LMStudioAnyPortToolCheckTests.v1Models]
        await RemoteLLMService(settings: s, session: ModelsListStub.session).detectServersIfNeeded()
        XCTAssertEqual(s.connection(id: c.id)?.detectedLMStudio, true)
    }

    /// R1: a server that answered neither LM Studio list isn't asked for /v1/models as well.
    func testNoThirdFetchWhenNeitherListAnswered() async throws {
        let s = settings()
        let c = knownLMStudio(s)
        ModelsListStub.unreachable = true
        await RemoteLLMService(settings: s, session: ModelsListStub.session).detectServer(for: c.id)
        let paths = ModelsListStub.asked.compactMap { URL(string: $0)?.path }
        XCTAssertFalse(paths.contains("/v1/models"), "\(paths)")
    }

    /// R1: the launch check asks every server at once.
    func testLaunchChecksRunInParallel() async throws {
        let s = settings()
        var ids: [String] = []
        for i in 0..<3 {
            let c = RemoteConnection(name: "LM \(i)", apiBaseURL: "http://192.168.1.\(140 + i):1234/v1")
            s.updateConnection(c)
            ids.append(c.id)
        }
        ModelsListStub.bodies = ["/api/v1/models": LMStudioAnyPortToolCheckTests.v1Models]
        ModelsListStub.delay = 0.4
        let started = Date()
        await RemoteLLMService(settings: s, session: ModelsListStub.session).detectServersIfNeeded()
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(ids.map { s.connection(id: $0)?.detectedLMStudio }, [true, true, true])
        XCTAssertLessThan(elapsed, 1.0, "3 servers × 0.4 s one after another would take 1.2 s")
    }

    /// R2: a refresh whose URL changed while it ran doesn't write the old server's models.
    func testARefreshThatRacedAURLChangeIsDropped() async throws {
        let s = settings()
        let c = RemoteConnection(name: "Box", apiBaseURL: "http://192.168.1.100:1234/v1")
        s.updateConnection(c)
        ModelsListStub.bodies = ["/v1/models": LMStudioAnyPortToolCheckTests.openAIList,
                                 "/api/v1/models": LMStudioAnyPortToolCheckTests.v1Models]
        ModelsListStub.delay = 0.3
        let service = RemoteLLMService(settings: s, session: ModelsListStub.session)
        async let refresh = try? service.queryModels(for: c.id)
        try await Task.sleep(nanoseconds: 100_000_000)
        var edited = try XCTUnwrap(s.connection(id: c.id))
        edited.apiBaseURL = "http://192.168.1.50:8000/v1"
        s.updateConnection(edited)
        _ = await refresh
        let saved = try XCTUnwrap(s.connection(id: c.id))
        XCTAssertEqual(saved.apiBaseURL, "http://192.168.1.50:8000/v1")
        XCTAssertFalse(saved.availableModels.contains(qwen), "the old server's models")
        XCTAssertNil(saved.modelToolSupport, "the old server's tool flags")
        XCTAssertNil(saved.currentLMStudioDetection)
    }
}
