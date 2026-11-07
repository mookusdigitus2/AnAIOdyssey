// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import SwiftData

/// SwiftData-backed implementation of `TaskRepositoryProtocol`.
@MainActor
public final class SwiftDataTaskRepository: TaskRepositoryProtocol {
    /// The shared SwiftData context all operations run against.
    private let context: ModelContext

    /// Binds the repository to a `ModelContext`.
    public init(context: ModelContext) {
        self.context = context
    }

    @discardableResult
    public func createTask(
        name: String,
        prompt: String?,
        schedule: String?,
        scheduledTime: String?,
        scheduledDate: Date?,
        sessionID: String?
    ) throws -> ScheduledTask {
        try createTask(
            name: name,
            prompt: prompt,
            schedule: schedule,
            scheduledTime: scheduledTime,
            scheduledDate: scheduledDate,
            sessionID: sessionID,
            parentTaskID: nil
        )
    }

    @discardableResult
    public func createTask(
        name: String,
        prompt: String?,
        schedule: String?,
        scheduledTime: String?,
        scheduledDate: Date?,
        sessionID: String?,
        parentTaskID: String?
    ) throws -> ScheduledTask {
        let task = ScheduledTask(
            parentTaskID: parentTaskID,
            name: name,
            prompt: prompt,
            schedule: schedule,
            scheduledTime: scheduledTime,
            scheduledDate: scheduledDate,
            sessionID: sessionID
        )
        context.insert(task)
        try save()
        return task
    }

    public func listSubtasks(parentTaskID: String?, status: String? = nil) throws -> [ScheduledTask] {
        // Branch over the (optional) parent and status filters; SwiftData can't
        // compare an optional field to a variable optional inside `#Predicate`.
        let sort = [
            SortDescriptor<ScheduledTask>(\.sortOrder, order: .forward),
            SortDescriptor<ScheduledTask>(\.nextRun, order: .forward),
            SortDescriptor<ScheduledTask>(\.updatedAt, order: .reverse),
        ]
        let descriptor: FetchDescriptor<ScheduledTask>
        switch (parentTaskID, status) {
        case let (parentTaskID?, status?):
            descriptor = FetchDescriptor<ScheduledTask>(
                predicate: #Predicate { $0.parentTaskID == parentTaskID && $0.status == status },
                sortBy: sort
            )
        case let (parentTaskID?, nil):
            descriptor = FetchDescriptor<ScheduledTask>(
                predicate: #Predicate { $0.parentTaskID == parentTaskID },
                sortBy: sort
            )
        case let (nil, status?):
            descriptor = FetchDescriptor<ScheduledTask>(
                predicate: #Predicate { $0.parentTaskID == nil && $0.status == status },
                sortBy: sort
            )
        case (nil, nil):
            descriptor = FetchDescriptor<ScheduledTask>(
                predicate: #Predicate { $0.parentTaskID == nil },
                sortBy: sort
            )
        }
        return try context.fetch(descriptor)
    }

    public func fetchTask(id: String) throws -> ScheduledTask? {
        let descriptor = FetchDescriptor<ScheduledTask>(
            predicate: #Predicate { $0.id == id }
        )
        return try context.fetch(descriptor).first
    }

    public func listTasks(status: String? = nil) throws -> [ScheduledTask] {
        // Order by soonest next run, then by recency for ties/unscheduled tasks.
        // Build the descriptor with or without the status filter accordingly.
        let descriptor: FetchDescriptor<ScheduledTask>
        if let status {
            descriptor = FetchDescriptor<ScheduledTask>(
                predicate: #Predicate { $0.status == status },
                sortBy: [
                    SortDescriptor(\.nextRun, order: .forward),
                    SortDescriptor(\.updatedAt, order: .reverse),
                ]
            )
        } else {
            descriptor = FetchDescriptor<ScheduledTask>(
                sortBy: [
                    SortDescriptor(\.nextRun, order: .forward),
                    SortDescriptor(\.updatedAt, order: .reverse),
                ]
            )
        }
        return try context.fetch(descriptor)
    }

    public func updateTask(
        id: String,
        name: String?,
        prompt: String?,
        schedule: String?,
        scheduledTime: String?,
        scheduledDate: Date?,
        status: String?,
        nextRun: Date?
    ) throws {
        guard let task = try fetchTask(id: id) else {
            throw RepositoryError.notFound(id)
        }
        // Apply only the provided fields; nil arguments leave the value untouched
        // (partial update semantics).
        if let name { task.name = name }
        if let prompt { task.prompt = prompt }
        if let schedule { task.schedule = schedule }
        if let scheduledTime { task.scheduledTime = scheduledTime }
        if let scheduledDate { task.scheduledDate = scheduledDate }
        if let status { task.status = status }
        if let nextRun { task.nextRun = nextRun }
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
