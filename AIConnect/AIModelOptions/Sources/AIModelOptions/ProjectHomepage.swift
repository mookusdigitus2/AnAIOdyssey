// SPDX-License-Identifier: MIT
import Foundation

/// The project homepage the AI packages send for attribution: OpenRouter's
/// `HTTP-Referer` header and the DuckDuckGo user agent.
///
/// Resolution order:
/// 1. `override`, if the host app sets it in code.
/// 2. The host app's Info.plist `PROJECT_HOMEPAGE_URL` value.
/// 3. `placeholderURL`, a neutral default.
public enum AIProjectHomepage {
    /// Neutral default used when the host app does not configure a homepage.
    public static let placeholderURL = "https://example.com"

    /// Info.plist key the host app can set (for example from an xcconfig).
    public static let infoPlistKey = "PROJECT_HOMEPAGE_URL"

    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var value: String?
    }
    private static let storage = Storage()

    /// Set by the host app to choose the homepage in code. `nil` uses the
    /// Info.plist value or the placeholder.
    public static var override: String? {
        get { storage.lock.lock(); defer { storage.lock.unlock() }; return storage.value }
        set { storage.lock.lock(); storage.value = newValue; storage.lock.unlock() }
    }

    /// The homepage to send.
    public static var url: String {
        resolve(infoValue: Bundle.main.object(forInfoDictionaryKey: infoPlistKey) as? String)
    }

    /// Picks the homepage from the override, an Info.plist value, or the
    /// placeholder. Blank values and unexpanded `$(...)` build settings are ignored.
    public static func resolve(infoValue: String?) -> String {
        if let chosen = usable(override) { return chosen }
        if let chosen = usable(infoValue) { return chosen }
        return placeholderURL
    }

    private static func usable(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty, !trimmed.hasPrefix("$(") else { return nil }
        return trimmed
    }
}
