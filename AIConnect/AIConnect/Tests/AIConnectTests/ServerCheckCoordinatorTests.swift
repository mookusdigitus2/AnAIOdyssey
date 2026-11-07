// SPDX-License-Identifier: MIT
import XCTest
@testable import AIConnect
import AIModelOptions

/// PR #229 re-review at d346b72. R1: the agent waits only for its own connection's server, and
/// at most a couple of seconds; never for cloud or on-device models. R3: a row with no answer is
/// checked again on the agent path. Non-blocker 3: the editor's Server line stays current.
@MainActor
final class ServerCheckCoordinatorTests: XCTestCase {
    private let qwen = "qwen3.8:27b"

    override func setUp() { ModelsListStub.reset() }
    override func tearDown() { ModelsListStub.reset() }

    private func settings() -> ProviderSettings {
        ProviderSettings(defaults: UserDefaults(suiteName: "checks-\(UUID().uuidString)")!,
                         apiKeyStore: RemoteAPIKeyStore(secureStore: MemorySecureStore()))
    }

    func testTheSendWaitsAtMostTheCap() async throws {
        let s = settings()
        let c = RemoteConnection(name: "LM Studio", apiBaseURL: "http://192.168.1.100:1234/v1")
        s.updateConnection(c)
        ModelsListStub.bodies = ["/api/v1/models": LMStudioAnyPortToolCheckTests.v1Models]
        ModelsListStub.delay = 0.8
        let checks = ServerCheckCoordinator(settings: s, session: ModelsListStub.session)
        XCTAssertTrue(checks.needsCheck(connectionID: c.id))
        let started = Date()
        await checks.checkBeforeSend(connectionID: c.id, waitingAtMost: 0.2)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.6)
        XCTAssertNil(s.connection(id: c.id)?.currentLMStudioDetection, "still checking")
        // The check carries on after the cap and saves its answer.
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertEqual(s.connection(id: c.id)?.currentLMStudioDetection, true)
    }

    func testNoWaitForCloudOrOnDeviceModels() async throws {
        let s = settings()
        let cloud = RemoteConnection(name: "OpenAI", apiBaseURL: "https://api.openai.com/v1")
        s.updateConnection(cloud)
        let checks = ServerCheckCoordinator(settings: s, session: ModelsListStub.session)
        XCTAssertFalse(checks.needsCheck(connectionID: cloud.id))
        XCTAssertFalse(checks.needsCheck(connectionID: nil), "on-device models have no connection")
        await checks.checkBeforeSend(connectionID: cloud.id)
        await checks.checkBeforeSend(connectionID: nil)
        XCTAssertEqual(ModelsListStub.asked, [])
    }

    func testAnAlreadyCheckedServerIsNotAskedAgain() async throws {
        let s = settings()
        var c = RemoteConnection(name: "LM Studio", apiBaseURL: "http://192.168.1.100:1234/v1")
        c.recordServer(isLMStudio: true, isOllama: false)
        s.updateConnection(c)
        let checks = ServerCheckCoordinator(settings: s, session: ModelsListStub.session)
        XCTAssertFalse(checks.needsCheck(connectionID: c.id))
        await checks.checkBeforeSend(connectionID: c.id)
        XCTAssertEqual(ModelsListStub.asked, [])
    }

    /// R3: Ollama on an Automatic row was off at launch; the next send finds it.
    func testTheAgentPathRechecksARowThatHadNoAnswerAtLaunch() async throws {
        let s = settings()
        let c = RemoteConnection(name: "Ollama", apiBaseURL: "http://192.168.1.50:8080/v1", encoding: .automatic)
        s.updateConnection(c)
        let checks = ServerCheckCoordinator(settings: s, session: ModelsListStub.session)
        ModelsListStub.unreachable = true
        checks.startLaunchChecks()
        await checks.checkBeforeSend(connectionID: c.id)
        XCTAssertNil(s.connection(id: c.id)?.currentLMStudioDetection, "off at launch: no answer")
        XCTAssertTrue(checks.needsCheck(connectionID: c.id))

        ModelsListStub.unreachable = false
        ModelsListStub.bodies = ["/api/version": #"{"version":"0.12.3"}"#]
        await checks.checkBeforeSend(connectionID: c.id)
        let saved = try XCTUnwrap(s.connection(id: c.id))
        XCTAssertEqual(saved.apiProvider, .ollama)
        XCTAssertFalse(LocalChatHistoryPolicy.sendsToolArgumentsAsObjects(connection: saved, modelID: qwen, usesResponsesAPI: false))
    }

    /// Non-blocker 3: the editor's copy shows (and saves) the latest server answer for its URL.
    func testTheEditorCopyPicksUpTheLatestServerAnswer() {
        let draft = RemoteConnection(name: "Box", apiBaseURL: "http://192.168.1.100:1234/v1")
        var saved = draft
        saved.recordServer(isLMStudio: true, isOllama: false)
        XCTAssertEqual(draft.detectedServerLabel, "Not checked yet")
        XCTAssertEqual(draft.withServerDetection(from: saved).detectedServerLabel, "LM Studio")
        XCTAssertEqual(draft.withServerDetection(from: nil).detectedServerLabel, "Not checked yet")
        var repointed = draft
        repointed.apiBaseURL = "http://192.168.1.50:8000/v1"
        XCTAssertEqual(repointed.withServerDetection(from: saved).detectedServerLabel, "Not checked yet",
                       "an answer for another URL doesn't apply")
    }
}
