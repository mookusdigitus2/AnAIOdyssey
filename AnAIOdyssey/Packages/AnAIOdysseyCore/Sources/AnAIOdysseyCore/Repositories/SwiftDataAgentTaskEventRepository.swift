// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import SwiftData

@MainActor
public final class SwiftDataAgentTaskEventRepository: AgentTaskEventRepositoryProtocol {
    private let context: ModelContext

    public init(context: ModelContext) {
        self.context = context
    }

    @discardableResult
    public func appendEvent(
        taskID: String,
        actorType: String,
        actorID: String?,
        action: String,
        message: String
    ) throws -> AgentTaskEvent {
        let event = AgentTaskEvent(
            taskID: taskID,
            actorType: actorType,
            actorID: actorID,
            action: action,
            message: message
        )
        context.insert(event)
        try save()
        return event
    }

    public func listEvents(taskID: String) throws -> [AgentTaskEvent] {
        let descriptor = FetchDescriptor<AgentTaskEvent>(
            predicate: #Predicate { $0.taskID == taskID },
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        return try context.fetch(descriptor)
    }

    public func deleteEvents(taskID: String) throws {
        let events = try listEvents(taskID: taskID)
        for event in events {
            context.delete(event)
        }
        if !events.isEmpty {
            try save()
        }
    }

    public func save() throws {
        try context.save()
    }
}
