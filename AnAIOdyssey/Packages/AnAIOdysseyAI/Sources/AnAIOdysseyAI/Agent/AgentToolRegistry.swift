// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
// Portions adapted from Odysseus v1.0, Copyright (c) 2025 Odysseus Contributors,
// used under the MIT License (see ACKNOWLEDGMENTS.md).
import Foundation
import AnAIOdysseyCore
import AIModelOptions

/// A single capability the agent can invoke (read a document, save a memory, etc.).
///
/// Conformers are keyed by `name` (the fenced-block tag the model emits) and turn
/// a parsed block's `content` into a textual result that is fed back to the model.
/// `context` is `inout` so a tool can update the active selection for later tools.
@MainActor
public protocol AgentTool {
    /// Tool tag matched against parsed `AgentToolBlock.toolType`.
    var name: String { get }
    /// Executes the tool against `content`, returning text the model will read next.
    func execute(content: String, context: inout AgentContext) async throws -> String
}

/// Name-indexed collection of tools plus the catalog text describing them to the model.
///
/// The loop looks up a parsed block's tag here and dispatches to the matching
/// tool; unknown tags return a graceful message instead of throwing.
@MainActor
public final class AgentToolRegistry {
    /// Tools indexed by their `name` for O(1) dispatch.
    private let tools: [String: any AgentTool]
    /// Catalog text for any host-injected tools (e.g. email), appended to the
    /// built-in catalog so the model knows how to call them.
    private let extraDescriptions: String

    /// Builds the lookup map from a flat list of tools.
    public init(tools: [any AgentTool], extraDescriptions: String = "") {
        var map: [String: any AgentTool] = [:]
        for tool in tools {
            map[tool.name] = tool
        }
        self.tools = map
        self.extraDescriptions = extraDescriptions
    }

    /// Every registered tool name — the full set the parser must recognize so the
    /// model's tool calls are actually detected and dispatched.
    public var toolNames: Set<String> {
        Set(tools.keys)
    }

    /// Convenience factory wiring up the full standard tool set against the app's
    /// repositories and memory, plus any host-injected `extraTools` (with their
    /// catalog text in `extraDescriptions`) such as the email tools.
    public static func standard(
        repositories: RepositoryBundle,
        memoryService: MemoryService,
        calendarAccess: CalendarAgentAccess? = nil,
        extraTools: [any AgentTool] = [],
        extraDescriptions: String = ""
    ) -> AgentToolRegistry {
        AgentToolRegistry(
            tools: AgentStandardTools.all(
                repositories: repositories,
                memoryService: memoryService,
                calendarAccess: calendarAccess
            ) + extraTools,
            extraDescriptions: extraDescriptions
        )
    }

    /// Documents and research only — no email, calendar, notes, or other host extras.
    public static func taskWorkspace(repositories: RepositoryBundle) -> AgentToolRegistry {
        AgentToolRegistry(
            tools: AgentStandardTools.taskWorkspace(repositories: repositories),
            extraDescriptions: ""
        )
    }

    /// Dispatches a parsed tool block to its tool, returning a fallback message for unknown tags.
    public func execute(block: AgentToolBlock, context: inout AgentContext) async throws -> String {
        guard let tool = tools[block.toolType] else {
            return "Unknown tool: \(block.toolType)"
        }
        return try await tool.execute(content: block.content, context: &context)
    }

    /// Human/model-readable catalog of every tool and its expected fenced-block input format.
    ///
    /// Injected verbatim into the agent system prompt so the model knows which
    /// tools exist and exactly how to format each invocation.
    public var toolDescriptions: String {
        var catalog = builtInDescriptions
        let extra = extraDescriptions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty {
            catalog += "\n\n" + extra
        }
        return catalog
    }

    /// The catalog text for the always-present built-in tools.
    private var builtInDescriptions: String {
        if tools.keys.contains("run_research") || tools.keys.contains("write_document"),
           !tools.keys.contains("create_note") {
            return taskToolDescriptions
        }
        return chatToolDescriptions
    }

    private var taskToolDescriptions: String {
        """
        Available tools — write a fenced code block with the tool name as the language tag:

        \(AgentTaskRunPolicy.boundarySentence)

        ## Search
        ```search
        packing list
        kinds: documents, research
        limit: 10
        ```
        Search documents and research only.

        ## Documents
        ```list_documents
        ```
        ```read_document
        <document-id>
        ```
        ```write_document
        title: Packing List
        Write a packing list for a 7-day Iceland trip in June.
        ```
        Hand writing to the Documents feature (Documents model, generation pipeline, saved Document). Do not compose the full document body yourself.
        Optional lines: `document: <id>` to rewrite an existing Document; `context:` for research or other notes.
        After a document exists, use read/edit/update/append for small fixes only.
        ```edit_document
        <<<FIND>>>
        text to find
        <<<REPLACE>>>
        replacement text
        <<<END>>>
        ```
        ```update_document
        <document-id>
        title: Optional New Title
        Replacement body...
        ```
        ```append_document
        <document-id>
        Text to append...
        ```

        ## Research
        ```list_research
        ```
        ```read_research
        <report-id>
        ```
        ```run_research
        Iceland packing list
        ```
        Hand the question to the Research feature (web search, Research model, sources, saved Research item). Do not write a research report yourself with document tools.

        ## Date & time
        ```current_date
        ```
        Returns today's date and weekday, the local time, the time zone, and an ISO 8601 timestamp.

        ## Rules
        - If the assignment asks you to research, look up, or investigate a topic, you MUST call run_research. Do not invent sources or write the report as a document.
        - If the assignment asks you to write, draft, or create a document, you MUST call write_document. Do not compose the full body with update_document or append_document.
        - A task may do both: run_research first, then write_document using the research summary as context.
        - Never request email or calendar tools. They are not available on task runs.
        - Use list_* / search first when you need ids; then read_* or write.
        - Call current_date when the assignment depends on today's date. Never guess it.
        - Do not delete documents or research unless the user explicitly asked in the assignment.
        """
    }

