// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import AnAIOdysseyCore
import AIModelOptions

// Read/write agent tools over the app's structured data (notes, chats, tasks,
// research, calendar, gallery, comparisons). Each conforms to `AgentTool`, is
// dispatched by `name`, and returns plain text for the model to read. They share
// the conventions in `AgentToolSupport` (preview truncation, list caps, id/prefix
// resolution, title/body and metadata parsing). `AgentStandardTools.all` at the
// bottom assembles the full set wired into the registry.

/// Agent tool: lists non-archived notes with one-line previews (capped at `listLimit`).
@MainActor
struct ListNotesTool: AgentTool {
    let name = "list_notes"
    private let repositories: RepositoryBundle

    init(repositories: RepositoryBundle) {
        self.repositories = repositories
    }

    func execute(content: String, context: inout AgentContext) async throws -> String {
        let notes = try repositories.notes.listVisibleNotes(includeArchived: false)
        guard !notes.isEmpty else {
            return "No notes found."
        }

        let lines = notes.prefix(AgentToolSupport.listLimit).map { note in
            let preview = (note.content ?? "")
                .replacingOccurrences(of: "\n", with: " ")
                .prefix(80)
            let pinned = note.pinned ? ", pinned" : ""
            let path = AgentFolderSupport.path(
                forFolderID: note.parentID,
                kind: .notes,
                repositories: repositories,
                cache: &context.folderPathMaps[.notes]
            )
            return "- \(note.title) (id: \(note.id)\(pinned), folder: \(path), updated: \(AgentToolSupport.formatDate(note.updatedAt))) — \(preview)"
        }
        var result = "Notes (\(notes.count)):\n" + lines.joined(separator: "\n")
        if notes.count > AgentToolSupport.listLimit {
            result += "\n... and \(notes.count - AgentToolSupport.listLimit) more."
        }
        return result
    }
}

/// Agent tool: reads a note by id/prefix or title search.
///
/// With no input it falls back to the active note, then the most recent. Sets the
/// active note for follow-ups and appends any checklist items. Output is truncated.
@MainActor
struct ReadNoteTool: AgentTool {
    let name = "read_note"
    private let repositories: RepositoryBundle

    init(repositories: RepositoryBundle) {
        self.repositories = repositories
    }

    func execute(content: String, context: inout AgentContext) async throws -> String {
        let query = content.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let notes = try repositories.notes.listVisibleNotes(includeArchived: true)

        // Resolve by id/prefix, then by title contains; else fall back to active/most-recent.
        let note: Note?
        if let query {
            note = AgentToolSupport.resolveByID(query, in: notes, id: \.id)
                ?? notes.first { $0.title.localizedCaseInsensitiveContains(query) }
        } else if let activeID = context.activeNoteID {
            note = try repositories.notes.fetchNote(id: activeID)
        } else {
            note = notes.first
        }

        guard let note else {
            return query.map { "No note found matching '\($0)'." } ?? "No notes found."
        }

        context.activeNoteID = note.id
        let body = note.content ?? ""
        let (preview, truncated) = AgentToolSupport.truncate(body)
        var result = """
        Note: \(note.title) (id: \(note.id), type: \(note.noteType))
        Updated: \(AgentToolSupport.formatDate(note.updatedAt))

        \(preview)
        """
        // Render checklist items (if any) as markdown checkboxes.
        if !note.checklistItems.isEmpty {
            let items = note.checklistItems.enumerated().map { index, item in
                let mark = item.done ? "[x]" : "[ ]"
                return "\(index + 1). \(mark) \(item.text)"
            }
            result += "\n\nChecklist:\n" + items.joined(separator: "\n")
        }
        if truncated {
            result += "\n(Content truncated for display.)"
        }
        return result
    }
}

/// Agent tool: creates a user-visible note (title line 1, body after), attributed to the AI.
@MainActor
struct CreateNoteTool: AgentTool {
    let name = "create_note"
    private let repositories: RepositoryBundle

    init(repositories: RepositoryBundle) {
        self.repositories = repositories
    }

