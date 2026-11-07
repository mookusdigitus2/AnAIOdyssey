// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import XCTest
import AnAIOdysseyAI

/// Live tests against an OpenAI-compatible server (e.g. LM Studio) on your
/// network. They skip unless `ODYSSEY_LIVE_LLM_URL` is set, for example:
///
///     TEST_RUNNER_ODYSSEY_LIVE_LLM_URL=http://<lan-host>:<port>/v1 \
///     TEST_RUNNER_ODYSSEY_LIVE_LLM_MODEL=qwen/qwen3-coder-next \
///     xcodebuild test ...
enum RemoteLLMTestFixtures {
    static let environment = ProcessInfo.processInfo.environment
    static let baseURL = environment["ODYSSEY_LIVE_LLM_URL"] ?? ""
    static let modelID = environment["ODYSSEY_LIVE_LLM_MODEL"] ?? "qwen/qwen3-coder-next"
    static let testPrompt = "What is a gekko?"

    static func matchesCoderNext(_ modelID: String) -> Bool {
        modelID == Self.modelID
            || (modelID as NSString).lastPathComponent == (Self.modelID as NSString).lastPathComponent
    }
}

@MainActor
final class RemoteLLMIntegrationTests: XCTestCase {
    private var defaults: UserDefaults!
    private var settings: ProviderSettings!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "RemoteLLMIntegrationTests-\(UUID().uuidString)")!
        settings = ProviderSettings(defaults: defaults)
        settings.remoteConnections = [
            RemoteConnection(
                id: "integration-test",
                name: "LAN LLM",
                apiBaseURL: RemoteLLMTestFixtures.baseURL,
                defaultModel: RemoteLLMTestFixtures.modelID,
                encoding: .lmStudioHarmony
            ),
        ]
    }

    override func tearDown() {
        settings = nil
        defaults.removePersistentDomain(forName: defaults.description)
        defaults = nil
        super.tearDown()
    }

    func testQueryModelsIncludesQwenCoderNext() async throws {
        try await requireRemoteServer()

        let service = RemoteLLMService(settings: settings)
        service.setActiveConnection(id: "integration-test", modelID: RemoteLLMTestFixtures.modelID)
        let models = try await service.queryModels()
        let ids = models.map(\.id)

        XCTAssertTrue(
            ids.contains(where: RemoteLLMTestFixtures.matchesCoderNext),
            "Expected qwen3-coder-next in \(ids)"
        )
        let saved = settings.connection(id: "integration-test")?.availableModels ?? []
        XCTAssertTrue(
            saved.contains(where: RemoteLLMTestFixtures.matchesCoderNext),
            "Expected the connection to keep qwen3-coder-next, got \(saved)"
        )
    }

    func testModelSelectionIncludesRemoteQwenCoderNext() async throws {
        try await requireRemoteServer()

        let service = RemoteLLMService(settings: settings)
        service.setActiveConnection(id: "integration-test", modelID: RemoteLLMTestFixtures.modelID)
        _ = try await service.queryModels()

        let choices = ConfiguredModelRegistry.availableChoices(providerSettings: settings)
        XCTAssertTrue(
            choices.contains {
                $0.backend == .remote && RemoteLLMTestFixtures.matchesCoderNext($0.id)
            }
        )

        let backend = ConfiguredModelRegistry.inferredBackend(
            for: settings.remoteModel,
            providerSettings: settings
        )
        XCTAssertEqual(backend, .remote)
    }

    func testReachQwenCoderNextWithGekkoQuestion() async throws {
        try await requireRemoteServer()

        let service = RemoteLLMService(settings: settings)
        service.setActiveConnection(id: "integration-test", modelID: RemoteLLMTestFixtures.modelID)
        let models = try await service.queryModels()
        let resolved = OpenAICompatibleAPI.resolvedModelID(
            requested: RemoteLLMTestFixtures.modelID,
            available: models.map(\.id)
        )

        try await service.loadSelectedModel()
        let response = try await service.completeResponse(to: RemoteLLMTestFixtures.testPrompt)

        let lower = response.lowercased()
        XCTAssertTrue(RemoteLLMTestFixtures.matchesCoderNext(resolved), "Resolved \(resolved)")
        XCTAssertFalse(response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertTrue(
            lower.contains("gecko") || lower.contains("gekkota") || lower.contains("lizard"),
            "Expected a gekko/gecko answer, got: \(response.prefix(200))"
        )
    }

    func testStreamReplyFromQwenCoderNext() async throws {
        try await requireRemoteServer()

        let service = RemoteLLMService(settings: settings)
        service.setActiveConnection(id: "integration-test", modelID: RemoteLLMTestFixtures.modelID)
        try await service.loadSelectedModel()

        var response = ""
        let stream = service.streamResponse(to: "Reply with exactly the word pong.", history: [])
        for try await chunk in stream {
            response += chunk
        }

        XCTAssertFalse(
            response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "Streaming reply was empty"
        )
        XCTAssertTrue(
            response.lowercased().contains("pong"),
            "Expected pong, got: \(response.prefix(300))"
        )
    }

    private func requireRemoteServer() async throws {
        if ProcessInfo.processInfo.environment["REMOTE_LLM_TESTS"] == "0" {
            throw XCTSkip("Remote LLM integration tests disabled (REMOTE_LLM_TESTS=0)")
        }
        if RemoteLLMTestFixtures.baseURL.isEmpty {
            throw XCTSkip("Set ODYSSEY_LIVE_LLM_URL to run the live LLM integration tests")
        }
        if let failure = await Self.reachabilityFailure() {
            throw XCTSkip("Remote LLM server not reachable at \(RemoteLLMTestFixtures.baseURL): \(failure)")
        }
    }

    private static func reachabilityFailure() async -> String? {
        guard let url = OpenAICompatibleAPI.buildModelsURL(baseURL: RemoteLLMTestFixtures.baseURL) else {
            return "invalid models URL"
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return "invalid response" }
            guard (200...299).contains(http.statusCode) else { return "HTTP \(http.statusCode)" }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
