// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import AnAIOdysseyCore

/// Agent tool: semantically searches the user's saved memories.
///
/// Input is a free-text query; returns the top matches with similarity scores so
/// the model can recall relevant facts about the user.
@MainActor
struct SearchMemoryTool: AgentTool {
    let name = "search_memory"
    private let memoryService: MemoryService

    init(memoryService: MemoryService) {
        self.memoryService = memoryService
    }

    func execute(content: String, context: inout AgentContext) async throws -> String {
        let query = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return "Provide a search query."
        }

        // Vector-search the memory store for the closest few entries.
        let results = try await memoryService.search(query: query, topK: 5)
        guard !results.isEmpty else {
            return "No matching memories."
        }

        // Render each hit with its similarity score for the model to weigh.
        let lines = results.enumerated().map { index, result in
            let score = String(format: "%.2f", result.score)
            return "\(index + 1). [\(score)] \(result.memory.text)"
        }
        return "Found \(results.count) memory(ies):\n" + lines.joined(separator: "\n")
    }
}

/// Agent tool: persists a long-term fact about the user.
///
/// Input is the raw text to remember; the saved memory is tagged with the current
/// session. Intended for durable user facts, not transient or user-visible notes.
@MainActor
struct SaveMemoryTool: AgentTool {
    let name = "save_memory"
    private let memoryService: MemoryService

    init(memoryService: MemoryService) {
        self.memoryService = memoryService
    }

    func execute(content: String, context: inout AgentContext) async throws -> String {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return "Provide memory text to save."
        }

        let memory = try await memoryService.save(text: text, sessionID: context.sessionID)
        return "Saved memory (id: \(memory.id))."
    }
}

/// Agent tool: lists all saved memories, newest first.
///
/// Takes no input; output is capped at `listLimit` with a "+N more" note.
@MainActor
struct ListMemoriesTool: AgentTool {
    let name = "list_memories"
    private let memoryService: MemoryService

    init(memoryService: MemoryService) {
        self.memoryService = memoryService
    }

    func execute(content: String, context: inout AgentContext) async throws -> String {
        let memories = try memoryService.listAll()
        guard !memories.isEmpty else {
            return "No saved memories."
        }

        // Newest first, previewed on a single line and capped at the list limit.
        let sorted = memories.sorted { $0.createdAt > $1.createdAt }
        let lines = sorted.prefix(AgentToolSupport.listLimit).map { memory in
            let preview = memory.text.replacingOccurrences(of: "\n", with: " ").prefix(120)
            return "- [\(AgentToolSupport.formatDate(memory.createdAt))] \(preview) (id: \(memory.id))"
        }
        var result = "Memories (\(memories.count)):\n" + lines.joined(separator: "\n")
        if memories.count > AgentToolSupport.listLimit {
            result += "\n... and \(memories.count - AgentToolSupport.listLimit) more."
        }
        return result
    }
}
