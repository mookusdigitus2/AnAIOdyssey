// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation

/// Backend-agnostic contract for reading mail: mailboxes, message lists, and details.
///
/// Concrete conformers include the macOS Apple Mail reader, a Gmail-backed reader, a
/// fixture reader for tests, and an iOS stub. `accessStatus` lets the UI reflect
/// whether mail is currently readable, needs permission, or isn't configured.
public protocol MailReaderServiceProtocol: AnyObject {
    var accessStatus: MailAccessStatus { get }
    /// Re-evaluates whether the backing store is reachable and updates `accessStatus`.
    func refreshAccessStatus()
    /// Returns the available mailboxes/folders.
    func listMailboxes() throws -> [MailMailbox]
    /// Returns message summaries, optionally scoped to one mailbox and capped by `limit`.
    func listMessages(mailboxID: Int64?, limit: Int) throws -> [MailMessageSummary]
    /// Loads the full detail (body, recipients) for a single message row.
    func loadMessageDetail(messageRowID: Int64) throws -> MailMessageDetail
}

#if os(macOS)

/// Reads the local Apple Mail store on macOS (Envelope Index DB + `.emlx` bodies).
///
/// macOS-only: depends on the Apple Mail data layout and Full Disk Access. The
/// service tracks an `accessStatus` (available / permission denied / not configured)
/// and lazily opens a read-only `MailDatabaseReader` per query rather than holding an
/// open handle, so it stays robust if Mail rewrites its database underneath us.
public final class MailReaderService: MailReaderServiceProtocol {
    private let fileManager: FileManager
    private let homeDirectory: URL
    private var databaseURL: URL?
    private var emlxSearchRoot: URL?

    public private(set) var accessStatus: MailAccessStatus = .mailNotConfigured

    /// Creates a reader that auto-detects the Mail store under the given home directory.
    public init(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
        refreshAccessStatus()
    }

    /// Creates a reader pointed at explicit paths (used for tests/fixtures).
    ///
    /// Skips auto-detection and instead reports `.available` or `.permissionDenied`
    /// based on whether the supplied Envelope Index is readable.
    public convenience init(
        envelopeIndexURL: URL,
        emlxSearchRoot: URL,
        fileManager: FileManager = .default
    ) {
        self.init(fileManager: fileManager)
        self.databaseURL = envelopeIndexURL
        self.emlxSearchRoot = emlxSearchRoot
        self.accessStatus = fileManager.isReadableFile(atPath: envelopeIndexURL.path) ? .available : .permissionDenied
    }

    /// Detects the Mail database and probes whether it can actually be opened.
    ///
    /// Distinguishes "Mail not configured" (no Envelope Index found) from
    /// "permission denied" (file exists but Full Disk Access is missing) by attempting
    /// a throwaway open and inspecting the resulting error.
    public func refreshAccessStatus() {
        // No Envelope Index on disk: Mail isn't set up. Still record the version
        // directory (if any) so .emlx lookups could work in degraded scenarios.
        guard let envelopeURL = MailPathLocator.envelopeIndexURL(
            fileManager: fileManager,
            homeDirectory: homeDirectory
        ) else {
            accessStatus = .mailNotConfigured
            databaseURL = nil
            emlxSearchRoot = MailPathLocator.detectMailVersionDirectory(
                fileManager: fileManager,
                homeDirectory: homeDirectory
            )
            return
        }

        // Cache the DB path and derive the version directory (two levels up from
        // V<n>/MailData/Envelope Index) as the root for .emlx body searches.
        databaseURL = envelopeURL
        emlxSearchRoot = envelopeURL.deletingLastPathComponent().deletingLastPathComponent()

        // Probe access by trying to open the DB; the resulting error tells us whether
        // we lack Full Disk Access or Mail simply isn't usable.
        do {
            _ = try MailDatabaseReader(databaseURL: envelopeURL)
            accessStatus = .available
        } catch MailReaderError.permissionDenied {
            accessStatus = .permissionDenied
        } catch {
            accessStatus = .mailNotConfigured
        }
    }

