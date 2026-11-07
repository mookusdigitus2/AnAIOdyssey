// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation

/// User-controlled permissions governing whether the AI agent may read the user's
/// private email and calendar through its tools, and whether Chat may search the web.
///
/// Defaults are **off** (privacy-first): the assistant only gains access once the
/// user explicitly enables it in Settings. The keys use the `anaiodyssey.` prefix so
/// `CloudDefaultsSync` mirrors them across the user's devices, and they are read
/// from `UserDefaults.standard` — the same store SwiftUI's `@AppStorage` writes to.
public enum AIDataAccess {
    /// `@AppStorage`/`UserDefaults` key gating AI access to email.
    public static let emailKey = "anaiodyssey.ai.allowEmailAccess"
    /// `@AppStorage`/`UserDefaults` key gating AI access to calendar.
    public static let calendarKey = "anaiodyssey.ai.allowCalendarAccess"
    /// `@AppStorage`/`UserDefaults` key gating Chat web search (not Agent tasks or Research).
    public static let chatWebSearchKey = "anaiodyssey.ai.allowChatWebSearch"
    /// `@AppStorage`/`UserDefaults` key for Chat/Research search engine (`brave`, `aiProvider`, `searchServer`).
    /// Leftover `duckDuckGo` values migrate to `brave`.
    public static let chatWebSearchEngineKey = "anaiodyssey.ai.chatWebSearchEngine"
    /// Shared SearXNG base URL for Chat (My Search Server) and Research.
    public static let searxBaseURLKey = "anaiodyssey.search.searxBaseURL"
    /// Keychain account for the Brave Search API subscription token.
    public static let braveSearchKeyAccount = "brave-search"

    /// Stored SearXNG address, trimmed. Empty when the user has not configured one.
    public static var searxBaseURL: String {
        (UserDefaults.standard.string(forKey: searxBaseURLKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the agent is currently allowed to read the user's email.
    public static var isEmailAllowed: Bool {
        UserDefaults.standard.bool(forKey: emailKey)
    }

    /// Whether the agent is currently allowed to read the user's calendar.
    public static var isCalendarAllowed: Bool {
        UserDefaults.standard.bool(forKey: calendarKey)
    }

    /// Whether Chat may send search terms to the web. Off by default.
    public static var isChatWebSearchAllowed: Bool {
        UserDefaults.standard.bool(forKey: chatWebSearchKey)
    }
}
