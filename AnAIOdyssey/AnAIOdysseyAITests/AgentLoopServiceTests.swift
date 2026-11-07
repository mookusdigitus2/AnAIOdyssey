// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import XCTest
@testable import AnAIOdysseyAI
@testable import AIConnect
@testable import AIConnectVoice
import AnAIOdysseyCore
import AIModelOptions

final class AgentToolParserExtendedTests: XCTestCase {
    func testParsesSingleLineFencedToolBlocks() {
        let text = "Here you go:\n```list_tasks```\nDone."
        let blocks = AgentToolParser.parseToolBlocks(from: text, tags: ["list_tasks"])
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].toolType, "list_tasks")
        XCTAssertTrue(blocks[0].content.isEmpty)
    }

    func testParsesMultilineSearchFence() {
        let text = "```search\nquarterly report\nlimit: 5\n```"
        let blocks = AgentToolParser.parseToolBlocks(from: text, tags: ["search"])
        XCTAssertEqual(blocks.count, 1)
        XCTAssertTrue(blocks[0].content.contains("quarterly report"))
    }
}

final class AgentLoopConversationTests: XCTestCase {
    @MainActor
    func testDoesNotDuplicateToolResultTurns() async {
        let mock = SequenceLLMService()
        let (context, repos) = try! TestModelContainer.makeRepositories()
        let vectorURL = FileManager.default.temporaryDirectory.appendingPathComponent("agent-loop-test.sqlite")
        try? FileManager.default.removeItem(at: vectorURL)
        let memory = MemoryService(
            memories: repos.memories,
            vectorStore: try! VectorIndexStore(databaseURL: vectorURL),
            embeddingService: MockEmbeddingService()
        )
        let loop = AgentLoopService(
            llmService: mock,
            repositories: repos,
            memoryService: memory,
            maxRounds: 3
        )
        let agentContext = AgentContext(sessionID: "s1", repositories: repos, memoryService: memory)

        for await _ in loop.run(prompt: "list tasks", history: [], context: agentContext) {}

        let userTurns = mock.recordedMessages.filter { $0.role == "user" }
        let toolResultTurns = userTurns.filter { $0.content.contains("[list_tasks]") }
        XCTAssertLessThanOrEqual(toolResultTurns.count, 1)
        _ = context
    }

    func testRecordsAssistantToolCallsAndToolTurns() {
        let blocks = LLMChatToolHistory.assigningCallIDs([
            ToolCallBlock(toolType: "list_tasks", content: "{}", callID: "call_tasks"),
        ])
        var conversation = [LLMChatTurn(role: "user", content: "list tasks")]
        conversation.append(LLMChatToolHistory.assistantTurn(text: "", blocks: blocks))
        conversation.append(contentsOf: LLMChatToolHistory.toolTurns(outputs: [
            EncodedFunctionCallOutput(callID: "call_tasks", output: "none"),
        ]))
        XCTAssertEqual(conversation.map(\.role), ["user", "assistant", "tool"])
        XCTAssertEqual(conversation[1].toolCalls.first?.callID, "call_tasks")
        XCTAssertEqual(conversation[2].toolCallID, "call_tasks")
    }
}

@MainActor
private final class SequenceLLMService: LLMServiceProtocol {
    struct Turn: Equatable { let role: String; let content: String }
    private(set) var recordedMessages: [Turn] = []
    private var round = 0

    var selectedModelID: String = LLMModelCatalog.defaultModelID
    var isModelLoaded: Bool = true
    var loadProgress: Double?
    var loadStatus: String = "test"
    var usesMLXBackend: Bool = false

    func availableModels() -> [LLMModelOption] { LLMModelCatalog.models }
    func loadSelectedModel() async throws { isModelLoaded = true }

    func streamResponse(to prompt: String, history: [LLMChatTurn]) -> AsyncThrowingStream<String, Error> {
        recordedMessages = history
            .filter { $0.role == "user" || $0.role == "assistant" }
            .map { Turn(role: $0.role, content: $0.content) }

        return AsyncThrowingStream { continuation in
            Task {
                round += 1
                if round == 1 {
                    continuation.yield("Checking tasks.\n```list_tasks\n```")
                } else {
                    continuation.yield("You have no tasks.")
                }
                continuation.finish()
            }
        }
    }
}
