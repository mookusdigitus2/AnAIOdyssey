// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import AnAIOdysseyCore

/// Agent-loop tools for the multi-agent central queue.
public enum AgentQueueTools {
    public static func make(agentController: AgentController) -> (tools: [any AgentTool], descriptions: String) {
        let tools: [any AgentTool] = [
            ListAgentTasksTool(controller: agentController),
            EnqueueAgentTaskTool(controller: agentController),
        ]
        let descriptions = """
        ## Agent tasks
        ```list_agent_tasks
        <optional status: running|paused|stopped|done|error>
        ```
        List agent tasks.

        ```enqueue_agent_task
        title: ...
        assignment: ...
        context: ... (optional)
        ```
        Create a task. It starts immediately and can read/edit documents and research.
        """
        return (tools, descriptions)
    }
}

private struct ListAgentTasksTool: AgentTool {
    let name = "list_agent_tasks"
    let controller: AgentController

    func execute(content: String, context: inout AgentContext) async throws -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let status = trimmed.isEmpty ? nil : trimmed
        let tasks = try controller.listQueueTasks(status: status)
        if tasks.isEmpty { return "No agent tasks found." }
        return tasks.map { t in
            "- \(t.title) [\(t.status)] id=\(t.id)"
        }.joined(separator: "\n")
    }
}

private struct EnqueueAgentTaskTool: AgentTool {
    let name = "enqueue_agent_task"
    let controller: AgentController

    func execute(content: String, context: inout AgentContext) async throws -> String {
        var title = "Untitled"
        var assignment = ""
        var ctx: String?
        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(line)
            if s.lowercased().hasPrefix("title:") {
                title = s.dropFirst(6).trimmingCharacters(in: .whitespaces)
            } else if s.lowercased().hasPrefix("assignment:") {
                assignment = s.dropFirst(11).trimmingCharacters(in: .whitespaces)
            } else if s.lowercased().hasPrefix("context:") {
                ctx = s.dropFirst(8).trimmingCharacters(in: .whitespaces)
            } else if assignment.isEmpty && !s.trimmingCharacters(in: .whitespaces).isEmpty {
                assignment = s.trimmingCharacters(in: .whitespaces)
            }
        }
        guard !assignment.isEmpty else {
            return "Provide assignment: (prompt) in the tool block."
        }
        let task = try controller.enqueue(
            title: title,
            assignment: assignment,
            contextInline: ctx,
            sessionID: context.sessionID
        )
        return "Started agent task \"\(task.title)\" (id: \(task.id))."
    }
}
