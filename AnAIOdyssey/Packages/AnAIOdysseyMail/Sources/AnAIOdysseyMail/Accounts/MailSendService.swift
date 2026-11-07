// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation

public enum MailSendError: Error, LocalizedError {
    case notConfigured
    case unsupportedProvider(String)
    case missingAccount
    case missingOriginalMessage
    case missingRecipients
    case sendFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            "No mail account is configured for sending."
        case .unsupportedProvider(let name):
            "Sending is not supported for \(name). Connect a Gmail account."
        case .missingAccount:
            "Choose a Gmail account to send from."
        case .missingOriginalMessage:
            "The original message could not be found for this reply."
        case .missingRecipients:
            "Add at least one recipient before sending."
        case .sendFailed(let detail):
            detail
        }
    }
}

/// Outgoing message the user (or a draft) is ready to send.
public struct OutgoingEmail: Sendable {
    public let accountID: String
    public let to: String
    public let cc: String
    public let subject: String
    public let body: String
    public let mode: MailSendMode
    /// Gmail message id of the message being replied to or forwarded.
    public let originalGmailMessageID: String?

    public init(
        accountID: String,
        to: String,
        cc: String,
        subject: String,
        body: String,
        mode: MailSendMode,
        originalGmailMessageID: String? = nil
    ) {
        self.accountID = accountID
        self.to = to
        self.cc = cc
        self.subject = subject
        self.body = body
        self.mode = mode
        self.originalGmailMessageID = originalGmailMessageID
    }
}

/// Sends email through configured Gmail accounts (OAuth).
@MainActor
public final class MailSendService {
    private let accountStore: MailAccountStore
    private let session: URLSession

    public init(accountStore: MailAccountStore, session: URLSession = .shared) {
        self.accountStore = accountStore
        self.session = session
    }

    /// Builds default To/Cc/Subject/Body for a reply-style compose sheet.
    public func prepareCompose(
        mode: MailSendMode,
        accountID: String,
        originalGmailMessageID: String,
        body: String = ""
    ) async throws -> OutgoingEmail {
        let account = accountStore.accounts.first { $0.id == accountID }
        guard let account, account.provider == .gmail else {
            throw MailSendError.unsupportedProvider(account?.provider.displayName ?? "Unknown")
        }
        let oauth = accountStore.oauthService(for: account)
        let gmail = GmailAPIClient(oauth: oauth, session: session)
        let context = try await gmail.fetchComposeContext(id: originalGmailMessageID)
        let selfAddresses = await selfAddresses(for: account)
        let fields = GmailMIMEComposer.composeFields(
            mode: mode,
            userBody: body,
            context: context,
            selfAddresses: selfAddresses
        )
        return OutgoingEmail(
            accountID: accountID,
            to: fields.to,
            cc: fields.cc,
            subject: fields.subject,
            body: fields.body,
            mode: mode,
            originalGmailMessageID: originalGmailMessageID
        )
    }

    /// Sends the message through Gmail.
    public func send(_ email: OutgoingEmail) async throws {
        guard !email.to.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !email.cc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MailSendError.missingRecipients
        }
        guard let account = accountStore.accounts.first(where: { $0.id == email.accountID }) else {
            throw MailSendError.missingAccount
        }
        guard account.provider == .gmail else {
            throw MailSendError.unsupportedProvider(account.provider.displayName)
        }

        let oauth = accountStore.oauthService(for: account)
        let gmail = GmailAPIClient(oauth: oauth, session: session)

        var threadID: String?
        var inReplyTo: String?
        var references: String?

        if email.mode == .reply || email.mode == .replyAll {
            guard let originalID = email.originalGmailMessageID else {
                throw MailSendError.missingOriginalMessage
            }
            let context = try await gmail.fetchComposeContext(id: originalID)
            threadID = context.threadID
            inReplyTo = context.messageIDHeader
            references = context.messageIDHeader
        }

        let raw = GmailMIMEComposer.buildRFC822(
            to: email.to,
            cc: email.cc,
            subject: email.subject,
            body: email.body,
            inReplyTo: inReplyTo,
            references: references
        )
        _ = try await gmail.sendMessage(rawRFC822: raw, threadID: threadID)
    }

    private func selfAddresses(for account: MailAccount) async -> Set<String> {
        var set: Set<String> = [account.email.lowercased()]
        if let email = try? await accountStore.oauthService(for: account).currentAccountEmail() {
            set.insert(email.lowercased())
        }
        return set
    }
}
