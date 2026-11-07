// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import SwiftData

/// SwiftData-backed implementation of `ResearchReportRepositoryProtocol`.
@MainActor
public final class SwiftDataResearchReportRepository: ResearchReportRepositoryProtocol {
    /// The shared SwiftData context all operations run against.
    private let context: ModelContext

    /// Binds the repository to a `ModelContext`.
    public init(context: ModelContext) {
        self.context = context
    }

    @discardableResult
    public func createReport(
        query: String,
        summary: String,
        sourcesJSON: String,
        threadJSON: String = "[]"
    ) throws -> ResearchReport {
        let report = ResearchReport(
            query: query,
            summary: summary,
            sourcesJSON: sourcesJSON,
            threadJSON: threadJSON
        )
        context.insert(report)
        try save()
        return report
    }

    public func fetchReport(id: String) throws -> ResearchReport? {
        let descriptor = FetchDescriptor<ResearchReport>(
            predicate: #Predicate { $0.id == id }
        )
        return try context.fetch(descriptor).first
    }

    public func listReports() throws -> [ResearchReport] {
        let descriptor = FetchDescriptor<ResearchReport>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return try context.fetch(descriptor)
    }

    public func updateReport(
        id: String,
        summary: String,
        threadJSON: String,
        sourcesJSON: String? = nil
    ) throws {
        guard let report = try fetchReport(id: id) else {
            throw RepositoryError.notFound(id)
        }
        // Summary and thread are always replaced; sources only when provided.
        report.summary = summary
        report.threadJSON = threadJSON
        if let sourcesJSON {
            report.sourcesJSON = sourcesJSON
        }
        try save()
    }

    public func deleteReport(id: String) throws {
        guard let report = try fetchReport(id: id) else {
            throw RepositoryError.notFound(id)
        }
        context.delete(report)
        try save()
    }

    public func save() throws {
        try context.save()
    }
}
