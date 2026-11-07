// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation

/// On-disk format for a portable workspace backup (chats, documents, notes,
/// research, and related records). Email drafts and calendar events are never
/// included — they live in Mail / EventKit, not this archive.
public enum WorkspaceArchive {
    /// Current JSON schema version written by this build.
    public static let formatVersion = 1
    /// Manifest filename inside the zip.
    public static let manifestFileName = "manifest.json"
    /// Payload filename inside the zip.
    public static let payloadFileName = "payload.json"
    /// Folder of gallery image bytes, keyed by `GalleryImage.filename`.
    public static let galleryDirectoryName = "gallery"
    /// Folder of agent-task context files, keyed by `AgentTask.contextFileName`.
    public static let contextsDirectoryName = "contexts"
    /// Kinds this format deliberately omits.
    public static let excludedKinds = ["email", "calendar"]

    /// Suggested download name without an extension (the exporter adds `.zip`).
    public static func suggestedFileName(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "An-AI-Odyssey-Export-\(formatter.string(from: date))"
    }

    /// Archive header: version, timestamp, and an explicit exclusion list so
    /// importers of future formats know email/calendar were left out on purpose.
    public struct Manifest: Codable, Equatable, Sendable {
        public var formatVersion: Int
        public var exportedAt: Date
        public var appVersion: String
        public var excludedKinds: [String]

        public init(
            formatVersion: Int = WorkspaceArchive.formatVersion,
            exportedAt: Date = Date(),
            appVersion: String = AnAIOdysseyCore.version,
            excludedKinds: [String] = WorkspaceArchive.excludedKinds
        ) {
            self.formatVersion = formatVersion
            self.exportedAt = exportedAt
            self.appVersion = appVersion
            self.excludedKinds = excludedKinds
        }
    }

    /// All exportable records. Missing keys decode as empty arrays so older
    /// archives remain readable when new collections are added.
    public struct Payload: Codable, Equatable, Sendable {
        public var sessions: [Session]
        public var messages: [Message]
        public var folders: [FolderRecord]
        public var documents: [DocumentRecord]
        public var documentVersions: [DocumentVersionRecord]
        public var notes: [NoteRecord]
        public var memories: [MemoryRecord]
        public var albums: [AlbumRecord]
        public var images: [ImageRecord]
        public var comparisons: [ComparisonRecord]
        public var researchReports: [ResearchRecord]
        public var tasks: [TaskRecord]
        public var agentTasks: [AgentTaskRecord]
        public var agentTaskEvents: [AgentTaskEventRecord]
        public var agentArtifacts: [AgentArtifactRecord]

        public init(
            sessions: [Session] = [],
            messages: [Message] = [],
            folders: [FolderRecord] = [],
            documents: [DocumentRecord] = [],
            documentVersions: [DocumentVersionRecord] = [],
            notes: [NoteRecord] = [],
            memories: [MemoryRecord] = [],
            albums: [AlbumRecord] = [],
            images: [ImageRecord] = [],
            comparisons: [ComparisonRecord] = [],
            researchReports: [ResearchRecord] = [],
            tasks: [TaskRecord] = [],
            agentTasks: [AgentTaskRecord] = [],
            agentTaskEvents: [AgentTaskEventRecord] = [],
            agentArtifacts: [AgentArtifactRecord] = []
        ) {
            self.sessions = sessions
            self.messages = messages
            self.folders = folders
            self.documents = documents
            self.documentVersions = documentVersions
            self.notes = notes
            self.memories = memories
            self.albums = albums
            self.images = images
            self.comparisons = comparisons
            self.researchReports = researchReports
            self.tasks = tasks
            self.agentTasks = agentTasks
            self.agentTaskEvents = agentTaskEvents
            self.agentArtifacts = agentArtifacts
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            sessions = try container.decodeIfPresent([Session].self, forKey: .sessions) ?? []
            messages = try container.decodeIfPresent([Message].self, forKey: .messages) ?? []
            folders = try container.decodeIfPresent([FolderRecord].self, forKey: .folders) ?? []
            documents = try container.decodeIfPresent([DocumentRecord].self, forKey: .documents) ?? []
            documentVersions = try container.decodeIfPresent([DocumentVersionRecord].self, forKey: .documentVersions) ?? []
            notes = try container.decodeIfPresent([NoteRecord].self, forKey: .notes) ?? []
            memories = try container.decodeIfPresent([MemoryRecord].self, forKey: .memories) ?? []
            albums = try container.decodeIfPresent([AlbumRecord].self, forKey: .albums) ?? []
            images = try container.decodeIfPresent([ImageRecord].self, forKey: .images) ?? []
            comparisons = try container.decodeIfPresent([ComparisonRecord].self, forKey: .comparisons) ?? []
            researchReports = try container.decodeIfPresent([ResearchRecord].self, forKey: .researchReports) ?? []
            tasks = try container.decodeIfPresent([TaskRecord].self, forKey: .tasks) ?? []
            agentTasks = try container.decodeIfPresent([AgentTaskRecord].self, forKey: .agentTasks) ?? []
            agentTaskEvents = try container.decodeIfPresent([AgentTaskEventRecord].self, forKey: .agentTaskEvents) ?? []
            agentArtifacts = try container.decodeIfPresent([AgentArtifactRecord].self, forKey: .agentArtifacts) ?? []
        }
    }

