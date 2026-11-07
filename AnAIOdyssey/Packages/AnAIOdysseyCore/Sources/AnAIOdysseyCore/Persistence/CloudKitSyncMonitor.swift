// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import CloudKit
import Combine
import CoreData
import Foundation
import OSLog

/// Observes the CloudKit mirroring activity behind the SwiftData container and
/// exposes it to the UI, so sync problems are visible instead of silent.
///
/// SwiftData's CloudKit support is built on `NSPersistentCloudKitContainer`,
/// which posts `eventChangedNotification` for every setup/import/export cycle.
/// This monitor records the most recent outcome of each phase plus the last
/// error, which Settings surfaces for on-device diagnosis (especially on
/// TestFlight builds where console logs aren't accessible). Full error details
/// (including per-record failures inside CloudKit partial failures) are also
/// appended to `cloudkit-sync-errors.log` in Application Support.
@MainActor
public final class CloudKitSyncMonitor: ObservableObject {
    public static let shared = CloudKitSyncMonitor()

    /// Human-readable outcome of the most recent CloudKit setup phase.
    @Published public private(set) var lastSetup: String?
    /// Most recent download (import) outcome.
    @Published public private(set) var lastImport: String?
    /// Most recent upload (export) outcome.
    @Published public private(set) var lastExport: String?
    /// Description of the most recent sync error, if any phase failed.
    @Published public private(set) var lastError: String?

    /// Posted when a CloudKit download finishes so file-backed stores (gallery) can catch up.
    public static let didFinishImport = Notification.Name("anaiodyssey.cloudKit.didFinishImport")

    private var observer: NSObjectProtocol?
    /// Store-touching closure installed by the app; scheduling a tiny save is
    /// the only sanctioned way to make the mirroring engine attempt an export.
    private var nudgeHandler: (@MainActor () -> Void)?
    /// Consecutive failed sync cycles, driving the watchdog's backoff.
    private var consecutiveFailures = 0
    private var retryTask: Task<Void, Never>?

    private init() {}

    /// Installs the closure used to nudge the sync engine (a no-op-ish save).
    public func installNudge(_ handler: @escaping @MainActor () -> Void) {
        nudgeHandler = handler
    }

    /// User-initiated "Sync Now": nudges the engine to export pending changes
    /// and fetch remote ones immediately.
    public func requestSync() {
        retryTask?.cancel()
        retryTask = nil
        nudgeHandler?()
    }