    func execute(content: String, context: inout AgentContext) async throws -> String {
        // Peel an optional trailing `folder:` metadata line, then title/body.
        var lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let metadata = AgentToolSupport.parseMetadataLines(from: &lines)
        let parsed = AgentToolSupport.parseTitleBody(from: lines.joined(separator: "\n"), defaultTitle: "Untitled Note")

        let folder = try AgentFolderSupport.resolveFolderID(metadata["folder"], kind: .notes, repositories: repositories)
        guard folder.found else {
            return "Target folder '\(metadata["folder"] ?? "")' not found in notes."
        }

        let note = try repositories.notes.createNote(
            title: parsed.title,
            content: parsed.body.nilIfEmpty,
            parentID: folder.id
        )
        note.sessionID = context.sessionID
        note.source = "ai"
        try repositories.notes.save()

        context.activeNoteID = note.id
        let path = AgentFolderSupport.path(forFolderID: folder.id, kind: .notes, repositories: repositories)
        return "Created note '\(parsed.title)' (id: \(note.id)) at \(path)."
    }
}

/// Agent tool: updates an existing note's title and/or content.
///
/// Input format: line 1 is the note id; an optional `title: ...` line sets a new
/// title; remaining lines become the new content. Reports which fields changed.
@MainActor
struct UpdateNoteTool: AgentTool {
    let name = "update_note"
    private let repositories: RepositoryBundle

    init(repositories: RepositoryBundle) {
        self.repositories = repositories
    }

    func execute(content: String, context: inout AgentContext) async throws -> String {
        // Line 1 must identify the note to update.
        var lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let idLine = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
            return "First line must be the note id."
        }
        lines.removeFirst()

        let notes = try repositories.notes.listVisibleNotes(includeArchived: true)
        let note: Note?
        if let resolved = AgentToolSupport.resolveByID(idLine, in: notes, id: \.id) {
            note = resolved
        } else {
            note = try repositories.notes.fetchNote(id: idLine)
        }
        guard let note else {
            return "No note found with id '\(idLine)'."
        }

        // Optional leading `title:` line updates the title; the rest is the new content.
        var newTitle: String?
        var newContent: String?
        if let first = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines),
           first.lowercased().hasPrefix("title:") {
            newTitle = String(first.dropFirst("title:".count)).trimmingCharacters(in: .whitespaces)
            lines.removeFirst()
        }
        if !lines.isEmpty {
            newContent = lines.joined(separator: "\n")
        }

        try repositories.notes.updateNote(id: note.id, title: newTitle, content: newContent, checklistItems: nil)
        try repositories.notes.save()
        context.activeNoteID = note.id

        // Summarize which fields actually changed for the model.
        var parts: [String] = []
        if newTitle != nil { parts.append("title") }
        if newContent != nil { parts.append("content") }
        let updated = parts.isEmpty ? "unchanged" : parts.joined(separator: " and ")
        return "Updated note '\(note.title)' (id: \(note.id)): \(updated)."
    }
}

/// Agent tool: lists active chat sessions with last-message time and model (capped at `listLimit`).
@MainActor
struct ListChatsTool: AgentTool {
    let name = "list_chats"
    private let repositories: RepositoryBundle

    init(repositories: RepositoryBundle) {
        self.repositories = repositories
    }

    func execute(content: String, context: inout AgentContext) async throws -> String {
        let sessions = try repositories.sessions.listActiveSessions()
        guard !sessions.isEmpty else {
            return "No chat sessions found."
        }

        let lines = sessions.prefix(AgentToolSupport.listLimit).map { session in
            let last = session.lastMessageAt.map(AgentToolSupport.formatDate) ?? "never"
            return "- \(session.name) (id: \(session.id), last message: \(last), model: \(session.model))"
        }
        var result = "Chat sessions (\(sessions.count)):\n" + lines.joined(separator: "\n")
        if sessions.count > AgentToolSupport.listLimit {
            result += "\n... and \(sessions.count - AgentToolSupport.listLimit) more."
        }
        return result
    }
}

/// Agent tool: reads a chat session's transcript by id/prefix or name search.
///
/// Defaults to the current session when no query is given. Output is a role-tagged
/// transcript, truncated to the preview limit.
@MainActor
struct ReadChatTool: AgentTool {
    let name = "read_chat"
    private let repositories: RepositoryBundle

    init(repositories: RepositoryBundle) {
        self.repositories = repositories
    }

