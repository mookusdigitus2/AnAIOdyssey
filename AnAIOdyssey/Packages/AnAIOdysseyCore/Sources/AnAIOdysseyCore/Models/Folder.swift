// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import SwiftData

/// Which tree a `Folder` belongs to. Documents and Notes keep separate folder
/// hierarchies so they don't intermix in their respective sidebars.
public enum FolderKind: String, Codable, Sendable, CaseIterable {
    /// Folder in the Documents tree.
    case documents
    /// Folder in the Notes tree.
    case notes
}

/// A nestable folder for organizing Documents or Notes into a real
/// file-system-like tree.
///
/// Folders form a tree via `parentID` (nil = a root-level folder). `kind` keeps
/// the Documents and Notes hierarchies independent. Items (`Document`, `Note`)
/// reference their containing folder by `parentID`; tasks nest via their own
/// `parentTaskID` and do not use `Folder`.
@Model
public final class Folder {
    /// Stable identifier (UUID string), or a deterministic id for imports.
    public var id: String = ""
    /// Display name (no path; the path is derived by walking `parentID`).
    public var name: String = "Untitled Folder"
    /// Parent folder id, or `nil` for a root-level folder.
    public var parentID: String?
    /// Which tree this folder lives in, as a `FolderKind` raw value.
    public var kind: String = FolderKind.documents.rawValue
    /// Optional owning user.
    public var owner: String?
    /// Manual ordering hint among siblings.
    public var sortOrder: Int = 0

    /// Bookkeeping timestamps.
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()

    /// Creates a folder; `id` defaults to a fresh UUID. Imports may pass an
    /// explicit deterministic id to stay idempotent.
    public init(
        id: String = UUID().uuidString,
        name: String = "Untitled Folder",
        parentID: String? = nil,
        kind: FolderKind = .documents,
        owner: String? = nil,
        sortOrder: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.kind = kind.rawValue
        self.owner = owner
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// The `kind` as its typed enum (defaults to `.documents` if somehow invalid).
    public var folderKind: FolderKind {
        FolderKind(rawValue: kind) ?? .documents
    }
}