    /// Schedules an automatic retry after a failure, with capped exponential
    /// backoff (1, 2, 4, 8, capped at 10 minutes). Failed syncs must never be
    /// abandoned: the engine's own retries can wedge until relaunch, so this
    /// watchdog keeps prodding it for as long as the app runs.
    private func scheduleRetry() {
        retryTask?.cancel()
        let delay = min(60.0 * pow(2.0, Double(max(consecutiveFailures - 1, 0))), 600.0)
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.nudgeHandler?()
        }
    }

    /// Begins listening for CloudKit mirroring events. Safe to call when the
    /// store is local-only — no events will arrive.
    public func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil,
            queue: .main
        ) { notification in
            let key = NSPersistentCloudKitContainer.eventNotificationUserInfoKey
            guard let event = notification.userInfo?[key] as? NSPersistentCloudKitContainer.Event else {
                return
            }
            Task { @MainActor in
                CloudKitSyncMonitor.shared.record(event)
            }
        }
    }

    private func record(_ event: NSPersistentCloudKitContainer.Event) {
        let summary = Self.describe(event)
        switch event.type {
        case .setup: lastSetup = summary
        case .import: lastImport = summary
        case .export: lastExport = summary
        @unknown default: break
        }
        if let error = event.error {
            let phase = Self.phaseName(event.type)
            let detail = Self.detailedDescription(for: error)
            lastError = "\(phase): \(detail)"
            Self.appendToErrorLog("\(phase): \(detail)")
            // The concise description can hide the cause (Core Data sometimes
            // strips userInfo), so also log the complete error structure.
            Self.appendToErrorLog("\(phase) full detail: \(Self.dump(error: error as NSError))")
            // Core Data strips per-record sub-errors from the event, but logs
            // them via os_log in-process — harvest our own log for the truth.
            Task.detached(priority: .utility) {
                let harvested = Self.harvestCoreDataLogEntries()
                if !harvested.isEmpty {
                    await MainActor.run {
                        Self.appendToErrorLog("\(phase) os_log detail:\n\(harvested)")
                    }
                }
            }
            if event.endDate != nil {
                consecutiveFailures += 1
                scheduleRetry()
            }
        } else if event.endDate != nil, event.succeeded {
            // A successful completion of any phase clears a stale error banner
            // and resets the retry watchdog.
            lastError = nil
            consecutiveFailures = 0
            retryTask?.cancel()
            retryTask = nil
            if event.type == .import {
                NotificationCenter.default.post(name: Self.didFinishImport, object: nil)
            }
        }
    }

    private static func describe(_ event: NSPersistentCloudKitContainer.Event) -> String {
        guard let end = event.endDate else { return "In progress…" }
        let time = end.formatted(date: .omitted, time: .shortened)
        return event.succeeded ? "Succeeded at \(time)" : "Failed at \(time)"
    }

    private static func phaseName(_ type: NSPersistentCloudKitContainer.EventType) -> String {
        switch type {
        case .setup: return "Setup"
        case .import: return "Download"
        case .export: return "Upload"
        @unknown default: return "Sync"
        }
    }

    // MARK: - Error detail extraction

    /// Expands a CloudKit error into an actionable message. Partial failures
    /// (CKError 2) hide the real cause in per-record sub-errors, so those are
    /// unwrapped, de-duplicated, and counted.
    static func detailedDescription(for error: Error) -> String {
        let nsError = error as NSError
        guard nsError.domain == CKErrorDomain else {
            return nsError.localizedDescription
        }

        if nsError.code == CKError.partialFailure.rawValue,
           let partials = nsError.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error],
           !partials.isEmpty {
            // Group identical sub-errors so one bad record type reads as a
            // single line instead of hundreds.
            var counts: [String: Int] = [:]
            for (_, subError) in partials {
                let message = singleErrorDescription(subError as NSError)
                counts[message, default: 0] += 1
            }
            let grouped = counts
                .sorted { $0.value > $1.value }
                .prefix(3)
                .map { "\($0.value)× \($0.key)" }
                .joined(separator: " | ")
            return "\(partials.count) record(s) failed: \(grouped)"
        }

        return singleErrorDescription(nsError)
    }

    private static func singleErrorDescription(_ nsError: NSError) -> String {
        var parts = [nsError.localizedDescription]
        if let serverMessage = nsError.userInfo["ServerErrorDescription"] as? String {
            parts.append(serverMessage)
        }
        if nsError.domain == CKErrorDomain, let name = ckErrorName(code: nsError.code) {
            parts.append("[\(name)]")
        }
        return parts.joined(separator: " ")
    }

    /// Names for the CloudKit error codes most relevant to mirroring failures.
    private static func ckErrorName(code: Int) -> String? {
        switch CKError.Code(rawValue: code) {
        case .internalError: return "internalError"
        case .partialFailure: return "partialFailure"
        case .networkUnavailable: return "networkUnavailable"
        case .networkFailure: return "networkFailure"
        case .badContainer: return "badContainer"
        case .serviceUnavailable: return "serviceUnavailable"
        case .requestRateLimited: return "requestRateLimited"
        case .missingEntitlement: return "missingEntitlement"
        case .notAuthenticated: return "notAuthenticated"
        case .permissionFailure: return "permissionFailure"
        case .unknownItem: return "unknownItem"
        case .invalidArguments: return "invalidArguments"
        case .serverRecordChanged: return "serverRecordChanged"
        case .serverRejectedRequest: return "serverRejectedRequest"
        case .constraintViolation: return "constraintViolation"
        case .changeTokenExpired: return "changeTokenExpired"
        case .batchRequestFailed: return "batchRequestFailed"
        case .zoneBusy: return "zoneBusy"
        case .quotaExceeded: return "quotaExceeded"
        case .zoneNotFound: return "zoneNotFound"
        case .limitExceeded: return "limitExceeded"
        case .userDeletedZone: return "userDeletedZone"
        case .accountTemporarilyUnavailable: return "accountTemporarilyUnavailable"
        default: return nil
        }
    }

    /// Recursively renders an NSError with its full userInfo, underlying
    /// errors, and CloudKit partial-failure sub-errors, capped for sanity.
    static func dump(error: NSError, depth: Int = 0) -> String {
        guard depth < 4 else { return "…" }
        var lines = ["\(error.domain)(\(error.code)) \(error.localizedDescription)"]
        for (key, value) in error.userInfo {
            if let sub = value as? NSError {
                lines.append("[\(key)] \(dump(error: sub, depth: depth + 1))")
            } else if let dict = value as? [AnyHashable: Any] {
                // CloudKit partial failures: itemID -> error. Log up to 5.
                for (itemID, item) in dict.prefix(5) {
                    if let sub = item as? NSError {
                        lines.append("[\(key)] \(itemID): \(dump(error: sub, depth: depth + 1))")
                    } else {
                        lines.append("[\(key)] \(itemID): \(item)")
                    }
                }
                if dict.count > 5 { lines.append("[\(key)] …and \(dict.count - 5) more") }
            } else {
                lines.append("[\(key)] \(String(describing: value).prefix(300))")
            }
        }
        return lines.joined(separator: " • ")
    }

    /// Reads this process's own unified-log entries (allowed without special
    /// permissions) and extracts recent Core Data / CloudKit error lines, which
    /// contain the per-record failure reasons the event API withholds.
    nonisolated static func harvestCoreDataLogEntries() -> String {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return "" }
        let position = store.position(date: Date().addingTimeInterval(-180))
        guard let entries = try? store.getEntries(at: position) else { return "" }
        var lines: [String] = []
        for entry in entries {
            guard let log = entry as? OSLogEntryLog else { continue }
            let message = log.composedMessage
            let isCoreDataError = log.subsystem == "com.apple.coredata"
                && (log.level == .error || log.level == .fault
                    || message.contains("CKError") || message.contains("Error"))
            let isCloudKitError = log.subsystem == "com.apple.cloudkit"
                && (log.level == .error || log.level == .fault)
            if isCoreDataError || isCloudKitError {
                lines.append("\(log.date.formatted(.iso8601)) \(message.prefix(2000))")
            }
        }
        return lines.suffix(25).joined(separator: "\n")
    }

    /// Directly saves (then deletes) a probe record via CKDatabase to obtain an
    /// unredacted server error. Core Data strips failure details from mirroring
    /// events, but direct CloudKit calls return the server's real explanation —
    /// e.g. "record type not found" when the Production schema was never
    /// deployed. Results are appended to the error log.
    public static func probeSchema() async {
        let container = CKContainer(identifier: ModelContainerFactory.cloudKitContainerID)
        let database = container.privateCloudDatabase
        let record = CKRecord(
            recordType: "CD_Note",
            recordID: CKRecord.ID(recordName: "schema-probe-\(UUID().uuidString)")
        )
        record["CD_title"] = "schema probe" as CKRecordValue
        do {
            let saved = try await database.save(record)
            await MainActor.run {
                appendToErrorLog("Schema probe: CD_Note save SUCCEEDED (schema exists in this environment)")
            }
            try? await database.deleteRecord(withID: saved.recordID)
        } catch {
            let detail = dump(error: error as NSError)
            await MainActor.run {
                appendToErrorLog("Schema probe: CD_Note save FAILED: \(detail)")
            }
        }
    }

    // MARK: - On-disk error log

    /// Where full sync-error details are appended for offline diagnosis.
    public static var errorLogURL: URL {
        AppBranding.applicationSupportDirectory()
            .appendingPathComponent("cloudkit-sync-errors.log", isDirectory: false)
    }

    private static func appendToErrorLog(_ message: String) {
        let url = errorLogURL
        let fileManager = FileManager.default
        try? fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Cap the log so repeated failures can't grow it without bound.
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 200_000 {
            try? fileManager.removeItem(at: url)
        }
        let timestamp = Date().formatted(.iso8601)
        let line = "\(timestamp) \(message)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