    public struct Session: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var endpointURL: String
        public var model: String
        public var owner: String?
        public var rag: Bool
        public var archived: Bool
        public var folder: String?
        public var headersJSON: String
        public var createdAt: Date
        public var updatedAt: Date
        public var lastAccessed: Date
        public var lastMessageAt: Date?
        public var isImportant: Bool
        public var messageCount: Int
        public var totalInputTokens: Int
        public var totalOutputTokens: Int
        public var mode: String?
        public var crewMemberID: String?
    }

    public struct Message: Codable, Equatable, Sendable {
        public var id: String
        public var sessionID: String
        public var role: String
        public var content: String
        public var metadata: String?
        public var timestamp: Date
    }

    public struct FolderRecord: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var parentID: String?
        public var kind: String
        public var owner: String?
        public var sortOrder: Int
        public var createdAt: Date
        public var updatedAt: Date
    }

    public struct DocumentRecord: Codable, Equatable, Sendable {
        public var id: String
        public var sessionID: String?
        public var parentID: String?
        public var title: String
        public var language: String?
        public var currentContent: String
        public var versionCount: Int
        public var isActive: Bool
        public var archived: Bool
        public var owner: String?
        public var tidyVerdict: String?
        public var sourceEmailUID: String?
        public var sourceEmailFolder: String?
        public var sourceEmailAccountID: String?
        public var sourceEmailMessageID: String?
        public var createdAt: Date
        public var updatedAt: Date
    }

    public struct DocumentVersionRecord: Codable, Equatable, Sendable {
        public var id: String
        public var documentID: String
        public var versionNumber: Int
        public var content: String
        public var summary: String?
        public var source: String
        public var createdAt: Date
    }

    public struct NoteRecord: Codable, Equatable, Sendable {
        public var id: String
        public var owner: String?
        public var parentID: String?
        public var title: String
        public var content: String?
        public var checklistItems: [ChecklistItem]
        public var noteType: String
        public var color: String?
        public var label: String?
        public var pinned: Bool
        public var archived: Bool
        public var dueDate: String?
        public var source: String
        public var sessionID: String?
        public var sortOrder: Int
        public var imageURL: String?
        public var repeatRule: String
        public var aiClassification: String?
        public var aiContentHash: String?
        public var agentSessionID: String?
        public var createdAt: Date
        public var updatedAt: Date
    }

    public struct MemoryRecord: Codable, Equatable, Sendable {
        public var id: String
        public var text: String
        public var sessionID: String?
        public var createdAt: Date
    }

    public struct AlbumRecord: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var albumDescription: String?
        public var coverImageID: String?
    }

    public struct ImageRecord: Codable, Equatable, Sendable {
        public var id: String
        public var albumID: String
        public var filename: String
        public var caption: String?
        public var createdAt: Date
    }

    public struct ComparisonRecord: Codable, Equatable, Sendable {
        public var id: String
        public var prompt: String
        public var modelA: String
        public var modelB: String
        public var responseA: String?
        public var responseB: String?
        public var winner: String?
        public var isBlind: Bool
        public var blindMappingJSON: String?
        public var votedAt: Date?
    }

    public struct ResearchRecord: Codable, Equatable, Sendable {
        public var id: String
        public var query: String
        public var summary: String
        public var sourcesJSON: String
        public var threadJSON: String
        public var createdAt: Date
    }

    public struct TaskRecord: Codable, Equatable, Sendable {
        public var id: String
        public var owner: String?
        public var parentTaskID: String?
        public var sortOrder: Int
        public var name: String
        public var prompt: String?
        public var taskType: String
        public var action: String?
        public var schedule: String?
        public var scheduledTime: String?
        public var scheduledDay: Int?
        public var scheduledDate: Date?
        public var triggerType: String
        public var triggerEvent: String?
        public var nextRun: Date?
        public var lastRun: Date?
        public var status: String
        public var outputTarget: String
        public var sessionID: String?
        public var model: String?
        public var endpointURL: String?
        public var runCount: Int
        public var cronExpression: String?
        public var notificationsEnabled: Bool
        public var createdAt: Date
        public var updatedAt: Date
    }

    public struct AgentTaskRecord: Codable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var assignment: String
        public var status: String
        public var assigneeAgentID: String?
        public var controllerAgentID: String?
        public var handoffTarget: String?
        public var contextInline: String?
        public var contextFileName: String?
        public var parentTaskID: String?
        public var sessionID: String?
        public var priority: Int
        public var resultSummary: String?
        public var currentAction: String?
        public var changeLogJSON: String
        public var conversationJSON: String?
        public var errorMessage: String?
        public var createdAt: Date
        public var updatedAt: Date

        public init(
            id: String,
            title: String,
            assignment: String,
            status: String,
            assigneeAgentID: String? = nil,
            controllerAgentID: String? = nil,
            handoffTarget: String? = nil,
            contextInline: String? = nil,
            contextFileName: String? = nil,
            parentTaskID: String? = nil,
            sessionID: String? = nil,
            priority: Int = 0,
            resultSummary: String? = nil,
            currentAction: String? = nil,
            changeLogJSON: String = "[]",
            conversationJSON: String? = nil,
            errorMessage: String? = nil,
            createdAt: Date,
            updatedAt: Date
        ) {
            self.id = id
            self.title = title
            self.assignment = assignment
            self.status = status
            self.assigneeAgentID = assigneeAgentID
            self.controllerAgentID = controllerAgentID
            self.handoffTarget = handoffTarget
            self.contextInline = contextInline
            self.contextFileName = contextFileName
            self.parentTaskID = parentTaskID
            self.sessionID = sessionID
            self.priority = priority
            self.resultSummary = resultSummary
            self.currentAction = currentAction
            self.changeLogJSON = changeLogJSON
            self.conversationJSON = conversationJSON
            self.errorMessage = errorMessage
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            title = try container.decode(String.self, forKey: .title)
            assignment = try container.decode(String.self, forKey: .assignment)
            status = try container.decode(String.self, forKey: .status)
            assigneeAgentID = try container.decodeIfPresent(String.self, forKey: .assigneeAgentID)
            controllerAgentID = try container.decodeIfPresent(String.self, forKey: .controllerAgentID)
            handoffTarget = try container.decodeIfPresent(String.self, forKey: .handoffTarget)
            contextInline = try container.decodeIfPresent(String.self, forKey: .contextInline)
            contextFileName = try container.decodeIfPresent(String.self, forKey: .contextFileName)
            parentTaskID = try container.decodeIfPresent(String.self, forKey: .parentTaskID)
            sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
            priority = try container.decodeIfPresent(Int.self, forKey: .priority) ?? 0
            resultSummary = try container.decodeIfPresent(String.self, forKey: .resultSummary)
            currentAction = try container.decodeIfPresent(String.self, forKey: .currentAction)
            changeLogJSON = try container.decodeIfPresent(String.self, forKey: .changeLogJSON) ?? "[]"
            conversationJSON = try container.decodeIfPresent(String.self, forKey: .conversationJSON)
            errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
            createdAt = try container.decode(Date.self, forKey: .createdAt)
            updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        }
    }

    public struct AgentTaskEventRecord: Codable, Equatable, Sendable {
        public var id: String
        public var taskID: String
        public var actorType: String
        public var actorID: String?
        public var action: String
        public var message: String
        public var createdAt: Date
    }

    public struct AgentArtifactRecord: Codable, Equatable, Sendable {
        public var id: String
        public var taskID: String
        public var kind: String
        public var title: String
        public var body: String
        public var linkedEntityID: String?
        public var createdAt: Date
        public var updatedAt: Date
    }
}

