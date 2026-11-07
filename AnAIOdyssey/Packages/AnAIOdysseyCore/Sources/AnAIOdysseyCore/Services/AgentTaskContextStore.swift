// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation

/// Persists large task context blobs on disk (metadata stays in SwiftData).
public enum AgentTaskContextStore {
    private static let directoryName = "agent-contexts"

    /// Root directory for context files under Application Support.
    public static func directory(appSupport: URL) -> URL {
        appSupport.appendingPathComponent(directoryName, isDirectory: true)
    }

    public static func ensureDirectory(appSupport: URL) throws -> URL {
        let url = directory(appSupport: appSupport)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes text to a new file and returns the filename (not full path).
    public static func save(text: String, appSupport: URL, taskID: String) throws -> String {
        let dir = try ensureDirectory(appSupport: appSupport)
        let name = "\(taskID)-\(UUID().uuidString).txt"
        let fileURL = dir.appendingPathComponent(name)
        try text.write(to: fileURL, atomically: true, encoding: .utf8)
        return name
    }

    public static func load(fileName: String, appSupport: URL) throws -> String {
        let url = directory(appSupport: appSupport).appendingPathComponent(fileName)
        return try String(contentsOf: url, encoding: .utf8)
    }

    public static func delete(fileName: String, appSupport: URL) {
        let url = directory(appSupport: appSupport).appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: url)
    }
}
