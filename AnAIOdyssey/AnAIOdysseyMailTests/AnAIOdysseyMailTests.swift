// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import XCTest
@testable import AnAIOdysseyMail

final class AnAIOdysseyMailTests: XCTestCase {
    private var fixturesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Mail", isDirectory: true)
    }

    func testMailModuleLoads() {
        XCTAssertEqual(AnAIOdysseyMail.version, "1.0.0")
    }

    // MARK: - Gmail folder/label interpretation

    private func label(_ id: String, _ name: String, type: String) -> GmailLabel {
        GmailLabel(id: id, name: name, type: type, messagesTotal: 0, messagesUnread: 0)
    }

    func testGmailMappingHidesNonFolderSystemLabels() {
        for hidden in ["UNREAD", "IMPORTANT", "CHAT", "CATEGORY_PERSONAL", "CATEGORY_PROMOTIONS"] {
            XCTAssertNil(
                GmailFolderMapping.mapping(for: label(hidden, hidden, type: "system")),
                "\(hidden) should not be shown as a folder"
            )
        }
    }

    func testGmailMappingGivesSystemFoldersFriendlyNames() {
        let inbox = GmailFolderMapping.mapping(for: label("INBOX", "INBOX", type: "system"))
        XCTAssertEqual(inbox?.path, ["Inbox"])
        let drafts = GmailFolderMapping.mapping(for: label("DRAFT", "DRAFT", type: "system"))
        XCTAssertEqual(drafts?.path, ["Drafts"])
    }

    func testGmailMappingDerivesNestedUserLabelPath() {
        // User labels carry hierarchy in their NAME via "/", not the opaque id.
        let nested = GmailFolderMapping.mapping(for: label("Label_42", "Work/Projects/Alpha", type: "user"))
        XCTAssertEqual(nested?.path, ["Work", "Projects", "Alpha"])
    }

    func testGmailMappingOrdersSystemFoldersBeforeUserLabels() {
        let inbox = GmailFolderMapping.mapping(for: label("INBOX", "INBOX", type: "system"))!.sortKey
        let userLabel = GmailFolderMapping.mapping(for: label("Label_1", "Aardvark", type: "user"))!.sortKey
        XCTAssertTrue(inbox < userLabel, "System Inbox should sort before a user label")
    }

    #if os(macOS)
    func testMailSupportedOnMac() {
        XCTAssertTrue(AnAIOdysseyMail.isSupported)
    }

    func testEmlxParserExtractsBody() throws {
        let emlxURL = fixturesDirectory.appendingPathComponent("sample.emlx")
        let parsed = try EmlxParser.parse(fileURL: emlxURL)

        XCTAssertEqual(parsed.headers["Subject"], "Fixture Test Email")
        XCTAssertEqual(parsed.headers["From"], "sender@example.com")
        XCTAssertEqual(parsed.bodyText, "Hello from the fixture email body.")
        XCTAssertNil(parsed.bodyHTML)
    }

    func testEmlxParserExtractsMultipartHTML() throws {
        let emlxURL = fixturesDirectory.appendingPathComponent("2.emlx")
        let parsed = try EmlxParser.parse(fileURL: emlxURL)

        XCTAssertEqual(parsed.headers["Subject"], "Weekly Digest")
        XCTAssertEqual(parsed.bodyText, "Plain digest summary.")
        XCTAssertEqual(parsed.bodyHTML, "<html><body><p>HTML digest summary.</p></body></html>")
    }

    func testEnvelopeIndexReaderListsMessages() throws {
        let databaseURL = fixturesDirectory.appendingPathComponent("EnvelopeIndex.sqlite")
        let reader = try MailDatabaseReader(databaseURL: databaseURL)
        let messages = try reader.listMessages(limit: 10)

        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(Set(messages.map(\.subject)), Set(["Fixture Test Email", "Weekly Digest"]))
    }

    func testMailReaderGracefulNoAccess() {
        let service = MailReaderService()
        service.refreshAccessStatus()

        switch service.accessStatus {
        case .permissionDenied:
            XCTAssertThrowsError(try service.listMailboxes()) { error in
                XCTAssertEqual(error as? MailReaderError, .permissionDenied)
            }
        case .mailNotConfigured:
            XCTAssertThrowsError(try service.listMailboxes()) { error in
                XCTAssertEqual(error as? MailReaderError, .mailNotConfigured)
            }
        case .available:
            XCTAssertNoThrow(try service.listMailboxes())
        }
    }

    func testDetectMailVersionDirectory() {
        let versionDirectory = MailPathLocator.detectMailVersionDirectory()
        if let versionDirectory {
            XCTAssertTrue(versionDirectory.lastPathComponent.hasPrefix("V"))
            XCTAssertTrue(FileManager.default.fileExists(atPath: versionDirectory.path))
        }
    }

    func testFixtureMailReaderLoadsInbox() throws {
        let service = FixtureMailReaderService(fixturesDirectory: fixturesDirectory)
        let messages = try service.listMessages(mailboxID: nil, limit: 10)
        XCTAssertEqual(messages.count, 2)

        let detail = try service.loadMessageDetail(messageRowID: messages[0].id)
        XCTAssertFalse(detail.summary.subject.isEmpty)
        XCTAssertNotNil(detail.bodyText)
    }

    func testLoadMessageDetailFallsBackToSnippetWhenEmlxMissing() throws {
        let databaseURL = fixturesDirectory.appendingPathComponent("EnvelopeIndex.sqlite")
        let messages = try MailDatabaseReader(databaseURL: databaseURL).listMessages(limit: 1)
        let summary = try XCTUnwrap(messages.first)

        let emptyRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-emlx-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: emptyRoot) }

        let service = MailReaderService(
            envelopeIndexURL: databaseURL,
            emlxSearchRoot: emptyRoot
        )
        let detail = try service.loadMessageDetail(messageRowID: summary.id)

        XCTAssertEqual(detail.summary.id, summary.id)
        XCTAssertNotNil(detail.bodyText)
        XCTAssertNotNil(detail.loadNotice)
    }
    #else
    func testMailSupportedOnIOS() {
        XCTAssertTrue(AnAIOdysseyMail.isSupported)
    }
    #endif

    func testEmailCachePersistenceRoundTrip() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let snapshot = UnifiedMailCacheSnapshot(
            accountFingerprint: "apple|account-1",
            mailboxes: [
                MailMailbox(
                    id: 1,
                    url: "gmail://INBOX",
                    totalCount: 2,
                    unreadCount: 1,
                    accountID: "account-1",
                    accountLabel: "Work",
                    displayPath: ["Inbox"]
                ),
            ],
            messagesByMailbox: [
                "-1": [
                    MailMessageSummary(
                        id: 10,
                        messageID: 10,
                        subject: "Cached subject",
                        senderAddress: "sender@example.com",
                        senderName: "Sender",
                        dateReceived: Date(timeIntervalSince1970: 1_700_000_000),
                        snippet: "Preview",
                        isRead: false,
                        isFlagged: false,
                        mailboxURL: "gmail://INBOX",
                        accountID: "account-1",
                        accountLabel: "Work"
                    ),
                ],
            ],
            nextMailboxGlobalID: 2,
            nextMessageGlobalID: 11,
            mailboxKeyToGlobal: ["0|gmail://INBOX": 1],
            globalToMailbox: ["1": .init(childIndex: 0, childMailboxID: 1)],
            messageKeyToGlobal: ["0|5": 10],
            globalToMessage: ["10": .init(childIndex: 0, childMessageID: 5)]
        )

        EmailCachePersistence.save(snapshot, appSupportDirectory: tempDir)
        let loaded = EmailCachePersistence.load(appSupportDirectory: tempDir)
        XCTAssertEqual(loaded, snapshot)
    }
}
