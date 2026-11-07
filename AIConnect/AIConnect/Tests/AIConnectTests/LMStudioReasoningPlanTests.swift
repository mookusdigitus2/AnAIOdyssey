// SPDX-License-Identifier: MIT
import XCTest
@testable import AIConnect
import AIModelOptions

/// The request plan only sends a thinking level the user picked. LM Studio's model list
/// (`capabilities.reasoning`) is not copied into requests: its `high` crashes Qwen3.8's template.
final class LMStudioReasoningPlanTests: XCTestCase {
    private func lmStudio(_ id: String, live: [String: LiveModelCapabilities]) -> RemoteConnection {
        RemoteConnection(id: id, name: "LM Studio", apiBaseURL: "http://localhost:1234/v1", encoding: .automatic,
                         liveModelCapabilities: live)
    }

    func testNoStoredLevelSendsNothingEvenWhenLMStudioListsOne() {
        let c = lmStudio("plan-lms-1", live: [
            "qwen/qwen3.8-27b": LiveModelCapabilities(reasoningEfforts: [.low, .medium, .high], defaultReasoningEffort: .high),
            "other/thinker": LiveModelCapabilities(reasoningEfforts: [.low, .high], defaultReasoningEffort: .high),
        ])
        defer { ModelGenerationSettings.removeOptions(connectionID: c.id) }
        XCTAssertNil(ConnectionRequestPlan.resolve(connection: c, modelID: "qwen/qwen3.8-27b", hasTools: true).reasoningEffort)
        XCTAssertNil(ConnectionRequestPlan.resolve(connection: c, modelID: "other/thinker", hasTools: true).reasoningEffort)
    }

    func testPickedLevelIsSentOnlyWhenTheTemplateTakesIt() {
        let c = lmStudio("plan-lms-2", live: [
            "qwen/qwen3.8-27b": LiveModelCapabilities(reasoningEfforts: [.low, .medium, .high], defaultReasoningEffort: .high),
        ])
        defer { ModelGenerationSettings.removeOptions(connectionID: c.id) }
        ModelGenerationSettings.setOptions(ModelGenerationOptions(reasoningEffort: .low), connectionID: c.id, modelID: "qwen/qwen3.8-27b")
        XCTAssertEqual(ConnectionRequestPlan.resolve(connection: c, modelID: "qwen/qwen3.8-27b", hasTools: true).reasoningEffort, .low)
        ModelGenerationSettings.setOptions(ModelGenerationOptions(reasoningEffort: .high), connectionID: c.id, modelID: "qwen/qwen3.8-27b")
        XCTAssertNil(ConnectionRequestPlan.resolve(connection: c, modelID: "qwen/qwen3.8-27b", hasTools: true).reasoningEffort,
                     "high would hit raise_exception in the template")
    }

    func testInconclusiveToolTestIsNotRecorded() throws {
        let suite = "tool-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ToolCallVerificationStore(defaults: defaults)
        let key = "remote|lms|qwen/qwen3.8-27b"
        XCTAssertFalse(store.recordIfConclusive(passed: nil, for: key))
        XCTAssertNil(store.result(for: key), "a timeout or server error is not a failed test")
        XCTAssertTrue(store.recordIfConclusive(passed: false, for: key))
        XCTAssertEqual(store.result(for: key), false)
        XCTAssertTrue(store.recordIfConclusive(passed: true, for: key))
        XCTAssertEqual(store.result(for: key), true)
    }
}