    private var chatToolDescriptions: String {
        """
        Available tools — write a fenced code block with the tool name as the language tag:

        ## Search (find anything)
        ```search
        quarterly report budget
        kinds: documents, notes, chats (optional filter)
        limit: 10 (optional, capped at 20)
        ```
        Unified keyword search across documents, notes, chats, tasks, research,
        memories, drafts, calendar (if permitted), gallery, and comparisons.
        Use returned ids with read_* tools.

        ## Documents
        ```list_documents
        ```
        List all documents in the library.

        ```read_document
        <document-id>
        ```
        Read a document by id (or omit id for the most recent).

        ```create_document
        Document Title
        Full document content...
        folder: /Projects/Specs
        ```
        Create a document (line 1 = title, rest = content). Optional trailing
        `folder:` places it in a folder by id or /path (omit for root).

        ```edit_document
        <<<FIND>>>
        text to find
        <<<REPLACE>>>
        replacement text
        <<<END>>>
        ```
        Apply targeted find/replace edits to the active document.

        ```update_document
        <document-id>
        title: Optional New Title
        Replacement body...
        ```
        Replace a document's body (and optional title).

        ```append_document
        <document-id>
        Text to append...
        ```
        Append text to a document.

        ## Folders (Documents & Notes trees)
        ```list_folders
        documents|notes (optional; omit for both)
        ```
        Show the folder tree(s) with folder ids.

        ```browse_folder
        kind: documents
        /Projects/Specs
        ```
        List the subfolders and items in a folder (by id or /path; empty = root).
        `kind:` selects the documents or notes tree (default documents).

        ```create_folder
        Folder Name
        kind: documents
        parent: /Projects
        ```
        Create a folder. `kind:` = documents|notes, `parent:` = id or /path (omit for root).

        ```move_item
        document <id>
        to: /Projects/Specs
        ```
        Move a document, note, or folder into a folder. Line 1 = `document|note|folder <id>`;
        destination via `to:` (id or /path; empty or `/` = root).

        ## Notes
        ```list_notes
        ```
        List all notes (each shows its folder path).

        ```read_note
        <note-id or title search>
        ```
        Read a note by id or title.

        ```create_note
        Note Title
        Note content...
        folder: /Ideas
        ```
        Create a note (line 1 = title, rest = content). Optional trailing `folder:`
        places it in a notes folder by id or /path (omit for root).

        ```update_note
        <note-id>
        title: New Title (optional line)
        Updated content...
        ```
        Update a note's title and/or content.

        ## Chats
        ```list_chats
        ```
        List chat sessions.

        ```read_chat
        <session-id or name search>
        ```
        Read messages from a chat session.

        ## Tasks
        ```list_tasks
        <status filter: active|paused|completed — optional>
        ```
        List scheduled tasks.

        ```create_task
        Task Name
        Prompt for the task...
        schedule: daily
        time: 09:00
        parent: <task-id>
        ```
        Create a scheduled task (metadata lines optional). `parent:` nests it as a
        subtask of another task.

        ```list_subtasks
        <task-id (empty = top-level tasks)>
        ```
        List the direct subtasks of a task.

        ## Email drafts (compose only — you can NEVER send mail)
        ```draft_email
        mode: reply
        to: alice@example.com
        cc: bob@example.com
        subject: Re: Project update
        original: <message-id from read_email, for reply/forward>

        Body of the email goes here, after a blank line.
        ```
        Save an email draft for the user to review and send themselves. `mode:` is
        new|reply|forward (default new). Header lines are optional except the body.
        The draft appears in the Email tab's Drafts list. You cannot send email.

        ## Research
        ```list_research
        ```
        List research reports.

        ```read_research
        <report-id or query search>
        ```
        Read a research report.

        ```create_research
        Research title
        Summary...
        ```
        Create a research report.

        ```update_research
        <report-id>
        title: Optional New Title
        Replacement summary...
        ```
        Replace a research report's summary.

        ```append_research
        <report-id>
        Text to append...
        ```
        Append text to a research report.

        ## Calendar & gallery
        ```list_calendar_events
        <days ahead, default 30>
        ```
        List upcoming calendar events (incl. synced Google Calendar). Requires the
        user to enable "Allow AI to access Calendar" in Settings. Refreshes live
        calendar data before listing.

        ```create_calendar_event
        Team sync
        start: 2026-08-27 14:00
        end: 2026-08-27 15:00
        location: Conference room (optional)
        notes: Agenda and links... (optional)
        allday: false (optional)
        ```
        Create an event in the user's calendar (line 1 = title). Dates accept
        "yyyy-MM-dd HH:mm", ISO 8601, or "yyyy-MM-dd" (all-day). `end:` defaults
        to one hour after start. Requires "Allow AI to access Calendar" in
        Settings and system Calendar permission.

        ```list_gallery_albums
        ```
        List gallery albums.

        ```list_comparisons
        ```
        List model comparison runs.

        ## Memory
        ```list_memories
        ```
        List all saved memories.

        ```search_memory
        query text
        ```
        Search memories semantically.

        ```save_memory
        text to remember
        ```
        Save a persistent memory about the user.

        ## Date & time
        ```current_date
        ```
        Returns today's date and weekday, the local time, the user's time zone with
        its UTC offset, and an ISO 8601 timestamp. Call it before working out
        "today", "tomorrow", deadlines, or calendar dates.
        """
    }
}
