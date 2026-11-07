// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import SwiftData

/// An immutable snapshot of a `Document`'s content at a point in time.
///
/// Versions form the document's edit history: `Document.saveContent` appends a
/// new one on every save. They are owned by the parent document via a cascade
/// relationship, so deleting the document removes its versions too.
@Model
public final class DocumentVersion {
    /// Stable identifier (UUID string).
    public var id: String = ""
    /// Denormalized parent document ID, kept alongside the `document`
    /// relationship for predicate-based fetches and import matching.
    public var documentID: String = ""
    /// Monotonic version index within the document (1-based).
    public var versionNumber: Int = 0
    /// The snapshotted document body.
    public var content: String = ""
    /// Optional short description of what changed in this version.
    public var summary: String?
    /// Who produced this version ("ai", "user", "import", ...).
    public var source: String = "ai"
    /// When the snapshot was taken.
    public var createdAt: Date = Date()

    /// Inverse side of the cascade relationship to the owning `Document`.
    public var document: Document?

    /// Creates a version bound to `document`, copying its ID into `documentID`
    /// so the snapshot can be matched even if the relationship is faulted out.
    public init(
        id: String = UUID().uuidString,
        document: Document,
        versionNumber: Int,
        content: String,
        summary: String? = nil,
        source: String = "ai",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.document = document
        self.documentID = document.id
        self.versionNumber = versionNumber
        self.content = content
        self.summary = summary
        self.source = source
        self.createdAt = createdAt
    }
}
