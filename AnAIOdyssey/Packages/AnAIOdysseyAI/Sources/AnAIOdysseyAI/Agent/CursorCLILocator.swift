// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation

/// Locates the Cursor CLI without spawning subprocesses (safe during SwiftUI layout).
enum CursorCLILocator {
    /// Returns the absolute path to an executable Cursor CLI, if found.
    static func executablePath(configuredPath: String) -> String? {
        #if !os(macOS)
        return nil
        #else
        let trimmed = configuredPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "cursor" : trimmed

        if name.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: name) ? name : nil
        }

        if let fromPATH = findInPATH(executableName: name) {
            return fromPATH
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let wellKnown = [
            "/usr/local/bin/\(name)",
            "/opt/homebrew/bin/\(name)",
            "\(home)/.local/bin/\(name)",
        ]
        for candidate in wellKnown where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return nil
        #endif
    }

    static func isInstalled(configuredPath: String) -> Bool {
        executablePath(configuredPath: configuredPath) != nil
    }

    private static func findInPATH(executableName: String) -> String? {
        let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin"
        for dir in pathEnv.split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = (String(dir) as NSString).appendingPathComponent(executableName)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
