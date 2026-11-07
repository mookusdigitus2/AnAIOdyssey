// SPDX-License-Identifier: MIT
import Foundation

/// Lifecycle of an agent task run after "run with assignee" was removed.
public enum AgentTaskRunStatus: String, Sendable, CaseIterable, Codable {
    case running
    case paused
    case stopped
    case done
    case error

    public var displayName: String {
        switch self {
        case .running: "Running"
        case .paused: "Paused"
        case .stopped: "Stopped"
        case .done: "Done"
        case .error: "Error"
        }
    }

    /// Maps historical queue statuses onto the pause/continue/stop machine.
    public static func migrateStored(_ raw: String) -> AgentTaskRunStatus {
        switch raw {
        case running.rawValue, "in_progress", "claimed":
            .running
        case paused.rawValue, "pending", "blocked", "handoff_human", "handoff_ai":
            .paused
        case stopped.rawValue:
            .stopped
        case done.rawValue, "completed":
            .done
        case error.rawValue, "failed":
            .error
        default:
            .paused
        }
    }

    /// Cold-start recovery: in-flight work cannot be trusted after process death.
    /// Mark it paused so the user can Continue (safer than silently hitting the network).
    public static func statusAfterLaunchRecovery(_ status: AgentTaskRunStatus) -> AgentTaskRunStatus {
        status == .running ? .paused : status
    }
}

/// User controls on a running or paused task.
public enum AgentTaskRunCommand: String, Sendable {
    case pause
    case continueRun = "continue"
    case stop
}

/// One Document or Research item a task created or edited.
public struct AgentTaskChangeEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var action: String
    public var kind: String
    public var itemID: String
    public var title: String

    public init(
        id: String = UUID().uuidString,
        action: String,
        kind: String,
        itemID: String,
        title: String
    ) {
        self.id = id
        self.action = action
        self.kind = kind
        self.itemID = itemID
        self.title = title
    }

    public var label: String {
        AgentTaskRunPolicy.changeLogLabel(action: action, title: title)
    }
}

/// Portable task-run rules: tools, pause/continue/stop, copy, and change-log JSON.
public enum AgentTaskRunPolicy {
    public static let boundarySentence =
        "Tasks can read and edit your documents and research. They can't see your email or calendar."

    public static let allowedToolNames: Set<String> = [
        "search",
        "list_documents",
        "read_document",
        "write_document",
        "edit_document",
        "update_document",
        "append_document",
        "list_research",
        "read_research",
        "run_research",
    ]

    /// Tools that write a Research item without going through the Research feature.
    public static let selfAuthoredResearchWriteTools: Set<String> = [
        "create_research",
        "update_research",
        "append_research",
    ]

    /// Tools that compose a full Document without going through the Documents writer.
    public static let selfAuthoredDocumentWriteTools: Set<String> = [
        "create_document",
    ]

    public static let deniedToolNames: Set<String> = [
        "list_emails",
        "read_email",
        "draft_email",
        "list_calendar_events",
        "create_calendar_event",
    ]

    public static func containsEmailOrCalendar(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("email") || lower.contains("calendar")
    }

    public static func isDenied(_ name: String) -> Bool {
        deniedToolNames.contains(name) || containsEmailOrCalendar(name)
    }

    public static func isAllowed(_ name: String) -> Bool {
        allowedToolNames.contains(name) && !isDenied(name)
    }

    public static func assertNoEmailOrCalendar(in toolNames: Set<String>) -> Bool {
        toolNames.allSatisfy { !isDenied($0) }
    }

    public static func apply(
        _ command: AgentTaskRunCommand,
        to status: AgentTaskRunStatus
    ) -> AgentTaskRunStatus? {
        switch (command, status) {
        case (.pause, .running):
            .paused
        case (.continueRun, .paused):
            .running
        case (.stop, .running), (.stop, .paused):
            .stopped
        default:
            nil
        }
    }

    public static func canPauseOrContinue(_ status: AgentTaskRunStatus) -> Bool {
        status == .running || status == .paused
    }