    func execute(content: String, context: inout AgentContext) async throws -> String {
        // Default to the current session if no query is supplied.
        let query = content.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? context.sessionID
        let sessions = try repositories.sessions.listActiveSessions()

        // Match by exact id, then id prefix, then session name.
        let session: ChatSession?
        if let exact = try repositories.sessions.fetchSession(id: query) {
            session = exact
        } else {
            session = AgentToolSupport.resolveByID(query, in: sessions, id: \.id)
                ?? sessions.first { $0.name.localizedCaseInsensitiveContains(query) }
        }

        guard let session else {
            return "No chat session found matching '\(query)'."
        }

        let messages = try repositories.sessions.messages(for: session.id)
        guard !messages.isEmpty else {
            return "Chat '\(session.name)' (id: \(session.id)) has no messages."
        }

        let lines = messages.map { message in
            let role = message.role.capitalized
            let body = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return "[\(role)] \(body)"
        }
        let transcript = lines.joined(separator: "\n\n")
        let (preview, truncated) = AgentToolSupport.truncate(transcript)
        var result = """
        Chat: \(session.name) (id: \(session.id))
        Messages: \(messages.count)

        \(preview)
        """
        if truncated {
            result += "\n(Transcript truncated for display.)"
        }
        return result
    }
}

/// Agent tool: lists scheduled tasks, optionally filtered by status (active|paused|completed).
@MainActor
struct ListTasksTool: AgentTool {
    let name = "list_tasks"
    private let repositories: RepositoryBundle

    init(repositories: RepositoryBundle) {
        self.repositories = repositories
    }

    func execute(content: String, context: inout AgentContext) async throws -> String {
        // Optional status filter passed as the whole block body.
        let statusFilter = content.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let tasks = try repositories.tasks.listTasks(status: statusFilter)
        guard !tasks.isEmpty else {
            return statusFilter.map { "No tasks with status '\($0)'." } ?? "No scheduled tasks."
        }

        let lines = tasks.prefix(AgentToolSupport.listLimit).map { task in
            // Combine schedule + time into one readable field, or "manual" when unscheduled.
            let schedule = [task.schedule, task.scheduledTime].compactMap { $0?.nilIfEmpty }.joined(separator: " @ ")
            let scheduleText = schedule.isEmpty ? "manual" : schedule
            let promptPreview = (task.prompt ?? "").replacingOccurrences(of: "\n", with: " ").prefix(60)
            return "- \(task.name) (id: \(task.id), status: \(task.status), schedule: \(scheduleText)) — \(promptPreview)"
        }
        var result = "Tasks (\(tasks.count)):\n" + lines.joined(separator: "\n")
        if tasks.count > AgentToolSupport.listLimit {
            result += "\n... and \(tasks.count - AgentToolSupport.listLimit) more."
        }
        return result
    }
}

/// Agent tool: creates a scheduled task.
///
/// Input: line 1 is the task name, following lines are the prompt, and trailing
/// `schedule:`/`time:` metadata lines (parsed off the end) set the schedule.
@MainActor
struct CreateTaskTool: AgentTool {
    let name = "create_task"
    private let repositories: RepositoryBundle

    init(repositories: RepositoryBundle) {
        self.repositories = repositories
    }

    func execute(content: String, context: inout AgentContext) async throws -> String {
        // Peel trailing key:value metadata off the end, leaving name + prompt.
        var lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let metadata = AgentToolSupport.parseMetadataLines(from: &lines)
        let name = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Untitled Task"
        let prompt = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty

        // Optional `parent:` id nests this as a subtask; resolve by id/prefix.
        var parentTaskID: String?
        if let parentRef = metadata["parent"]?.nilIfEmpty {
            let tasks = try repositories.tasks.listTasks(status: nil)
            parentTaskID = try AgentToolSupport.resolveByID(parentRef, in: tasks, id: \.id)?.id
                ?? repositories.tasks.fetchTask(id: parentRef)?.id
            guard parentTaskID != nil else {
                return "Parent task '\(parentRef)' not found."
            }
        }

        let task = try repositories.tasks.createTask(
            name: name,
            prompt: prompt,
            schedule: metadata["schedule"],
            scheduledTime: metadata["time"],
            scheduledDate: nil,
            sessionID: context.sessionID,
            parentTaskID: parentTaskID
        )
        try repositories.tasks.save()

        var details = "Created task '\(name)' (id: \(task.id))."
        if let parentTaskID {
            details += " Subtask of: \(parentTaskID)."
        }
        if let schedule = metadata["schedule"] {
            details += " Schedule: \(schedule)."
        }
        if let time = metadata["time"] {
            details += " Time: \(time)."
        }
        return details
    }
}

/// Agent tool: lists saved research reports with query + summary preview (capped at `listLimit`).
@MainActor
struct ListResearchTool: AgentTool {
    let name = "list_research"
    private let repositories: RepositoryBundle

    init(repositories: RepositoryBundle) {
        self.repositories = repositories
    }

