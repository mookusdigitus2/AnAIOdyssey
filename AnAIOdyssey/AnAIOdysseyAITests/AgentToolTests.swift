// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import XCTest
@testable import AnAIOdysseyAI
@testable import AIConnect
@testable import AIConnectVoice
import AnAIOdysseyCore

@MainActor
final class AgentToolTests: XCTestCase {
    private var repositories: RepositoryBundle!
    private var memoryService: MemoryService!
    private var registry: AgentToolRegistry!
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-tool-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        let (_, repos) = try TestModelContainer.makeRepositories()
        repositories = repos
        let vectorStore = try VectorIndexStore(
            databaseURL: tempDirectory.appendingPathComponent("vectors.sqlite")
        )
        memoryService = MemoryService(
            memories: repos.memories,
            vectorStore: vectorStore,
            embeddingService: MockEmbeddingService()
        )
        registry = AgentToolRegistry.standard(repositories: repos, memoryService: memoryService)
    }

    override func tearDownWithError() throws {
        registry = nil
        memoryService = nil
        repositories = nil
        try? FileManager.default.removeItem(at: tempDirectory)
        tempDirectory = nil
    }

    private func makeContext() -> AgentContext {
        AgentContext(
            sessionID: "test-session",
            repositories: repositories,
            memoryService: memoryService
        )
    }

    func testCreateAndReadNote() async throws {
        var context = makeContext()
        let create = AgentToolBlock(toolType: "create_note", content: "Shopping\nBuy milk and eggs")
        let createResult = try await registry.execute(block: create, context: &context)
        XCTAssertTrue(createResult.contains("Created note"))
        XCTAssertNotNil(context.activeNoteID)

        let read = AgentToolBlock(toolType: "read_note", content: context.activeNoteID ?? "")
        let readResult = try await registry.execute(block: read, context: &context)
        XCTAssertTrue(readResult.contains("Shopping"))
        XCTAssertTrue(readResult.contains("Buy milk and eggs"))
    }

    func testListNotesIncludesCreatedNote() async throws {
        var context = makeContext()
        _ = try await registry.execute(
            block: AgentToolBlock(toolType: "create_note", content: "List Test\nBody"),
            context: &context
        )

        let listResult = try await registry.execute(
            block: AgentToolBlock(toolType: "list_notes", content: ""),
            context: &context
        )
        XCTAssertTrue(listResult.contains("List Test"))
    }

    func testCreateDocumentAndListDocuments() async throws {
        var context = makeContext()
        _ = try await registry.execute(
            block: AgentToolBlock(toolType: "create_document", content: "Draft\nHello world"),
            context: &context
        )

        let listResult = try await registry.execute(
            block: AgentToolBlock(toolType: "list_documents", content: ""),
            context: &context
        )
        XCTAssertTrue(listResult.contains("Draft"))
    }

    func testCreateTask() async throws {
        var context = makeContext()
        let result = try await registry.execute(
            block: AgentToolBlock(
                toolType: "create_task",
                content: "Morning summary\nSummarize overnight emails\nschedule: daily\ntime: 08:00"
            ),
            context: &context
        )
        XCTAssertTrue(result.contains("Created task"))
        XCTAssertTrue(result.contains("daily"))

        let listResult = try await registry.execute(
            block: AgentToolBlock(toolType: "list_tasks", content: ""),
            context: &context
        )
        XCTAssertTrue(listResult.contains("Morning summary"))
    }

    func testReadChatSession() async throws {
        var context = makeContext()
        let session = try repositories.sessions.createSession(
            name: "Agent Chat",
            endpointURL: "http://localhost",
            model: "test",
            owner: nil
        )
        _ = try repositories.sessions.addMessage(sessionID: session.id, role: "user", content: "Hello")
        _ = try repositories.sessions.addMessage(sessionID: session.id, role: "assistant", content: "Hi there")
        try repositories.sessions.save()

        let result = try await registry.execute(
            block: AgentToolBlock(toolType: "read_chat", content: session.id),
            context: &context
        )
        XCTAssertTrue(result.contains("Agent Chat"))
        XCTAssertTrue(result.contains("Hello"))
        XCTAssertTrue(result.contains("Hi there"))
    }

    func testTaskWorkspaceExcludesEmailAndCalendar() {
        let taskRegistry = AgentToolRegistry.taskWorkspace(repositories: repositories)
        XCTAssertFalse(taskRegistry.toolNames.contains("list_emails"))
        XCTAssertFalse(taskRegistry.toolNames.contains("read_email"))
        XCTAssertFalse(taskRegistry.toolNames.contains("draft_email"))
        XCTAssertFalse(taskRegistry.toolNames.contains("list_calendar_events"))
        XCTAssertFalse(taskRegistry.toolNames.contains("create_calendar_event"))
        XCTAssertFalse(taskRegistry.toolNames.contains("create_note"))
        XCTAssertFalse(taskRegistry.toolNames.contains("create_document"))
        XCTAssertFalse(taskRegistry.toolNames.contains("create_research"))
        XCTAssertFalse(taskRegistry.toolNames.contains("append_research"))
        XCTAssertTrue(taskRegistry.toolNames.contains("write_document"))
        XCTAssertTrue(taskRegistry.toolNames.contains("update_document"))
        XCTAssertTrue(taskRegistry.toolNames.contains("append_document"))
        XCTAssertTrue(taskRegistry.toolNames.contains("run_research"))
        XCTAssertTrue(taskRegistry.toolNames.contains("search"))
    }

    func testUnknownToolReturnsMessage() async throws {
        var context = makeContext()
        let result = try await registry.execute(
            block: AgentToolBlock(toolType: "nonexistent_tool", content: ""),
            context: &context
        )
        XCTAssertTrue(result.contains("Unknown tool"))
    }
}
