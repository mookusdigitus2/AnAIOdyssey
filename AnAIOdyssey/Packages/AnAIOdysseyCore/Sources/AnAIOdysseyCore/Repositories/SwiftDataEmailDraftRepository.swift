// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import SwiftData

/// SwiftData-backed implementation of `EmailDraftRepositoryProtocol`.
@MainActor
public final class SwiftDataEmailDraftRepository: EmailDraftRepositoryProtocol {
    /// The shared SwiftData context all operations run against.
    private let context: ModelContext

    /// Binds the repository to a `ModelContext`.
    public init(context: ModelContext) {
        self.context = context
    }

    @discardableResult
    public func createDraft(
        mode: String,
        toRecipients: String,
        ccRecipients: String,
        subject: String,
        body: String,
        originalMessageID: String?,
        originalSubject: String?,
        accountID: String?,
        source: String,
        sessionID: String?
    ) throws -> EmailDraft {
        let draft = EmailDraft(
            mode: mode,
            toRecipients: toRecipients,
            ccRecipients: ccRecipients,
            subject: subject,
            body: body,
            originalMessageID: originalMessageID,
            originalSubject: originalSubject,
            accountID: accountID,
            source: source,
            sessionID: sessionID
        )
        context.insert(draft)
        try save()
        return draft
    }

    public func fetchDraft(id: String) throws -> EmailDraft? {
        let descriptor = FetchDescriptor<EmailDraft>(
            predicate: #Predicate { $0.id == id }
        )
        return try context.fetch(descriptor).first
    }

    public func listDrafts() throws -> [EmailDraft] {
        let descriptor = FetchDescriptor<EmailDraft>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return try context.fetch(descriptor)
    }

    public func updateDraft(
        id: String,
        toRecipients: String?,
        ccRecipients: String?,
        subject: String?,
        body: String?
    ) throws {
        guard let draft = try fetchDraft(id: id) else {
            throw RepositoryError.notFound(id)
        }
        if let toRecipients { draft.toRecipients = toRecipients }
        if let ccRecipients { draft.ccRecipients = ccRecipients }
        if let subject { draft.subject = subject }
        if let body { draft.body = body }
        draft.updatedAt = .now
        try save()
    }

    public func deleteDraft(id: String) throws {
        guard let draft = try fetchDraft(id: id) else {
            throw RepositoryError.notFound(id)
        }
        context.delete(draft)
        try save()
    }

    public func save() throws {
        try context.save()
    }
}
