// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import SwiftData
import SwiftUI

/// Live repository instances backed by a shared `ModelContext`.
///
/// One aggregate "service locator" for every repository, so views and services
/// can be handed a single value instead of wiring up nine dependencies. Because
/// all repositories share the same `ModelContext`, their changes participate in
/// the same unit of work.
@MainActor
public struct RepositoryBundle {
    /// The individual domain repositories, one per model area.
    public let sessions: any SessionRepositoryProtocol
    public let documents: any DocumentRepositoryProtocol
    public let folders: any FolderRepositoryProtocol
    public let notes: any NoteRepositoryProtocol
    public let memories: any MemoryRepositoryProtocol
    public let gallery: any GalleryRepositoryProtocol
    public let comparisons: any ComparisonRepositoryProtocol
    public let researchReports: any ResearchReportRepositoryProtocol
    public let tasks: any TaskRepositoryProtocol
    public let calendarEvents: any CalendarEventRepositoryProtocol
    public let emailDrafts: any EmailDraftRepositoryProtocol
    public let agentTasks: any AgentTaskRepositoryProtocol
    public let agentTaskEvents: any AgentTaskEventRepositoryProtocol
    public let agentArtifacts: any AgentArtifactRepositoryProtocol

    /// Designated initializer; lets tests inject mock repositories.
    public init(
        sessions: any SessionRepositoryProtocol,
        documents: any DocumentRepositoryProtocol,
        folders: any FolderRepositoryProtocol,
        notes: any NoteRepositoryProtocol,
        memories: any MemoryRepositoryProtocol,
        gallery: any GalleryRepositoryProtocol,
        comparisons: any ComparisonRepositoryProtocol,
        researchReports: any ResearchReportRepositoryProtocol,
        tasks: any TaskRepositoryProtocol,
        calendarEvents: any CalendarEventRepositoryProtocol,
        emailDrafts: any EmailDraftRepositoryProtocol,
        agentTasks: any AgentTaskRepositoryProtocol,
        agentTaskEvents: any AgentTaskEventRepositoryProtocol,
        agentArtifacts: any AgentArtifactRepositoryProtocol
    ) {
        self.sessions = sessions
        self.documents = documents
        self.folders = folders
        self.notes = notes
        self.memories = memories
        self.gallery = gallery
        self.comparisons = comparisons
        self.researchReports = researchReports
        self.tasks = tasks
        self.calendarEvents = calendarEvents
        self.emailDrafts = emailDrafts
        self.agentTasks = agentTasks
        self.agentTaskEvents = agentTaskEvents
        self.agentArtifacts = agentArtifacts
    }

    /// Builds the production bundle wiring every SwiftData-backed repository to
    /// the same `context`. `galleryDirectory` overrides where image files are
    /// stored (defaults to the app-support gallery folder).
    public static func live(context: ModelContext, galleryDirectory: URL? = nil) -> RepositoryBundle {
        RepositoryBundle(
            sessions: SwiftDataSessionRepository(context: context),
            documents: SwiftDataDocumentRepository(context: context),
            folders: SwiftDataFolderRepository(context: context),
            notes: SwiftDataNoteRepository(context: context),
            memories: SwiftDataMemoryRepository(context: context),
            gallery: SwiftDataGalleryRepository(context: context, galleryDirectory: galleryDirectory),
            comparisons: SwiftDataComparisonRepository(context: context),
            researchReports: SwiftDataResearchReportRepository(context: context),
            tasks: SwiftDataTaskRepository(context: context),
            calendarEvents: SwiftDataCalendarEventRepository(context: context),
            emailDrafts: SwiftDataEmailDraftRepository(context: context),
            agentTasks: SwiftDataAgentTaskRepository(context: context),
            agentTaskEvents: SwiftDataAgentTaskEventRepository(context: context),
            agentArtifacts: SwiftDataAgentArtifactRepository(context: context)
        )
    }
}

/// Environment key backing the optional `repositories` value.
private struct RepositoryBundleKey: EnvironmentKey {
    static let defaultValue: RepositoryBundle? = nil
}

/// SwiftUI environment access to the shared `RepositoryBundle`, so any view can
/// reach the data layer without manual dependency threading.
public extension EnvironmentValues {
    var repositories: RepositoryBundle? {
        get { self[RepositoryBundleKey.self] }
        set { self[RepositoryBundleKey.self] = newValue }
    }
}

/// Test conveniences for spinning up an in-memory store plus repositories.
public extension TestModelContainer {
    /// A standalone `ModelContext` over a fresh in-memory container.
    static func makeContext() throws -> ModelContext {
        ModelContext(try make())
    }

    /// A fresh in-memory context paired with a live `RepositoryBundle` over it —
    /// the typical starting point for repository tests.
    static func makeRepositories() throws -> (ModelContext, RepositoryBundle) {
        let container = try make()
        let context = ModelContext(container)
        return (context, RepositoryBundle.live(context: context))
    }
}