    func execute(content: String, context: inout AgentContext) async throws -> String {
        let reports = try repositories.researchReports.listReports()
        guard !reports.isEmpty else {
            return "No research reports found."
        }

        let lines = reports.prefix(AgentToolSupport.listLimit).map { report in
            let preview = report.summary.replacingOccurrences(of: "\n", with: " ").prefix(80)
            return "- \(report.query) (id: \(report.id), \(AgentToolSupport.formatDate(report.createdAt))) — \(preview)"
        }
        var result = "Research reports (\(reports.count)):\n" + lines.joined(separator: "\n")
        if reports.count > AgentToolSupport.listLimit {
            result += "\n... and \(reports.count - AgentToolSupport.listLimit) more."
        }
        return result
    }
}

/// Agent tool: reads a research report by id/prefix or query search (defaults to the most recent).
///
/// Appends the report's stored sources JSON when present; summary is truncated.
@MainActor
struct ReadResearchTool: AgentTool {
    let name = "read_research"
    private let repositories: RepositoryBundle

    init(repositories: RepositoryBundle) {
        self.repositories = repositories
    }

    func execute(content: String, context: inout AgentContext) async throws -> String {
        let query = content.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let reports = try repositories.researchReports.listReports()

        // Match by id/prefix, then by query text; else default to the newest report.
        let report: ResearchReport?
        if let query {
            report = AgentToolSupport.resolveByID(query, in: reports, id: \.id)
                ?? reports.first { $0.query.localizedCaseInsensitiveContains(query) }
        } else {
            report = reports.first
        }

        guard let report else {
            return query.map { "No research report found matching '\($0)'." } ?? "No research reports found."
        }

        context.activeResearchID = report.id
        let (summary, truncated) = AgentToolSupport.truncate(report.summary)
        var result = """
        Research: \(report.query) (id: \(report.id))
        Created: \(AgentToolSupport.formatDate(report.createdAt))

        \(summary)
        """
        if !report.sourcesJSON.isEmpty, report.sourcesJSON != "[]" {
            result += "\n\nSources JSON:\n\(report.sourcesJSON)"
        }
        if truncated {
            result += "\n(Summary truncated for display.)"
        }
        return result
    }
}

/// Creates a research report through the same repository the Research tab uses.
@MainActor
struct CreateResearchTool: AgentTool {
    let name = "create_research"
    private let repositories: RepositoryBundle

    init(repositories: RepositoryBundle) {
        self.repositories = repositories
    }

    func execute(content: String, context: inout AgentContext) async throws -> String {
        let parsed = AgentToolSupport.parseTitleBody(from: content, defaultTitle: "Untitled research")
        let report = try repositories.researchReports.createReport(
            query: parsed.title,
            summary: parsed.body,
            sourcesJSON: "[]",
            threadJSON: "[]"
        )
        context.activeResearchID = report.id
        context.taskProgress?.recordChange(
            action: "created",
            kind: "research",
            itemID: report.id,
            title: parsed.title
        )
        return "Created research '\(parsed.title)' (id: \(report.id))."
    }
}

/// Hands a research question to the Research feature (web search + synthesis).
@MainActor
struct RunResearchTool: AgentTool {
    let name = "run_research"

    func execute(content: String, context: inout AgentContext) async throws -> String {
        let query = AgentTaskRunPolicy.researchQuery(fromToolInput: content)
        guard !query.isEmpty else {
            return "Provide a research topic or question."
        }
        guard let runner = context.researchRunner else {
            return "Research is not configured for this task run."
        }
        context.taskProgress?.setCurrentAction(
            AgentTaskRunPolicy.currentAction(action: "researched", title: query)
        )
        let shouldContinue = context.shouldContinueTool ?? { true }
        do {
            let result = try await runner.runResearch(query: query, shouldContinue: shouldContinue)
            context.activeResearchID = result.id
            context.taskProgress?.recordChange(
                action: "researched",
                kind: "research",
                itemID: result.id,
                title: result.title
            )
            let summary = AgentToolSupport.truncate(result.summary).0
            return """
            Researched '\(result.title)' (id: \(result.id)).
            Saved as a Research item by the Research feature.

            Summary:
            \(summary)
            """
        } catch is CancellationError {
            return "Research was interrupted (paused or stopped) and was not saved. After Continue, call run_research again with the same query."
        }
    }
}

/// Replaces a research report's summary (and optional title) in place.
@MainActor
struct UpdateResearchTool: AgentTool {
    let name = "update_research"
    private let repositories: RepositoryBundle

    init(repositories: RepositoryBundle) {
        self.repositories = repositories
    }

