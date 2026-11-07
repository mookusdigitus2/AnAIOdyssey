// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import SwiftData

@MainActor
public final class SwiftDataAgentArtifactRepository: AgentArtifactRepositoryProtocol {
    private let context: ModelContext

    public init(context: ModelContext) {
        self.context = context
    }

    @discardableResult
    public func createArtifact(
        taskID: String,
        kind: String,
        title: String,
        body: String,
        linkedEntityID: String?
    ) throws -> AgentArtifact {
        let artifact = AgentArtifact(
            taskID: taskID,
            kind: kind,
            title: title,
            body: body,
            linkedEntityID: linkedEntityID
        )
        context.insert(artifact)
        try save()
        return artifact
    }

    public func listArtifacts(taskID: String) throws -> [AgentArtifact] {
        let descriptor = FetchDescriptor<AgentArtifact>(
            predicate: #Predicate { $0.taskID == taskID },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return try context.fetch(descriptor)
    }

    public func fetchArtifact(id: String) throws -> AgentArtifact? {
        let descriptor = FetchDescriptor<AgentArtifact>(predicate: #Predicate { $0.id == id })
        return try context.fetch(descriptor).first
    }

    public func updateArtifact(id: String, title: String?, body: String?) throws {
        guard let artifact = try fetchArtifact(id: id) else {
            throw RepositoryError.notFound(id)
        }
        if let title { artifact.title = title }
        if let body { artifact.body = body }
        artifact.updatedAt = .now
        try save()
    }

    public func deleteArtifact(id: String) throws {
        guard let artifact = try fetchArtifact(id: id) else {
            throw RepositoryError.notFound(id)
        }
        context.delete(artifact)
        try save()
    }

    public func save() throws {
        try context.save()
    }
}
