// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation

/// Launch/environment flags that install a canned inbox on ``WorkspaceConnectionManager``.
public enum FakeMailTesting {
    /// True when UI tests (or a debug launch) asked for the preview inbox.
    public static var isEnabled: Bool {
        let args = ProcessInfo.processInfo.arguments
        let env = ProcessInfo.processInfo.environment
        return args.contains("UITEST_FAKE_MAIL")
            || args.contains("-UITestFakeMail")
            || env["ANAIODYSSEY_FAKE_MAIL"] == "1"
    }
}

/// In-memory mail backend used by tests and the UI-test preview connection.
public final class InMemoryMailReaderService: MailReaderServiceProtocol {
    public private(set) var accessStatus: MailAccessStatus = .available

    private let mailboxes: [MailMailbox]
    private let messages: [MailMessageSummary]
    private let bodies: [Int64: String]

    public init(
        mailboxes: [MailMailbox],
        messages: [MailMessageSummary],
        bodies: [Int64: String] = [:]
    ) {
        self.mailboxes = mailboxes
        self.messages = messages
        self.bodies = bodies
    }

    public func refreshAccessStatus() {
        accessStatus = .available
    }

    public func listMailboxes() throws -> [MailMailbox] {
        mailboxes
    }

    public func listMessages(mailboxID: Int64?, limit: Int) throws -> [MailMessageSummary] {
        Array(messages.prefix(limit))
    }

    public func loadMessageDetail(messageRowID: Int64) throws -> MailMessageDetail {
        guard let summary = messages.first(where: { $0.id == messageRowID }) else {
            throw MailReaderError.messageNotFound(messageRowID)
        }
        return MailMessageDetail(
            summary: summary,
            bodyText: bodies[messageRowID] ?? summary.snippet,
            bodyHTML: nil,
            to: "you@example.com",
            cc: nil
        )
    }
}

/// Email adapter that serves ``FakeEmailProviderAdapter/sampleInbox`` through the
/// connection manager — the same path Google Auth uses after a real sign-in.
@MainActor
public final class FakeEmailProviderAdapter: EmailProviderAdapter {
    public static let connectionID = "preview:inbox"

    /// Stable subjects the Email tab and UI tests assert against.
    public static let sampleSubjects = [
        "Quarterly planning",
        "Lunch tomorrow",
        "Ship checklist",
    ]

    public let connectionID: String
    public let displayName: String
    public var isAvailable: Bool { true }

    private let reader: InMemoryMailReaderService

    public init(
        connectionID: String = FakeEmailProviderAdapter.connectionID,
        displayName: String = "Preview Gmail",
        reader: InMemoryMailReaderService
    ) {
        self.connectionID = connectionID
        self.displayName = displayName
        self.reader = reader
    }

    public func makeMailReader() -> any MailReaderServiceProtocol {
        reader
    }

    /// Three unread preview messages, newest first.
    public static func sampleInbox() -> FakeEmailProviderAdapter {
        let now = Date()
        let inbox = MailMailbox(
            id: 1,
            url: "preview://INBOX",
            totalCount: sampleSubjects.count,
            unreadCount: sampleSubjects.count,
            accountID: connectionID,
            accountLabel: "Preview Gmail",
            displayPath: ["Inbox"]
        )
        let messages: [MailMessageSummary] = [
            MailMessageSummary(
                id: 1,
                messageID: 1,
                subject: sampleSubjects[0],
                senderAddress: "ada@example.com",
                senderName: "Ada Lovelace",
                dateReceived: now.addingTimeInterval(-3600),
                snippet: "Agenda for Monday's planning hour.",
                isRead: false,
                isFlagged: false,
                mailboxURL: inbox.url,
                accountID: connectionID,
                accountLabel: "Preview Gmail"
            ),
            MailMessageSummary(
                id: 2,
                messageID: 2,
                subject: sampleSubjects[1],
                senderAddress: "alan@example.com",
                senderName: "Alan Turing",
                dateReceived: now.addingTimeInterval(-7200),
                snippet: "Does noon still work?",
                isRead: false,
                isFlagged: false,
                mailboxURL: inbox.url,
                accountID: connectionID,
                accountLabel: "Preview Gmail"
            ),
            MailMessageSummary(
                id: 3,
                messageID: 3,
                subject: sampleSubjects[2],
                senderAddress: "grace@example.com",
                senderName: "Grace Hopper",
                dateReceived: now.addingTimeInterval(-10800),
                snippet: "Three items left before we ship.",
                isRead: false,
                isFlagged: true,
                mailboxURL: inbox.url,
                accountID: connectionID,
                accountLabel: "Preview Gmail"
            ),
        ]
        let bodies: [Int64: String] = [
            1: "Agenda for Monday's planning hour.\n\n1. Goals\n2. Risks\n3. Owners",
            2: "Does noon still work? I can do the cafe on the corner.",
            3: "Three items left before we ship:\n- Release notes\n- QA sign-off\n- Tag the build",
        ]
        return FakeEmailProviderAdapter(
            reader: InMemoryMailReaderService(
                mailboxes: [inbox],
                messages: messages,
                bodies: bodies
            )
        )
    }
}