    /// Lists mailboxes via a freshly opened reader. Throws if access isn't available.
    public func listMailboxes() throws -> [MailMailbox] {
        try requireReader().listMailboxes()
    }

    /// Lists message summaries via a freshly opened reader. Throws if access isn't available.
    public func listMessages(mailboxID: Int64?, limit: Int) throws -> [MailMessageSummary] {
        try requireReader().listMessages(mailboxID: mailboxID, limit: limit)
    }

    /// Loads a message's full detail, falling back to the indexed snippet when the
    /// `.emlx` body can't be located or parsed.
    ///
    /// First reads the metadata summary from the database, then tries to enrich it with
    /// the on-disk MIME body. If the body is unavailable it returns the snippet with a
    /// user-facing `loadNotice` instead of failing.
    public func loadMessageDetail(messageRowID: Int64) throws -> MailMessageDetail {
        let reader = try requireReader()
        // The summary (metadata) must exist; otherwise the row id is bogus.
        guard let summary = try reader.messageSummary(id: messageRowID) else {
            throw MailReaderError.messageNotFound(messageRowID)
        }

        // Best effort: find and parse the full MIME body from the matching .emlx file.
        if let emlxURL = try? locateEmlxURL(for: summary.messageID),
           let parsed = try? EmlxParser.parse(fileURL: emlxURL) {
            return MailMessageDetail(
                summary: summary,
                bodyText: parsed.bodyText ?? summary.snippet,
                bodyHTML: parsed.bodyHTML,
                to: parsed.headers["To"],
                cc: parsed.headers["Cc"]
            )
        }

        // Body unavailable: degrade gracefully to the indexed preview with a notice.
        return MailMessageDetail(
            summary: summary,
            bodyText: summary.snippet,
            bodyHTML: nil,
            to: nil,
            cc: nil,
            loadNotice: "Full message body is not available locally. Showing the preview stored in Mail’s index."
        )
    }

    /// Validates current access and returns a fresh read-only database reader.
    ///
    /// Maps the cached `accessStatus` onto the appropriate error so callers get a
    /// precise reason, then opens a new `MailDatabaseReader` for the operation.
    private func requireReader() throws -> MailDatabaseReader {
        // Translate the cached status into a specific failure before touching disk.
        switch accessStatus {
        case .permissionDenied:
            throw MailReaderError.permissionDenied
        case .mailNotConfigured:
            throw MailReaderError.mailNotConfigured
        case .available:
            break
        }

        guard let databaseURL else {
            throw MailReaderError.databaseNotFound
        }

        return try MailDatabaseReader(databaseURL: databaseURL)
    }

    /// Resolves the `.emlx` file URL for a message, preferring the cached search root.
    ///
    /// Tries the (faster) known version directory first for both full and partial
    /// variants, then falls back to a full Mail-tree scan. Throws `.emlxNotFound` if
    /// nothing matches.
    private func locateEmlxURL(for messageID: Int64) throws -> URL {
        let filename = "\(messageID).emlx"
        let partialFilename = "\(messageID).partial.emlx"

        // Prefer scanning the already-resolved version directory for either variant.
        if let emlxSearchRoot {
            if let match = findEmlxFile(named: filename, under: emlxSearchRoot) {
                return match
            }
            if let match = findEmlxFile(named: partialFilename, under: emlxSearchRoot) {
                return match
            }
        }

        // Fall back to the shared locator that rediscovers the version directory.
        if let url = MailPathLocator.locateEmlxFile(
            messageID: messageID,
            fileManager: fileManager,
            homeDirectory: homeDirectory
        ) {
            return url
        }

        throw MailReaderError.emlxNotFound(messageID)
    }

    /// Recursively searches `root` for the first file with the exact `filename`.
    private func findEmlxFile(named filename: String, under root: URL) -> URL? {
        if let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator where fileURL.lastPathComponent == filename {
                return fileURL
            }
        }
        return nil
    }
}

