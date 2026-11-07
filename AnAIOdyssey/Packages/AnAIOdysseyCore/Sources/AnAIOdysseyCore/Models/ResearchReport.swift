// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import SwiftData

/// A saved deep-research run: the original question plus the synthesized answer
/// and its supporting material.
///
/// Sources and the follow-up conversation thread are stored as JSON strings
/// rather than dedicated models so the shape can evolve without schema
/// migrations and so the whole report stays a single CloudKit-friendly record.
@Model
public final class ResearchReport {
    /// Stable identifier (UUID string).
    public var id: String = ""
    /// The research question that produced this report.
    public var query: String = ""
    /// The synthesized summary/answer.
    public var summary: String = ""
    /// JSON-encoded array of cited sources (URLs/snippets/metadata).
    public var sourcesJSON: String = "[]"
    /// JSON-encoded array of follow-up Q&A turns layered on top of the summary.
    public var threadJSON: String = "[]"
    /// Creation timestamp, used to list reports newest-first.
    public var createdAt: Date = Date()

    /// Creates a research report; `id` defaults to a fresh UUID.
    public init(
        id: String = UUID().uuidString,
        query: String,
        summary: String,
        sourcesJSON: String = "[]",
        threadJSON: String = "[]",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.query = query
        self.summary = summary
        self.sourcesJSON = sourcesJSON
        self.threadJSON = threadJSON
        self.createdAt = createdAt
    }
}
