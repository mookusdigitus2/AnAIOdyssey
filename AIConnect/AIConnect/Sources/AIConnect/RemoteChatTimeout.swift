// SPDX-License-Identifier: MIT
import Foundation

/// Idle vs total-resource timeouts for remote chat streams.
///
/// The idle timeout is how long we wait between bytes. The resource cap is a
/// last-resort ceiling so a 10-minute total no longer kills long local or
/// reasoning generations. Both can be changed in UserDefaults.
public enum RemoteChatTimeout {
    public static let defaultIdleSeconds: TimeInterval = 600
    public static let defaultResourceSeconds: TimeInterval = 86_400
    public static let idleDefaultsKey = "aiconnect.chatIdleTimeoutSeconds"
    public static let resourceDefaultsKey = "aiconnect.chatResourceTimeoutSeconds"

    public static func idleSeconds(defaults: UserDefaults = .standard) -> TimeInterval {
        positive(defaults.object(forKey: idleDefaultsKey) as? Double, fallback: defaultIdleSeconds)
    }

    public static func resourceSeconds(defaults: UserDefaults = .standard) -> TimeInterval {
        positive(defaults.object(forKey: resourceDefaultsKey) as? Double, fallback: defaultResourceSeconds)
    }

    private static func positive(_ value: Double?, fallback: TimeInterval) -> TimeInterval {
        guard let value, value > 0 else { return fallback }
        return value
    }
}
