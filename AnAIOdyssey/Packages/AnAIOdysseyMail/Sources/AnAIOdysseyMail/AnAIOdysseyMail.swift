// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import AnAIOdysseyCore

/// Top-level namespace for the AnAIOdysseyMail module.
///
/// Exposes the package `version` (kept in sync with `AnAIOdysseyCore`) and an
/// `isSupported` flag indicating whether mail is available on this platform
/// (Gmail OAuth on iOS/iPadOS/macOS; Apple Mail additionally on macOS).
public enum AnAIOdysseyMail {
    public static let version = AnAIOdysseyCore.version

    public static let isSupported = true
}

#if os(macOS)
/// macOS-only locator for the sample Mail fixtures used by previews and tests.
///
/// Fixtures (a small `EnvelopeIndex.sqlite` plus `.emlx` samples) may live in the app
/// bundle once Xcode copies resources, or in the source tree during development. This
/// namespace probes the likely locations in priority order.
public enum MailFixtures {
    /// Resolves the fixtures directory from the built app bundle, if present.
    ///
    /// Checks several bundle subpaths for `EnvelopeIndex.sqlite`, then a direct bundle
    /// resource lookup, and finally falls back to the source-tree fixtures.
    public static func bundledDirectory() -> URL? {
        // Probe common bundle layouts where the fixtures may have been copied.
        if let resourceURL = Bundle.main.resourceURL {
            let candidates = [
                resourceURL.appendingPathComponent("Mail", isDirectory: true),
                resourceURL.appendingPathComponent("Fixtures/Mail", isDirectory: true),
                resourceURL,
            ]
            for candidate in candidates {
                if FileManager.default.fileExists(
                    atPath: candidate.appendingPathComponent("EnvelopeIndex.sqlite").path
                ) {
                    return candidate
                }
            }
        }
        // Fall back to a direct resource lookup, returning its containing directory.
        if let sqliteURL = Bundle.main.url(forResource: "EnvelopeIndex", withExtension: "sqlite") {
            return sqliteURL.deletingLastPathComponent()
        }
        // Last resort: the development/source-tree fixtures.
        return developmentFixturesDirectory()
    }

    /// Used when Xcode hasn't copied fixture resources into the app bundle yet.
    ///
    /// Resolution order: an explicit `ANAIODYSSEY_MAIL_FIXTURES` env override, then a
    /// `Fixtures/Mail` directory relative to the current working directory, then a path
    /// derived from this source file's location within the repo.
    public static func developmentFixturesDirectory() -> URL? {
        // 1) Honor an explicit override pointing at a fixtures directory.
        let envPath = ProcessInfo.processInfo.environment["ANAIODYSSEY_MAIL_FIXTURES"]
        if let envPath, !envPath.isEmpty {
            let url = URL(fileURLWithPath: envPath, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }

        // 2) Look for fixtures relative to the process working directory.
        let cwd = FileManager.default.currentDirectoryPath
        let candidate = URL(fileURLWithPath: cwd).appendingPathComponent("Fixtures/Mail", isDirectory: true)
        if FileManager.default.fileExists(atPath: candidate.path) { return candidate }

        // 3) Walk up from this file's location to the repo root and look there.
        // Five `deletingLastPathComponent()` calls climb out of
        // Sources/AnAIOdysseyMail/.../AnAIOdysseyMail.swift to the package root.
        let sourceRelative = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Mail", isDirectory: true)
        if FileManager.default.fileExists(atPath: sourceRelative.path) { return sourceRelative }

        return nil
    }

    /// Convenience that prefers bundled fixtures and falls back to development fixtures.
    public static func resolveFixturesDirectory() -> URL? {
        bundledDirectory() ?? developmentFixturesDirectory()
    }
}
#endif