    public static func canStop(_ status: AgentTaskRunStatus) -> Bool {
        status == .running || status == .paused
    }

    public static func statusLine(
        status: AgentTaskRunStatus,
        currentAction: String? = nil,
        errorMessage: String? = nil
    ) -> String {
        switch status {
        case .running:
            if let currentAction, !currentAction.isEmpty {
                return "Running: \(currentAction)"
            }
            return "Running"
        case .paused:
            return "Paused"
        case .stopped:
            return "Stopped"
        case .done:
            return "Done"
        case .error:
            return "Error: \(shortError(errorMessage ?? "Unknown error"))"
        }
    }

    public static func shortError(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 80 { return trimmed }
        return String(trimmed.prefix(77)) + "…"
    }

    public static func changeLogLabel(action: String, title: String) -> String {
        switch action {
        case "created":
            return "Created \(title)"
        case "edited", "updated", "appended":
            return "Edited \(title)"
        case "researched":
            return "Researched \(title)"
        default:
            return "\(action.capitalized) \(title)"
        }
    }

    /// Assignments that should be handed to the Research tab pipeline.
    public static func shouldUseResearchFeature(_ assignment: String) -> Bool {
        let lower = assignment.lowercased()
        let needles = [
            "research",
            "look up",
            "look into",
            "investigate",
            "find sources",
            "web search",
            "search the web",
            "gather sources",
        ]
        return needles.contains { lower.contains($0) }
    }

    /// Assignments that should be handed to the Documents writing pipeline.
    public static func shouldUseDocumentsFeature(_ assignment: String) -> Bool {
        let lower = assignment.lowercased()
        if isEditOnlyDocumentAssignment(lower) {
            return false
        }
        let writeNeedles = [
            "write a document",
            "write the document",
            "create a document",
            "draft a document",
            "compose a document",
            "write up",
            "new document",
            "document titled",
            "as a document",
            "into a document",
            "write a ",
            "draft a ",
            "create a ",
            "compose a ",
        ]
        if writeNeedles.contains(where: { lower.contains($0) }) {
            return true
        }
        let mentionsDocument = lower.contains("document") || lower.contains(" doc")
        let mentionsWrite = lower.contains("write") || lower.contains("draft") || lower.contains("compose") || lower.contains("create")
        return mentionsDocument && mentionsWrite
    }

    /// Research first, then document writing, so a combined assignment can do both.
    public static func preferredTools(forAssignment assignment: String) -> [String] {
        var tools: [String] = []
        if shouldUseResearchFeature(assignment) {
            tools.append("run_research")
        }
        if shouldUseDocumentsFeature(assignment) {
            tools.append("write_document")
        }
        return tools
    }

    public static func preferredTool(forAssignment assignment: String) -> String? {
        preferredTools(forAssignment: assignment).first
    }

    public static func isSelfAuthoredResearchWrite(_ name: String) -> Bool {
        selfAuthoredResearchWriteTools.contains(name)
    }

    public static func isSelfAuthoredDocumentWrite(_ name: String) -> Bool {
        selfAuthoredDocumentWriteTools.contains(name)
    }

    public static func shouldBlockSelfAuthoredResearch(assignment: String, toolName: String) -> Bool {
        shouldUseResearchFeature(assignment) && isSelfAuthoredResearchWrite(toolName)
    }

    public static func shouldBlockSelfAuthoredDocumentWrite(assignment: String, toolName: String) -> Bool {
        shouldUseDocumentsFeature(assignment) && isSelfAuthoredDocumentWrite(toolName)
    }

    public static func researchQuery(fromToolInput input: String) -> String {
        let lines = input
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        for line in lines {
            let lower = line.lowercased()
            if lower.hasPrefix("query:") {
                return String(line.dropFirst("query:".count)).trimmingCharacters(in: .whitespaces)
            }
            if lower.hasPrefix("topic:") {
                return String(line.dropFirst("topic:".count)).trimmingCharacters(in: .whitespaces)
            }
            if !line.isEmpty {
                return line
            }
        }
        return ""
    }