    func execute(content: String, context: inout AgentContext) async throws -> String {
        var lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let targetID = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? context.activeResearchID
        if lines.first != nil { lines.removeFirst() }
        var newTitle: String?
        if let first = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines),
           first.lowercased().hasPrefix("title:") || first.lowercased().hasPrefix("query:") {
            let value = first.split(separator: ":", maxSplits: 1).dropFirst().joined(separator: ":")
            newTitle = value.trimmingCharacters(in: .whitespaces).nilIfEmpty
            lines.removeFirst()
        }
        let body = lines.joined(separator: "\n")
        guard let report = try resolveResearch(id: targetID, repositories: repositories) else {
            return "No research report found to update."
        }
        if let newTitle {
            report.query = newTitle
        }
        try repositories.researchReports.updateReport(
            id: report.id,
            summary: body.isEmpty ? report.summary : body,
            threadJSON: report.threadJSON,
            sourcesJSON: nil
        )
        context.activeResearchID = report.id
        let title = newTitle ?? report.query
        context.taskProgress?.recordChange(
            action: "edited",
            kind: "research",
            itemID: report.id,
            title: title
        )
        return "Updated research \(title) (id: \(report.id))."
    }
}

/// Appends text to a research report summary.
@MainActor
struct AppendResearchTool: AgentTool {
    let name = "append_research"
    private let repositories: RepositoryBundle

    init(repositories: RepositoryBundle) {
        self.repositories = repositories
    }

    func execute(content: String, context: inout AgentContext) async throws -> String {
        var lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let targetID = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? context.activeResearchID
        if lines.first != nil { lines.removeFirst() }
        let addition = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !addition.isEmpty else {
            return "Provide text to append after the research id."
        }
        guard let report = try resolveResearch(id: targetID, repositories: repositories) else {
            return "No research report found to append to."
        }
        let updated = report.summary.isEmpty ? addition : report.summary + "\n\n" + addition
        try repositories.researchReports.updateReport(
            id: report.id,
            summary: updated,
            threadJSON: report.threadJSON,
            sourcesJSON: nil
        )
        context.activeResearchID = report.id
        context.taskProgress?.recordChange(
            action: "edited",
            kind: "research",
            itemID: report.id,
            title: report.query
        )
        return "Updated research \(report.query) (id: \(report.id))."
    }
}

@MainActor
private func resolveResearch(id: String?, repositories: RepositoryBundle) throws -> ResearchReport? {
    let reports = try repositories.researchReports.listReports()
    if let id {
        if let match = AgentToolSupport.resolveByID(id, in: reports, id: \.id) {
            return match
        }
        return try repositories.researchReports.fetchReport(id: id)
    }
    return reports.first
}

/// Agent tool: lists upcoming calendar events within a window (default 30 days ahead).
@MainActor
struct ListCalendarEventsTool: AgentTool {
    let name = "list_calendar_events"
    private let repositories: RepositoryBundle
    private let calendarAccess: CalendarAgentAccess?

    init(repositories: RepositoryBundle, calendarAccess: CalendarAgentAccess? = nil) {
        self.repositories = repositories
        self.calendarAccess = calendarAccess
    }

    func execute(content: String, context: inout AgentContext) async throws -> String {
        // Privacy gate: the user must opt in to AI calendar access in Settings.
        guard AIDataAccess.isCalendarAllowed else {
            return "Calendar access is disabled. The user can enable \"Allow AI to access Calendar\" in Settings to grant access."
        }

        // Window is [today 00:00, today + N days]; N comes from the block (default 30, min 1).
        let days = Int(content.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 30
        let start = Calendar.current.startOfDay(for: .now)
        let end = Calendar.current.date(byAdding: .day, value: max(days, 1), to: start) ?? start

        // Refresh live calendar sources into the cache before listing.
        let refreshNotes = await calendarAccess?.refresh(from: start, to: end) ?? []

        let events = try repositories.calendarEvents.listEvents(from: start, to: end)
        guard !events.isEmpty else {
            var message = "No calendar events in the next \(days) day(s)."
            if !refreshNotes.isEmpty {
                message += "\n\n" + refreshNotes.joined(separator: "\n")
            }
            return message
        }

        // Chronological order, all-day events shown as a single date.
        let sorted = events.sorted { $0.startDate < $1.startDate }
        let lines = sorted.prefix(AgentToolSupport.listLimit).map { event in
            let when = event.allDay
                ? AgentToolSupport.formatDate(event.startDate)
                : "\(AgentToolSupport.formatDate(event.startDate)) – \(AgentToolSupport.formatDate(event.endDate))"
            let location = event.location.map { " @ \($0)" } ?? ""
            return "- \(event.title) (id: \(event.id), \(when))\(location)"
        }
        var result = "Calendar events (\(events.count), next \(days) days):\n" + lines.joined(separator: "\n")
        if events.count > AgentToolSupport.listLimit {
            result += "\n... and \(events.count - AgentToolSupport.listLimit) more."
        }
        if !refreshNotes.isEmpty {
            result += "\n\n" + refreshNotes.joined(separator: "\n")
        }
        return result
    }
}

/// Agent tool: creates an event in the user's system calendar.
///
/// Input format: line 1 = title, then optional `key: value` lines
/// (`start`, `end`, `location`, `notes`, `allday`); remaining non-key lines
/// become the notes body. `start:` is required. Dates accept ISO 8601,
/// `yyyy-MM-dd HH:mm`, or `yyyy-MM-dd` (which implies an all-day event).
@MainActor
struct CreateCalendarEventTool: AgentTool {
    let name = "create_calendar_event"
    private let calendarAccess: CalendarAgentAccess?

