// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import AnAIOdysseyCore

/// Agent tool: unified keyword search across AnAIOdyssey data.
@MainActor
struct SearchTool: AgentTool {
    let name = "search"
    private let searchService: UnifiedSearchService
    private let allowedKinds: Set<SearchHit.Kind>?

    init(repositories: RepositoryBundle, allowedKinds: Set<SearchHit.Kind>? = nil) {
        self.searchService = UnifiedSearchService(repositories: repositories)
        self.allowedKinds = allowedKinds
    }

    func execute(content: String, context: inout AgentContext) async throws -> String {
        let lines = content.components(separatedBy: .newlines)
        let query = parseSearchQuery(from: lines)
        guard !query.isEmpty else {
            return "Provide a search query on the first line."
        }

        var kinds: Set<SearchHit.Kind>? = allowedKinds
        var limit = 10
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.lowercased().hasPrefix("kinds:") {
                let raw = trimmed.dropFirst("kinds:".count)
                let names = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                let requested = Set(names.compactMap { mapKind($0) })
                if let allowedKinds {
                    kinds = requested.isEmpty ? allowedKinds : requested.intersection(allowedKinds)
                } else {
                    kinds = requested
                }
            } else if trimmed.lowercased().hasPrefix("limit:"),
                      let value = Int(trimmed.dropFirst("limit:".count).trimmingCharacters(in: .whitespaces)) {
                limit = min(max(value, 1), 20)
            }
        }

        let hits = try searchService.search(query: query, kinds: kinds, limit: limit)
        guard !hits.isEmpty else {
            var message = "No results for \"\(query)\"."
            if allowedKinds == nil, kinds != nil, !AIDataAccess.isCalendarAllowed {
                message += " Calendar results require AI calendar access in Settings."
            }
            return message
        }

        let formatted = hits.map { hit in
            let dateText = hit.date.map { AgentToolSupport.formatDate($0) } ?? "—"
            return "- [\(hit.kind.rawValue)] \(hit.title) (id: \(hit.entityID), \(dateText)) — \"\(hit.snippet)\""
        }
        return "Results (\(hits.count)):\n" + formatted.joined(separator: "\n")
    }

    private func parseSearchQuery(from lines: [String]) -> String {
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if trimmed.lowercased().hasPrefix("kinds:") || trimmed.lowercased().hasPrefix("limit:") {
                continue
            }
            if trimmed.lowercased().hasPrefix("query:") {
                return String(trimmed.dropFirst("query:".count)).trimmingCharacters(in: .whitespaces)
            }
            return trimmed
        }
        return ""
    }

    private func mapKind(_ raw: String) -> SearchHit.Kind? {
        switch raw.lowercased() {
        case "documents", "document": .document
        case "notes", "note": .note
        case "chats", "chat": .chat
        case "tasks", "task", "scheduled_tasks": .scheduledTask
        case "agent_tasks", "agent": .agentTask
        case "research": .research
        case "memories", "memory": .memory
        case "email", "email_drafts", "drafts": .emailDraft
        case "calendar", "events": .calendarEvent
        case "gallery", "albums": .galleryAlbum
        case "comparisons", "compare": .comparison
        default: SearchHit.Kind(rawValue: raw.lowercased())
        }
    }
}