    /// Parsed `write_document` tool body (title / brief / optional existing id).
    public struct DocumentWriteInput: Equatable, Sendable {
        public var title: String?
        public var brief: String
        public var documentID: String?
        public var context: String?

        public init(
            title: String? = nil,
            brief: String,
            documentID: String? = nil,
            context: String? = nil
        ) {
            self.title = title
            self.brief = brief
            self.documentID = documentID
            self.context = context
        }
    }

    public static func parseDocumentWriteInput(_ input: String) -> DocumentWriteInput {
        var title: String?
        var documentID: String?
        var contextParts: [String] = []
        var briefParts: [String] = []

        for raw in input.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let lower = line.lowercased()
            if lower.hasPrefix("title:") {
                title = String(line.dropFirst("title:".count)).trimmingCharacters(in: .whitespaces)
            } else if lower.hasPrefix("document:") || lower.hasPrefix("document_id:") || lower.hasPrefix("id:") {
                let value = line.split(separator: ":", maxSplits: 1).dropFirst().joined(separator: ":")
                documentID = value.trimmingCharacters(in: .whitespaces)
            } else if lower.hasPrefix("context:") {
                let value = String(line.dropFirst("context:".count)).trimmingCharacters(in: .whitespaces)
                if !value.isEmpty {
                    contextParts.append(value)
                }
            } else if lower.hasPrefix("brief:") {
                let value = String(line.dropFirst("brief:".count)).trimmingCharacters(in: .whitespaces)
                if !value.isEmpty {
                    briefParts.append(value)
                }
            } else if !line.isEmpty {
                briefParts.append(line)
            }
        }

        var brief = briefParts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if title == nil, let first = briefParts.first, briefParts.count > 1, first.count <= 80 {
            title = first
            brief = briefParts.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if brief.isEmpty {
            brief = title ?? ""
        }
        let context = contextParts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return DocumentWriteInput(
            title: nonEmpty(title),
            brief: brief,
            documentID: nonEmpty(documentID),
            context: nonEmpty(context)
        )
    }