    init(calendarAccess: CalendarAgentAccess? = nil) {
        self.calendarAccess = calendarAccess
    }

    /// Parsed and validated tool input.
    struct ParsedInput: Equatable {
        var title: String
        var start: Date
        var end: Date
        var notes: String?
        var location: String?
        var allDay: Bool
    }

    enum ParseOutcome: Equatable {
        case parsed(ParsedInput)
        case invalid(String)
    }

    func execute(content: String, context: inout AgentContext) async throws -> String {
        // Privacy gate: the user must opt in to AI calendar access in Settings.
        guard AIDataAccess.isCalendarAllowed else {
            return "Calendar access is disabled. The user can enable \"Allow AI to access Calendar\" in Settings to grant access."
        }
        guard let calendarService = calendarAccess?.calendarService else {
            return "The system calendar is not available on this device."
        }

        switch Self.parseInput(content) {
        case .invalid(let message):
            return message
        case .parsed(let input):
            do {
                let event = try await calendarService.createEvent(
                    title: input.title,
                    startDate: input.start,
                    endDate: input.end,
                    notes: input.notes,
                    location: input.location,
                    allDay: input.allDay
                )
                let when = event.allDay
                    ? AgentToolSupport.formatDate(event.startDate)
                    : "\(AgentToolSupport.formatDate(event.startDate)) – \(AgentToolSupport.formatDate(event.endDate))"
                return "Created calendar event \"\(event.title)\" (id: \(event.id), \(when))."
            } catch {
                return "Could not create the calendar event: \(error.localizedDescription)"
            }
        }
    }

    /// Parses the fenced-block body into a validated event, or a message the
    /// model can act on. Pure and nonisolated so it is directly testable.
    nonisolated static func parseInput(_ content: String) -> ParseOutcome {
        var lines = content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        // Line 1 = title (skip leading blank lines).
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }
        guard let titleLine = lines.first else {
            return .invalid("Provide an event title on the first line.")
        }
        let title = titleLine.trimmingCharacters(in: .whitespaces)
        lines.removeFirst()
        guard !title.isEmpty else {
            return .invalid("Provide an event title on the first line.")
        }

        // Remaining lines: `key: value` fields; anything else joins the notes body.
        let fieldKeys: Set<String> = ["start", "end", "location", "notes", "allday", "all_day"]
        var fields: [String: String] = [:]
        var noteLines: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if parts.count == 2, fieldKeys.contains(parts[0].lowercased()) {
                fields[parts[0].lowercased() == "all_day" ? "allday" : parts[0].lowercased()] = parts[1]
            } else if !trimmed.isEmpty {
                noteLines.append(trimmed)
            }
        }

        guard let startRaw = fields["start"], let start = parseDate(startRaw) else {
            return .invalid(
                "Provide a start: line with the event start (e.g. \"start: 2026-08-27 14:00\", ISO 8601, or \"start: 2026-08-27\" for all-day)."
            )
        }

        // Date-only starts imply an all-day event unless overridden.
        var allDay = start.dateOnly
        if let allDayRaw = fields["allday"] {
            allDay = ["true", "yes", "1"].contains(allDayRaw.lowercased())
        }

        let end: Date
        if let endRaw = fields["end"] {
            guard let parsedEnd = parseDate(endRaw) else {
                return .invalid("The end: date could not be parsed. Use the same formats as start:.")
            }
            end = max(parsedEnd.date, start.date)
        } else if allDay {
            end = start.date
        } else {
            end = start.date.addingTimeInterval(3600)
        }

