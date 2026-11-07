// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import SwiftData

/// Unambiguous alias for the `Document` model.
///
/// Code that imports both SwiftUI and AnAIOdysseyCore can't use the bare name
/// `Document` (it collides with `SwiftUI.Document`, added in the 26+ SDKs), and it
/// can't qualify with `AnAIOdysseyCore.Document` either, because the module also
/// exposes an `enum AnAIOdysseyCore` that shadows the module name. This alias gives
/// such call sites a single, collision-free name to reference the model.
public typealias DocumentModel = Document

/// A user/AI-editable document with full version history.
///
/// `currentContent` holds the latest text for fast reads, while every save also
/// appends an immutable `DocumentVersion` (owned via a cascade relationship).
/// Documents can be opened as editor "tabs" (`isActive`) and can originate from
/// imported email (the `sourceEmail*` fields).
@Model
public final class Document {
    /// Stable identifier (UUID string), or a deterministic ID for imports.
    public var id: String = ""
    /// Optional chat session this document is associated with.
    public var sessionID: String?
    /// Owning folder id in the documents tree (`nil` = root). See `Folder`.
    public var parentID: String?
    /// Document title.
    public var title: String = "Untitled"
    /// Optional content language/format hint (e.g. "markdown").
    public var language: String?
    /// The latest content; the head of the version history.
    public var currentContent: String = ""
    /// Number of versions saved so far; also the next version's number.
    public var versionCount: Int = 0
    /// Whether the document is currently open as an editor tab.
    public var isActive: Bool = true
    /// Whether the document is archived (excluded from the active library).
    public var archived: Bool = false
    /// Optional owning user.
    public var owner: String?
    /// Optional result of an AI "tidy"/cleanup pass.
    public var tidyVerdict: String?

    /// Provenance for documents created from an imported email message
    /// (account/folder/UID/message-ID), enabling de-duplication on re-import.
    public var sourceEmailUID: String?
    public var sourceEmailFolder: String?
    public var sourceEmailAccountID: String?
    public var sourceEmailMessageID: String?

    /// Bookkeeping timestamps; `updatedAt` drives library sort order.
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()

    /// Full edit history. Cascade delete ensures versions are removed with the
    /// document; optional because SwiftData faults relationships lazily.
    @Relationship(deleteRule: .cascade, inverse: \DocumentVersion.document)
    public var versions: [DocumentVersion]? = []

    /// Creates a document; `id` defaults to a fresh UUID. Imports pass an
    /// explicit deterministic `id` to stay idempotent.
    public init(
        id: String = UUID().uuidString,
        sessionID: String? = nil,
        parentID: String? = nil,
        title: String = "Untitled",
        language: String? = nil,
        currentContent: String = "",
        versionCount: Int = 0,
        isActive: Bool = true,
        archived: Bool = false,
        owner: String? = nil,
        tidyVerdict: String? = nil,
        sourceEmailUID: String? = nil,
        sourceEmailFolder: String? = nil,
        sourceEmailAccountID: String? = nil,
        sourceEmailMessageID: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        versions: [DocumentVersion] = []
    ) {
        self.id = id
        self.sessionID = sessionID
        self.parentID = parentID
        self.title = title
        self.language = language
        self.currentContent = currentContent
        self.versionCount = versionCount
        self.isActive = isActive
        self.archived = archived
        self.owner = owner
        self.tidyVerdict = tidyVerdict
        self.sourceEmailUID = sourceEmailUID
        self.sourceEmailFolder = sourceEmailFolder
        self.sourceEmailAccountID = sourceEmailAccountID
        self.sourceEmailMessageID = sourceEmailMessageID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.versions = versions
    }

    /// Updates the current content and appends a matching immutable version
    /// snapshot, returning the new `DocumentVersion`.
    ///
    /// This is the single entry point for edits so that history and
    /// `currentContent`/`versionCount` never drift apart. `summary` and `source`
    /// annotate the snapshot (e.g. who/what made the change). Discardable because
    /// callers often only care about the side effect.
    @discardableResult
    public func saveContent(
        _ content: String,
        summary: String? = nil,
        source: String = "user"
    ) -> DocumentVersion {
        // Advance the head and bump the monotonic version counter.
        currentContent = content
        updatedAt = .now
        versionCount += 1

        // Append an immutable snapshot for the new content.
        let version = DocumentVersion(
            document: self,
            versionNumber: versionCount,
            content: content,
            summary: summary,
            source: source
        )
        // Lazily materialize the (possibly faulted) relationship before appending.
        if versions == nil { versions = [] }
        versions?.append(version)
        return version
    }
}