    public static func documentTitle(requested: String?, body: String, brief: String) -> String {
        if let requested {
            let trimmed = requested.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        for raw in body.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                line = line.drop(while: { $0 == "#" || $0 == " " }).trimmingCharacters(in: .whitespaces)
                if !line.isEmpty {
                    return line
                }
            }
        }
        if let first = body
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty }),
           first.count <= 80 {
            return first
        }
        let briefFirst = brief
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        if !briefFirst.isEmpty {
            return String(briefFirst.prefix(80))
        }
        return "Untitled"
    }

    /// Pause or Stop must abort an in-flight Research or Documents feature run.
    public static func shouldAbortFeatureRun(pauseRequested: Bool, stopRequested: Bool) -> Bool {
        pauseRequested || stopRequested
    }

    public static func shouldAbortResearchRun(pauseRequested: Bool, stopRequested: Bool) -> Bool {
        shouldAbortFeatureRun(pauseRequested: pauseRequested, stopRequested: stopRequested)
    }

    public static func shouldAbortDocumentWrite(pauseRequested: Bool, stopRequested: Bool) -> Bool {
        shouldAbortFeatureRun(pauseRequested: pauseRequested, stopRequested: stopRequested)
    }

    public static func currentAction(forTool name: String) -> String {
        switch name {
        case "create_document", "write_document": return "writing a document"
        case "edit_document", "update_document", "append_document": return "updating a document"
        case "read_document", "list_documents": return "reading documents"
        case "create_research": return "creating research"
        case "run_research": return "researching"
        case "update_research", "append_research": return "updating research"
        case "read_research", "list_research": return "reading research"
        case "search": return "searching documents and research"
        default: return name.replacingOccurrences(of: "_", with: " ")
        }
    }

    public static func currentAction(action: String, title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return action
        }
        switch action {
        case "created":
            return "creating \(trimmed)"
        case "edited", "updated", "appended":
            return "updating \(trimmed)"
        case "researched":
            return "researching \(trimmed)"
        default:
            return "\(action) \(trimmed)"
        }
    }

    public static func changeFromTool(name: String, result: String) -> AgentTaskChangeEntry? {
        switch name {
        case "create_document":
            return parseChange(action: "created", kind: "document", result: result, titleFallback: "Document")
        case "write_document":
            let action = result.lowercased().contains("edited document") || result.lowercased().hasPrefix("edited ")
                ? "edited"
                : "created"
            return parseChange(action: action, kind: "document", result: result, titleFallback: "Document")
        case "edit_document", "update_document", "append_document":
            return parseChange(action: "edited", kind: "document", result: result, titleFallback: "Document")
        case "create_research":
            return parseChange(action: "created", kind: "research", result: result, titleFallback: "Research")
        case "run_research":
            return parseChange(action: "researched", kind: "research", result: result, titleFallback: "Research")
        case "update_research", "append_research":
            return parseChange(action: "edited", kind: "research", result: result, titleFallback: "Research")
        default:
            return nil
        }
    }

    public static func encodeChangeLog(_ entries: [AgentTaskChangeEntry]) -> String {
        guard let data = try? JSONEncoder().encode(entries),
              let text = String(data: data, encoding: .utf8)
        else {
            return "[]"
        }
        return text
    }

    public static func decodeChangeLog(_ json: String?) -> [AgentTaskChangeEntry] {
        guard let json, let data = json.data(using: .utf8),
              let entries = try? JSONDecoder().decode([AgentTaskChangeEntry].self, from: data)
        else {
            return []
        }
        return entries
    }

    public static func appendChange(
        _ entry: AgentTaskChangeEntry,
        to json: String?
    ) -> String {
        var entries = decodeChangeLog(json)
        if let existing = entries.firstIndex(where: {
            $0.kind == entry.kind && $0.itemID == entry.itemID
        }) {
            entries[existing].action = entry.action
            entries[existing].title = entry.title
        } else {
            entries.append(entry)
        }
        return encodeChangeLog(entries)
    }

    private static func isEditOnlyDocumentAssignment(_ lower: String) -> Bool {
        let editNeedles = ["edit ", "update ", "append ", "fix ", "tweak "]
        let writeNeedles = ["write", "draft", "compose", "create"]
        let isEdit = editNeedles.contains { lower.contains($0) }
        let isWrite = writeNeedles.contains { lower.contains($0) }
        return isEdit && !isWrite
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func parseChange(
        action: String,
        kind: String,
        result: String,
        titleFallback: String
    ) -> AgentTaskChangeEntry? {
        let title = parseQuotedTitle(result)
            ?? parseLabeledTitle(result)
            ?? titleFallback
        let itemID = parseID(result) ?? title
        return AgentTaskChangeEntry(
            action: action,
            kind: kind,
            itemID: itemID,
            title: title
        )
    }

    private static func parseQuotedTitle(_ text: String) -> String? {
        guard let start = text.firstIndex(of: "'") else { return nil }
        let after = text.index(after: start)
        guard let end = text[after...].firstIndex(of: "'") else { return nil }
        let title = String(text[after..<end]).trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : title
    }

    private static func parseLabeledTitle(_ text: String) -> String? {
        for prefix in ["Document edited: ", "Updated document ", "Created document ", "Edited document ", "Updated research ", "Research: ", "Researched "] {
            guard text.hasPrefix(prefix) else { continue }
            var rest = String(text.dropFirst(prefix.count))
            if let comma = rest.firstIndex(of: ",") {
                rest = String(rest[..<comma])
            }
            if let paren = rest.firstIndex(of: "(") {
                rest = String(rest[..<paren])
            }
            rest = rest.trimmingCharacters(in: .whitespaces)
            return rest.isEmpty ? nil : rest
        }
        return nil
    }

    private static func parseID(_ text: String) -> String? {
        guard let range = text.range(of: "id: ") else { return nil }
        var rest = String(text[range.upperBound...])
        if let end = rest.firstIndex(where: { !$0.isLetter && !$0.isNumber && $0 != "-" }) {
            rest = String(rest[..<end])
        }
        rest = rest.trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? nil : rest
    }
}