        var notes = fields["notes"] ?? ""
        if !noteLines.isEmpty {
            notes = (notes.isEmpty ? "" : notes + "\n") + noteLines.joined(separator: "\n")
        }

        return .parsed(
            ParsedInput(
                title: title,
                start: start.date,
                end: end,
                notes: notes.isEmpty ? nil : notes,
                location: fields["location"],
                allDay: allDay
            )
        )
    }

    /// Parses the date formats models commonly emit; `dateOnly` marks a bare
    /// `yyyy-MM-dd` (which implies an all-day event).
    nonisolated static func parseDate(_ raw: String) -> (date: Date, dateOnly: Bool)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: trimmed) {
            return (date, false)
        }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: trimmed) {
            return (date, false)
        }

        let formats: [(pattern: String, dateOnly: Bool)] = [
            ("yyyy-MM-dd'T'HH:mm:ss", false),
            ("yyyy-MM-dd'T'HH:mm", false),
            ("yyyy-MM-dd HH:mm:ss", false),
            ("yyyy-MM-dd HH:mm", false),
            ("yyyy-MM-dd", true),
        ]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format.pattern
            if let date = formatter.date(from: trimmed) {
                return (date, format.dateOnly)
            }
        }
        return nil
    }
}

/// Agent tool: lists gallery albums with their image counts and descriptions.
@MainActor
struct ListGalleryAlbumsTool: AgentTool {
    let name = "list_gallery_albums"
    private let repositories: RepositoryBundle

    init(repositories: RepositoryBundle) {
        self.repositories = repositories
    }

    func execute(content: String, context: inout AgentContext) async throws -> String {
        let albums = try repositories.gallery.listAlbums()
        guard !albums.isEmpty else {
            return "No gallery albums found."
        }

        let lines = albums.prefix(AgentToolSupport.listLimit).map { album in
            // Best-effort image count; treat a lookup failure as zero.
            let images = (try? repositories.gallery.listImages(albumID: album.id).count) ?? 0
            let description = album.albumDescription.map { " — \($0)" } ?? ""
            return "- \(album.name) (id: \(album.id), \(images) image(s))\(description)"
        }
        var result = "Gallery albums (\(albums.count)):\n" + lines.joined(separator: "\n")
        if albums.count > AgentToolSupport.listLimit {
            result += "\n... and \(albums.count - AgentToolSupport.listLimit) more."
        }
        return result
    }
}

/// Agent tool: lists model comparison runs (models, winner, prompt preview).
@MainActor
struct ListComparisonsTool: AgentTool {
    let name = "list_comparisons"
    private let repositories: RepositoryBundle

    init(repositories: RepositoryBundle) {
        self.repositories = repositories
    }

    func execute(content: String, context: inout AgentContext) async throws -> String {
        let comparisons = try repositories.comparisons.listComparisons()
        guard !comparisons.isEmpty else {
            return "No model comparisons found."
        }

        let lines = comparisons.prefix(AgentToolSupport.listLimit).map { comparison in
            let promptPreview = comparison.prompt.replacingOccurrences(of: "\n", with: " ").prefix(60)
            let winner = comparison.winner.map { ", winner: \($0)" } ?? ""
            return "- \(comparison.modelA) vs \(comparison.modelB) (id: \(comparison.id)\(winner)) — \(promptPreview)"
        }
        var result = "Comparisons (\(comparisons.count)):\n" + lines.joined(separator: "\n")
        if comparisons.count > AgentToolSupport.listLimit {
            result += "\n... and \(comparisons.count - AgentToolSupport.listLimit) more."
        }
        return result
    }
}

/// Agent tool: composes an email draft (new / reply / forward) for the user.
///
/// The assistant can draft but **never send** — the draft is persisted and shown
/// in the Email workspace for the user to review, edit, and send themselves.
/// Input format: leading `key: value` header lines (to/cc/subject/mode/original/
/// original_subject/account), then a blank line, then the body.
@MainActor
struct DraftEmailTool: AgentTool {
    let name = "draft_email"
    private let repositories: RepositoryBundle

    init(repositories: RepositoryBundle) {
        self.repositories = repositories
    }

    func execute(content: String, context: inout AgentContext) async throws -> String {
        var lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        // Consume leading `key: value` header lines until a blank line or a
        // non-header line; the remainder is the body.
        let headerKeys: Set<String> = ["to", "cc", "subject", "mode", "original", "original_subject", "account"]
        var fields: [String: String] = [:]
        while let first = lines.first {
            let trimmed = first.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                lines.removeFirst()
                break
            }
            let parts = trimmed.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, headerKeys.contains(parts[0].lowercased()) else { break }
            fields[parts[0].lowercased()] = parts[1]
            lines.removeFirst()
        }

