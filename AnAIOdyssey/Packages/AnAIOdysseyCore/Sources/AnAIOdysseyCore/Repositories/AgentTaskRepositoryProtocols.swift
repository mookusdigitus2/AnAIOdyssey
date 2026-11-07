// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import SwiftData

@MainActor
public protocol AgentTaskRepositoryProtocol: AnyObject {
    @discardableResult
    func createTask(
        title: String,
        assignment: String,
        controllerAgentID: String?,
        assigneeAgentID: String?,
        contextInline: String?,
        contextFileName: String?,
        parentTaskID: String?,
        sessionID: String?,
        priority: Int
    ) throws -> AgentTask

    func fetchTask(id: String) throws -> AgentTask?
    func listTasks(status: String?) throws -> [AgentTask]
    /// All tasks including subtasks (for agent queue pull).
    func listAllTasks(status: String?) throws -> [AgentTask]
    func listSubtasks(parentTaskID: String?) throws -> [AgentTask]
    func updateTask(
        id: String,
        title: String?,
        assignment: String?,
        status: String?,
        assigneeAgentID: String?,
        handoffTarget: String?,
        contextInline: String?,
        contextFileName: String?,
        resultSummary: String?
    ) throws
    func deleteTask(id: String) throws
    func save() throws
}

@MainActor
public protocol AgentTaskEventRepositoryProtocol: AnyObject {
    @discardableResult
    func appendEvent(
        taskID: String,
        actorType: String,
        actorID: String?,
        action: String,
        message: String
    ) throws -> AgentTaskEvent

    func listEvents(taskID: String) throws -> [AgentTaskEvent]
    func deleteEvents(taskID: String) throws
    func save() throws
}

@MainActor
public protocol AgentArtifactRepositoryProtocol: AnyObject {
    @discardableResult
    func createArtifact(
        taskID: String,
        kind: String,
        title: String,
        body: String,
        linkedEntityID: String?
    ) throws -> AgentArtifact

    func listArtifacts(taskID: String) throws -> [AgentArtifact]
    func fetchArtifact(id: String) throws -> AgentArtifact?
    func updateArtifact(id: String, title: String?, body: String?) throws
    func deleteArtifact(id: String) throws
    func save() throws
}
