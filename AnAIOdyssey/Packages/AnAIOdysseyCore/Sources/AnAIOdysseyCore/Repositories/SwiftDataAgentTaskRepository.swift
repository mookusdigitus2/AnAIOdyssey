// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import SwiftData

@MainActor
public final class SwiftDataAgentTaskRepository: AgentTaskRepositoryProtocol {
    private let context: ModelContext

    public init(context: ModelContext) {
        self.context = context
    }

    @discardableResult
    public func createTask(
        title: String,
        assignment: String,
        controllerAgentID: String?,
        assigneeAgentID: String?,
        contextInline: String?,
        contextFileName: String?,
        parentTaskID: String?,
        sessionID: String?,
        priority: Int
    ) throws -> AgentTask {
        let task = AgentTask(
            title: title,
            assignment: assignment,
            assigneeAgentID: assigneeAgentID,
            controllerAgentID: controllerAgentID,
            contextInline: contextInline,
            contextFileName: contextFileName,
            parentTaskID: parentTaskID,
            sessionID: sessionID,
            priority: priority
        )
        context.insert(task)
        try save()
        return task
    }

    public func fetchTask(id: String) throws -> AgentTask? {
        let descriptor = FetchDescriptor<AgentTask>(predicate: #Predicate { $0.id == id })
        return try context.fetch(descriptor).first
    }

    public func listTasks(status: String?) throws -> [AgentTask] {
        let sort = [
            SortDescriptor<AgentTask>(\.priority, order: .reverse),
            SortDescriptor<AgentTask>(\.updatedAt, order: .reverse),
        ]
        let descriptor: FetchDescriptor<AgentTask>
        if let status {
            descriptor = FetchDescriptor(
                predicate: #Predicate { $0.status == status && $0.parentTaskID == nil },
                sortBy: sort
            )
        } else {
            descriptor = FetchDescriptor(
                predicate: #Predicate { $0.parentTaskID == nil },
                sortBy: sort
            )
        }
        return try context.fetch(descriptor)
    }

    public func listAllTasks(status: String?) throws -> [AgentTask] {
        let sort = [
            SortDescriptor<AgentTask>(\.priority, order: .reverse),
            SortDescriptor<AgentTask>(\.updatedAt, order: .reverse),
        ]
        if let status {
            let descriptor = FetchDescriptor<AgentTask>(
                predicate: #Predicate { $0.status == status },
                sortBy: sort
            )
            return try context.fetch(descriptor)
        }
        return try context.fetch(FetchDescriptor<AgentTask>(sortBy: sort))
    }

    public func listSubtasks(parentTaskID: String?) throws -> [AgentTask] {
        let sort = [
            SortDescriptor<AgentTask>(\.priority, order: .reverse),
            SortDescriptor<AgentTask>(\.updatedAt, order: .reverse),
        ]
        if let parentTaskID {
            let descriptor = FetchDescriptor<AgentTask>(
                predicate: #Predicate { $0.parentTaskID == parentTaskID },
                sortBy: sort
            )
            return try context.fetch(descriptor)
        }
        return []
    }

    public func updateTask(
        id: String,
        title: String?,
        assignment: String?,
        status: String?,
        assigneeAgentID: String?,
        handoffTarget: String?,
        contextInline: String?,
        contextFileName: String?,
        resultSummary: String?
    ) throws {
        guard let task = try fetchTask(id: id) else {
            throw RepositoryError.notFound(id)
        }
        if let title { task.title = title }
        if let assignment { task.assignment = assignment }
        if let status { task.status = status }
        if let assigneeAgentID { task.assigneeAgentID = assigneeAgentID }
        if let handoffTarget { task.handoffTarget = handoffTarget }
        if let contextInline { task.contextInline = contextInline }
        if let contextFileName { task.contextFileName = contextFileName }
        if let resultSummary { task.resultSummary = resultSummary }
        task.updatedAt = .now
        try save()
    }

    public func deleteTask(id: String) throws {
        guard let task = try fetchTask(id: id) else {
            throw RepositoryError.notFound(id)
        }
        context.delete(task)
        try save()
    }

    public func save() throws {
        try context.save()
    }
}