/// Tally of records newly imported vs. skipped (already present) per entity.
public struct WorkspaceArchiveCounts: Sendable, Equatable {
    public var sessionsImported = 0
    public var sessionsSkipped = 0
    public var messagesImported = 0
    public var messagesSkipped = 0
    public var foldersImported = 0
    public var foldersSkipped = 0
    public var documentsImported = 0
    public var documentsSkipped = 0
    public var documentVersionsImported = 0
    public var documentVersionsSkipped = 0
    public var notesImported = 0
    public var notesSkipped = 0
    public var memoriesImported = 0
    public var memoriesSkipped = 0
    public var albumsImported = 0
    public var albumsSkipped = 0
    public var imagesImported = 0
    public var imagesSkipped = 0
    public var comparisonsImported = 0
    public var comparisonsSkipped = 0
    public var researchReportsImported = 0
    public var researchReportsSkipped = 0
    public var tasksImported = 0
    public var tasksSkipped = 0
    public var agentTasksImported = 0
    public var agentTasksSkipped = 0
    public var agentTaskEventsImported = 0
    public var agentTaskEventsSkipped = 0
    public var agentArtifactsImported = 0
    public var agentArtifactsSkipped = 0
    /// True when the importer wiped archive-covered content before inserting.
    public var replacedExisting = false
    /// How many SwiftData records were deleted during a replace import.
    public var replacedRecordCount = 0