/// Test/demo reader that serves a bundled fixture database and `.emlx` samples.
///
/// Always reports `.available` initially and reads from a fixtures directory rather
/// than the real Apple Mail store, enabling previews and tests without Full Disk Access.
public final class FixtureMailReaderService: MailReaderServiceProtocol {
    public private(set) var accessStatus: MailAccessStatus = .available

    private let envelopeIndexURL: URL
    private let emlxDirectory: URL

    /// Points the reader at a fixtures directory containing `EnvelopeIndex.sqlite`.
    public init(fixturesDirectory: URL) {
        envelopeIndexURL = fixturesDirectory.appendingPathComponent("EnvelopeIndex.sqlite")
        emlxDirectory = fixturesDirectory
    }

    /// Marks the fixture available only if its sqlite file is actually readable.
    public func refreshAccessStatus() {
        accessStatus = FileManager.default.isReadableFile(atPath: envelopeIndexURL.path) ? .available : .mailNotConfigured
    }

    /// Lists mailboxes from the fixture database.
    public func listMailboxes() throws -> [MailMailbox] {
        try MailDatabaseReader(databaseURL: envelopeIndexURL).listMailboxes()
    }

    /// Lists message summaries from the fixture database.
    public func listMessages(mailboxID: Int64?, limit: Int) throws -> [MailMessageSummary] {
        try MailDatabaseReader(databaseURL: envelopeIndexURL).listMessages(mailboxID: mailboxID, limit: limit)
    }

    /// Loads a fixture message detail, parsing a per-message or generic `sample.emlx` body.
    public func loadMessageDetail(messageRowID: Int64) throws -> MailMessageDetail {
        let reader = try MailDatabaseReader(databaseURL: envelopeIndexURL)
        // The metadata summary must exist in the fixture DB.
        guard let summary = try reader.messageSummary(id: messageRowID) else {
            throw MailReaderError.messageNotFound(messageRowID)
        }

        // Prefer a message-specific .emlx fixture, else fall back to a shared sample.
        let emlxCandidates = [
            emlxDirectory.appendingPathComponent("\(summary.messageID).emlx"),
            emlxDirectory.appendingPathComponent("sample.emlx"),
        ]

        guard let emlxURL = emlxCandidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw MailReaderError.emlxNotFound(summary.messageID)
        }

        let parsed = try EmlxParser.parse(fileURL: emlxURL)
        return MailMessageDetail(
            summary: summary,
            bodyText: parsed.bodyText ?? summary.snippet,
            bodyHTML: parsed.bodyHTML,
            to: parsed.headers["To"],
            cc: parsed.headers["Cc"]
        )
    }
}

#else

/// iOS (non-macOS) stub for `MailReaderService`.
///
/// Apple Mail's local store doesn't exist outside macOS, so this implementation keeps
/// the API surface identical but permanently reports `.mailNotConfigured` and throws
/// from every read. This lets shared code compile and run on iOS, where Gmail (via the
/// Google backend) is the actual mail source.
public final class MailReaderService: MailReaderServiceProtocol {
    public private(set) var accessStatus: MailAccessStatus = .mailNotConfigured

    public init() {}

    /// No-op on iOS; there is no local Mail store to detect.
    public func refreshAccessStatus() {}

    /// Always throws `.mailNotConfigured`: Apple Mail is unavailable on iOS.
    public func listMailboxes() throws -> [MailMailbox] {
        throw MailReaderError.mailNotConfigured
    }

    /// Always throws `.mailNotConfigured`: Apple Mail is unavailable on iOS.
    public func listMessages(mailboxID: Int64?, limit: Int) throws -> [MailMessageSummary] {
        throw MailReaderError.mailNotConfigured
    }

    /// Always throws `.mailNotConfigured`: Apple Mail is unavailable on iOS.
    public func loadMessageDetail(messageRowID: Int64) throws -> MailMessageDetail {
        throw MailReaderError.mailNotConfigured
    }
}

#endif