        let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            return "Draft body is empty. Provide header lines (to:, subject:, mode:) then a blank line, then the body."
        }

        let modeRaw = (fields["mode"] ?? "new").lowercased().replacingOccurrences(of: " ", with: "_")
        let mode = EmailDraftMode(rawValue: modeRaw) ?? .new
        let to = fields["to"] ?? ""
        let subject = fields["subject"] ?? ""

        let draft = try repositories.emailDrafts.createDraft(
            mode: mode.rawValue,
            toRecipients: to,
            ccRecipients: fields["cc"] ?? "",
            subject: subject,
            body: body,
            originalMessageID: fields["original"]?.nilIfEmpty,
            originalSubject: fields["original_subject"]?.nilIfEmpty,
            accountID: fields["account"]?.nilIfEmpty,
            source: "ai",
            sessionID: context.sessionID
        )

        return """
        Saved \(mode.displayName) draft (id: \(draft.id)) to Drafts. To: \(to.nilIfEmpty ?? "—"), Subject: \(subject.nilIfEmpty ?? "—").
        The user can review and send it from the Email tab (Drafts or Reply buttons).
        """
    }
}

/// Assembles the complete standard tool set the agent is given by default.
///
/// Tools needing data access get the `RepositoryBundle`; memory tools get the
/// `MemoryService`. The order here is the registration order; the registry keys
/// them by name regardless.
@MainActor
enum AgentStandardTools {
    /// Builds every standard tool, wired to the provided repositories and memory service.
    static func all(
        repositories: RepositoryBundle,
        memoryService: MemoryService,
        calendarAccess: CalendarAgentAccess? = nil
    ) -> [any AgentTool] {
        [
            // Unified search
            SearchTool(repositories: repositories),
            // Documents
            ListDocumentsTool(repositories: repositories),
            ReadDocumentTool(repositories: repositories),
            CreateDocumentTool(repositories: repositories),
            EditDocumentTool(repositories: repositories),
            UpdateDocumentTool(repositories: repositories),
            AppendDocumentTool(repositories: repositories),
            // Folders (Documents & Notes trees)
            ListFoldersTool(repositories: repositories),
            BrowseFolderTool(repositories: repositories),
            CreateFolderTool(repositories: repositories),
            MoveItemTool(repositories: repositories),
            // Notes
            ListNotesTool(repositories: repositories),
            ReadNoteTool(repositories: repositories),
            CreateNoteTool(repositories: repositories),
            UpdateNoteTool(repositories: repositories),
            // Chats
            ListChatsTool(repositories: repositories),
            ReadChatTool(repositories: repositories),
            // Tasks
            ListTasksTool(repositories: repositories),
            CreateTaskTool(repositories: repositories),
            ListSubtasksTool(repositories: repositories),
            // Research
            ListResearchTool(repositories: repositories),
            ReadResearchTool(repositories: repositories),
            CreateResearchTool(repositories: repositories),
            UpdateResearchTool(repositories: repositories),
            AppendResearchTool(repositories: repositories),
            // Email drafts (compose only; never sends)
            DraftEmailTool(repositories: repositories),
            // Calendar & gallery
            ListCalendarEventsTool(repositories: repositories, calendarAccess: calendarAccess),
            CreateCalendarEventTool(calendarAccess: calendarAccess),
            ListGalleryAlbumsTool(repositories: repositories),
            ListComparisonsTool(repositories: repositories),
            // Memory
            ListMemoriesTool(memoryService: memoryService),
            SearchMemoryTool(memoryService: memoryService),
            SaveMemoryTool(memoryService: memoryService),
            // Date & time
            CurrentDateTool(),
        ]
    }

    /// Tools an agent *task* may call: documents and research only — never email or calendar.
    static func taskWorkspace(repositories: RepositoryBundle) -> [any AgentTool] {
        [
            SearchTool(
                repositories: repositories,
                allowedKinds: [.document, .research]
            ),
            ListDocumentsTool(repositories: repositories),
            ReadDocumentTool(repositories: repositories),
            WriteDocumentTool(),
            EditDocumentTool(repositories: repositories),
            UpdateDocumentTool(repositories: repositories),
            AppendDocumentTool(repositories: repositories),
            ListResearchTool(repositories: repositories),
            ReadResearchTool(repositories: repositories),
            RunResearchTool(),
            CurrentDateTool(),
        ]
    }
}
