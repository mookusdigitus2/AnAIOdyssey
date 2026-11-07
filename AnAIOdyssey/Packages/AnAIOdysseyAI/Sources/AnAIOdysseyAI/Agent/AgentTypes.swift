// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import AnAIOdysseyCore
import AIModelOptions

/// Streamed events emitted by the agent loop, consumed by the chat UI to render progress.
///
/// The loop interleaves assistant `token`s with `toolStart`/`toolResult` pairs as
/// it executes tools, then ends with exactly one `finished` (or `error`).
public enum AgentEvent: Sendable, Equatable {
    /// Incremental assistant-visible text (already stripped of tool blocks).
    case token(String)
    /// Incremental chain-of-thought (`reasoning_content` / `reasoning`).
    case reasoning(String)
    /// A tool is about to run, with its name and raw input block.
    case toolStart(name: String, input: String)
    /// A tool finished, carrying its textual output (or error message).
    case toolResult(name: String, output: String)
    /// Hosted or fallback web search is in progress.
    case searchingWeb
    /// Sources collected from a web search this turn.
    case webSearchCitations([ChatWebSearchCitation])
    /// The search backend could not be reached; the model still answers.
    case webSearchFailed
    /// The chosen engine failed and quick facts (or another fallback) answered instead.
    case webSearchNotice(String)
    /// Terminal event: the final assistant message.
    case finished(content: String)
    /// Terminal event: an unrecoverable error description.
    case error(message: String)
    /// The model answered in text where a tool call was expected.
    case toolFormatHint(model: String, connectionID: String?)
    /// The run was paused; history is enough to Continue later.
    case paused(history: [LLMChatTurn], partial: String)
}

/// Mutable, per-run state threaded through every tool execution.
///
/// Carries the active session plus the "current" document/note ids (so tools
/// like `read_document`/`edit_document` can default to what the user is looking
/// at), and gives tools access to the repositories and memory service. Passed
/// `inout` so a tool can update the active selection for later tools in the run.
@MainActor
public struct AgentContext {
    public var sessionID: String
    /// Most recently read/created document; lets edit/read tools default sensibly.
    public var activeDocumentID: String?
    /// Most recently read/created research report.
    public var activeResearchID: String?
    /// Most recently read/created note; lets note tools default sensibly.
    public var activeNoteID: String?
    /// Optional sink so a task run can persist a change log and live status.
    public var taskProgress: AgentTaskProgressSink?
    /// Hands research work to the Research feature (same pipeline as the Research tab).
    public var researchRunner: AgentResearchRunning?
    /// Hands document writing to the Documents writing feature.
    public var documentWriter: AgentDocumentWriting?
    /// Polled during long tools so Pause/Stop can abort a Research or Documents run.
    public var shouldContinueTool: (@MainActor () -> Bool)?
    /// All data repositories the read/write tools operate on.
    public let repositories: RepositoryBundle
    /// Semantic memory store backing the memory tools.
    public let memoryService: MemoryService
    /// Cached folder paths per kind to avoid N+1 fetches during tool runs.
    public var folderPathMaps: [FolderKind: [String: String]] = [:]

    public init(
        sessionID: String,
        activeDocumentID: String? = nil,
        activeResearchID: String? = nil,
        activeNoteID: String? = nil,
        repositories: RepositoryBundle,
        memoryService: MemoryService,
        taskProgress: AgentTaskProgressSink? = nil,
        researchRunner: AgentResearchRunning? = nil,
        documentWriter: AgentDocumentWriting? = nil,
        shouldContinueTool: (@MainActor () -> Bool)? = nil
    ) {
        self.sessionID = sessionID
        self.activeDocumentID = activeDocumentID
        self.activeResearchID = activeResearchID
        self.activeNoteID = activeNoteID
        self.repositories = repositories
        self.memoryService = memoryService
        self.taskProgress = taskProgress
        self.researchRunner = researchRunner
        self.documentWriter = documentWriter
        self.shouldContinueTool = shouldContinueTool
    }
}

/// Result of handing a research request to the Research feature.
public struct AgentResearchRunResult: Sendable {
    public let id: String
    public let title: String
    public let summary: String

    public init(id: String, title: String, summary: String) {
        self.id = id
        self.title = title
        self.summary = summary
    }
}

/// Runs the Research-tab pipeline for a task tool.
@MainActor
public protocol AgentResearchRunning: AnyObject {
    func runResearch(
        query: String,
        shouldContinue: @escaping @MainActor () -> Bool
    ) async throws -> AgentResearchRunResult
}

/// Result of handing a document brief to the Documents writing feature.
public struct AgentDocumentWriteResult: Sendable {
    public let id: String
    public let title: String
    public let excerpt: String
    public let created: Bool

    public init(id: String, title: String, excerpt: String, created: Bool) {
        self.id = id
        self.title = title
        self.excerpt = excerpt
        self.created = created
    }
}

/// Runs the Documents writing pipeline for a task tool.
@MainActor
public protocol AgentDocumentWriting: AnyObject {
    func writeDocument(
        title: String?,
        brief: String,
        existingDocumentID: String?,
        extraContext: String?,
        shouldContinue: @escaping @MainActor () -> Bool
    ) async throws -> AgentDocumentWriteResult
}

/// Lets a task run record Document/Research edits and the current action line.
@MainActor
public protocol AgentTaskProgressSink: AnyObject {
    func setCurrentAction(_ text: String)
    func recordChange(action: String, kind: String, itemID: String, title: String)
}

/// A single tool invocation parsed out of the model's text.
///
/// Represents one fenced ```toolname block: `toolType` is the tag and `content`
/// is the block body that the matching tool will interpret.
public typealias AgentToolBlock = ToolCallBlock

/// Setup/configuration errors for the agent subsystem, with display-ready messages.
public enum AgentLoopError: Error, LocalizedError {
    case missingLLMService
    case missingDependencies

    public var errorDescription: String? {
        switch self {
        case .missingLLMService:
            "LLM service not configured."
        case .missingDependencies:
            "Agent dependencies were not configured."
        }
    }
}
