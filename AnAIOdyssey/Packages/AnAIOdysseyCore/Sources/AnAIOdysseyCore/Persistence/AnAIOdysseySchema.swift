// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import SwiftData

/// Single source of truth for the set of SwiftData models AnAIOdyssey persists.
///
/// Every `ModelContainer` (local, CloudKit, and in-memory test containers) is
/// built from this one schema so all stores stay structurally identical. Add new
/// `@Model` types to `models` to include them in persistence and CloudKit
/// mirroring.
public enum AnAIOdysseySchema {
    /// The complete list of persisted model types.
    public static let models: [any PersistentModel.Type] = [
        ChatSession.self,
        ChatMessage.self,
        Document.self,
        DocumentVersion.self,
        Folder.self,
        Note.self,
        Memory.self,
        Album.self,
        GalleryImage.self,
        Comparison.self,
        ResearchReport.self,
        ScheduledTask.self,
        CalendarEventRecord.self,
        EmailDraft.self,
        AgentTask.self,
        AgentTaskEvent.self,
        AgentArtifact.self,
    ]

    /// The `Schema` value built from `models`, passed to every container.
    public static var schema: Schema {
        Schema(models)
    }
}