    public var totalImported: Int {
        sessionsImported + messagesImported + foldersImported + documentsImported
            + documentVersionsImported + notesImported + memoriesImported
            + albumsImported + imagesImported + comparisonsImported
            + researchReportsImported + tasksImported + agentTasksImported
            + agentTaskEventsImported + agentArtifactsImported
    }

    public var totalSkipped: Int {
        sessionsSkipped + messagesSkipped + foldersSkipped + documentsSkipped
            + documentVersionsSkipped + notesSkipped + memoriesSkipped
            + albumsSkipped + imagesSkipped + comparisonsSkipped
            + researchReportsSkipped + tasksSkipped + agentTasksSkipped
            + agentTaskEventsSkipped + agentArtifactsSkipped
    }

    public var summary: String {
        let replacement: String
        if replacedExisting {
            replacement = "Replaced existing workspace content (\(replacedRecordCount) records removed). "
        } else {
            replacement = ""
        }
        return """
        \(replacement)Imported \(totalImported) records (\(totalSkipped) skipped). \
        Email drafts and calendar events are not part of this archive.
        Chats: \(sessionsImported)/\(sessionsSkipped), Messages: \(messagesImported)/\(messagesSkipped), \
        Folders: \(foldersImported)/\(foldersSkipped), Documents: \(documentsImported)/\(documentsSkipped), \
        Notes: \(notesImported)/\(notesSkipped), Memories: \(memoriesImported)/\(memoriesSkipped), \
        Research: \(researchReportsImported)/\(researchReportsSkipped), Tasks: \(tasksImported)/\(tasksSkipped).
        """
    }
}

/// Tally of records written into an export archive.
public struct WorkspaceExportSummary: Sendable, Equatable {
    public var sessionCount = 0
    public var messageCount = 0
    public var folderCount = 0
    public var documentCount = 0
    public var documentVersionCount = 0
    public var noteCount = 0
    public var memoryCount = 0
    public var albumCount = 0
    public var imageCount = 0
    public var comparisonCount = 0
    public var researchReportCount = 0
    public var taskCount = 0
    public var agentTaskCount = 0
    public var agentTaskEventCount = 0
    public var agentArtifactCount = 0
    public var galleryFileCount = 0
    public var contextFileCount = 0

    public var totalRecords: Int {
        sessionCount + messageCount + folderCount + documentCount
            + documentVersionCount + noteCount + memoryCount + albumCount
            + imageCount + comparisonCount + researchReportCount + taskCount
            + agentTaskCount + agentTaskEventCount + agentArtifactCount
    }

    public var summary: String {
        """
        Exported \(totalRecords) records \
        (\(sessionCount) chats, \(documentCount) documents, \(noteCount) notes, \
        \(researchReportCount) research reports, \(memoryCount) memories). \
        Email and calendar were omitted.
        """
    }
}

/// Errors thrown while exporting or importing a workspace archive.
public enum WorkspaceArchiveError: Error, LocalizedError {
    case invalidArchive
    case unsupportedVersion(Int)
    case writeFailed(String)
    case readFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidArchive:
            "The selected file is not a valid \(AppBranding.appName) workspace export."
        case .unsupportedVersion(let version):
            "This export uses format version \(version), which this app cannot read."
        case .writeFailed(let message):
            "Could not write the export: \(message)"
        case .readFailed(let message):
            "Could not read the export: \(message)"
        }
    }
}
