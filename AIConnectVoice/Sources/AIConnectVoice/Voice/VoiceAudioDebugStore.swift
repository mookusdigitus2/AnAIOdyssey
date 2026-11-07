// SPDX-License-Identifier: MIT
import Foundation
import AIConnect
import AIModelOptions

/// Append-only breadcrumb log (last ~200 audio events) in Documents so the user
/// can share it after a crash even without an analytics report.
public enum VoiceAudioDebugStore {
    /// File IO runs here, never on the caller's thread: voice events are
    /// logged from the Stop/Back tap path.
    private static let ioQueue = DispatchQueue(label: "com.example.anaiodyssey.audio-log", qos: .utility)

    public static var fileURL: URL {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return directory.appendingPathComponent(VoiceAudioDebugLogPolicy.fileName)
    }

    public static func hasLog() -> Bool {
        ioQueue.sync {
            guard let data = try? Data(contentsOf: fileURL) else { return false }
            return !data.isEmpty
        }
    }

    public static func readText() -> String {
        ioQueue.sync { readTextOnQueue() }
    }

    private static func readTextOnQueue() -> String {
        (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
    }

    /// Copies the log to a fresh, readable .txt in tmp for the share sheet.
    /// Sharing a large String from a Form row failed silently on device; a
    /// file URL is what Mail/Messages/Files expect.
    public static func exportForSharing() -> URL? {
        let text = readText()
        guard !text.isEmpty else { return nil }
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnAIOdyssey-audio-log-\(stamp).txt")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    /// Tests observe every event synchronously (log-shape checks).
    public nonisolated(unsafe) static var observerForTesting: (@Sendable (String, String) -> Void)?

    public static func append(event: String, detail: String) {
        observerForTesting?(event, detail)
        let formatter = ISO8601DateFormatter()
        let crumb = VoiceAudioBreadcrumb(
            timestamp: formatter.string(from: Date()),
            event: event,
            detail: detail
        )
        let line = crumb.line
        ioQueue.async {
            var lines = readTextOnQueue()
                .split(whereSeparator: \.isNewline)
                .map(String.init)
            lines = VoiceAudioDebugLogPolicy.append(lines, event: line)
            try? lines.joined(separator: "\n").write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }
}
