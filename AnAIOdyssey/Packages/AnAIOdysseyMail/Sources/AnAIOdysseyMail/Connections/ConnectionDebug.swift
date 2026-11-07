// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation

/// Secret-safe connection diagnostics written directly to standard output.
///
/// Debug builds log automatically. Release builds require
/// `ANAIODYSSEY_CONNECTION_DEBUG=1`. Never pass authorization codes, access
/// tokens, refresh tokens, request headers, or complete message/calendar data.
public enum ConnectionDebug {
    public static var isEnabled: Bool {
        #if DEBUG
        true
        #else
        ProcessInfo.processInfo.environment["ANAIODYSSEY_CONNECTION_DEBUG"] == "1"
        #endif
    }

    public static func log(
        _ component: String,
        _ message: @autoclosure () -> String
    ) {
        guard isEnabled else { return }
        let timestamp = String(format: "%.3f", Date().timeIntervalSince1970)
        print("[ConnectionDebug \(timestamp)] [\(component)] \(message())")
        fflush(stdout)
    }

    /// Short identifier suitable for correlating one account without logging its email.
    public static func account(_ id: String) -> String {
        "…\(id.suffix(8))"
    }
}
