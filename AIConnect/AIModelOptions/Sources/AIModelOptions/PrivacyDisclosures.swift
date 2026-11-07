// SPDX-License-Identifier: MIT
import Foundation

/// App tabs that appear on Settings → Privacy, in iPhone tab order then Library order.
public enum PrivacyTab: String, CaseIterable, Sendable, Hashable {
    case chats
    case research
    case search
    case tasks
    case documents
    case notes
    case email
    case calendar
    case gallery
    case memory
    case compare

    public var title: String {
        switch self {
        case .chats: "Chat"
        case .research: "Research"
        case .search: "Search"
        case .tasks: "Tasks"
        case .documents: "Documents"
        case .notes: "Notes"
        case .email: "Email"
        case .calendar: "Calendar"
        case .gallery: "Gallery"
        case .memory: "Memory"
        case .compare: "Compare"
        }
    }

    public var systemImage: String {
        switch self {
        case .chats: "bubble.left.and.bubble.right"
        case .research: "magnifyingglass.circle"
        case .search: "sparkle.magnifyingglass"
        case .tasks: "checklist"
        case .documents: "doc.text"
        case .notes: "note.text"
        case .email: "envelope"
        case .calendar: "calendar"
        case .gallery: "photo.on.rectangle.angled"
        case .memory: "brain.head.profile"
        case .compare: "arrow.left.arrow.right"
        }
    }
}

/// Why Chat or Research used Instant Answers + Wikipedia instead of the
/// selected engine.
public enum ChatWebSearchFallbackReason: String, Equatable, Sendable {
    case missingBraveKey
    case braveFailed
    case searchServerFailed
}

/// Chat and Research web-search engine. Brave is the default. Saved
/// `duckDuckGo` values migrate to Brave. `quickFacts` is not selectable —
/// it names Instant Answers + Wikipedia when those answered a turn.
public enum ChatWebSearchEngine: String, Sendable, Codable, Hashable {
    case brave
    case aiProvider
    case searchServer
    case quickFacts

    public var pickerTitle: String {
        switch self {
        case .brave: "Brave Search"
        case .aiProvider: "AI provider search (may add to your bill)"
        case .searchServer: "My Search Server"
        case .quickFacts: "Quick facts"
        }
    }

    /// Name used when telling the model which engine actually answered.
    public var modelName: String {
        switch self {
        case .brave: "Brave Search"
        case .aiProvider: "your AI provider"
        case .searchServer: "your search server"
        case .quickFacts: "quick facts"
        }
    }

    public var isAdvanced: Bool {
        self == .searchServer
    }

    public var isSelectable: Bool {
        self != .quickFacts
    }

    public static let `default`: ChatWebSearchEngine = .brave
    public static let storageKey = "anaiodyssey.ai.chatWebSearchEngine"
    public static let primaryCases: [ChatWebSearchEngine] = [.brave, .aiProvider]
    public static let advancedCases: [ChatWebSearchEngine] = [.searchServer]
    public static let selectableCases: [ChatWebSearchEngine] = [.brave, .aiProvider, .searchServer]

    /// Maps a stored raw value. Leftover `duckDuckGo` (and unknown) become Brave.
    public static func resolved(_ raw: String?) -> ChatWebSearchEngine {
        switch raw {
        case "brave": .brave
        case "aiProvider": .aiProvider
        case "searchServer": .searchServer
        case "quickFacts": .quickFacts
        default: .brave
        }
    }

    /// Picker-safe resolution — `quickFacts` is not a stored user choice.
    public static func resolvedSelectable(_ raw: String?) -> ChatWebSearchEngine {
        let engine = resolved(raw)
        return engine.isSelectable ? engine : .brave
    }

    /// Rewrites a leftover DuckDuckGo (or empty) setting to Brave.
    @discardableResult
    public static func migrateStoredEngine(in defaults: UserDefaults = .standard) -> ChatWebSearchEngine {
        let raw = defaults.string(forKey: storageKey)
        let migrated = resolvedSelectable(raw)
        if raw != migrated.rawValue {
            defaults.set(migrated.rawValue, forKey: storageKey)
        }
        return migrated
    }
}

extension ChatWebSearchEngine: CaseIterable {
    public static var allCases: [ChatWebSearchEngine] {
        selectableCases
    }
}

/// Single source of truth for Settings → Privacy footers, SPEC, and App Store copy.
///
/// Chat and Research share the selected engine (Brave default, My Search Server,
/// or AI provider search). Keyless / failed Brave falls back to DuckDuckGo
/// Instant Answers and Wikipedia only — never the unofficial HTML results page.
public enum PrivacyDisclosures {
    public static let nothingLeaves = "Nothing from this tab leaves your device."

    public static let chatMessages =
        "Chat sends your messages to the AI provider you chose."

    public static let chatBraveFooter =
        "When on, search terms from your chat go to Brave Search, and the result pages it reads see a normal page visit."

    public static let chatProviderFooter =
        "When on, the AI can send search terms from your chat to the web through your AI provider. Web searches may add to your AI provider bill."

    public static let chatSearchServerFooter =
        "When on, search terms from your chat go to your own search server, which forwards them to the search engines it's set up to use, and the result pages it reads see a normal page visit."

    public static let chatQuickFactsFooter =
        "When on, search terms from your chat go to DuckDuckGo Instant Answers and Wikipedia for quick facts. Add a Brave key for full web results."

    public static let researchBraveFooter =
        "Research sends search terms to Brave Search. If Brave is unavailable it may use DuckDuckGo Instant Answers and Wikipedia. Your question and the returned snippets go to the AI provider you chose for Research."

    public static let researchSearchServerFooter =
        "Research sends search terms to your own search server, which forwards them to the search engines it's set up to use. If that server is unavailable it may use DuckDuckGo Instant Answers and Wikipedia. Your question and the returned snippets go to the AI provider you chose for Research."

    public static let researchProviderFooter =
        "Research sends search terms through your AI provider. Web searches may add to your AI provider bill. Your question and the returned snippets go to the AI provider you chose for Research."

    public static let researchQuickFactsFooter =
        "Research uses DuckDuckGo Instant Answers and Wikipedia for quick facts. Add a Brave key for full web results. Your question and the returned snippets go to the AI provider you chose for Research."

    /// Default Research copy when Brave is the active engine.
    public static let research = researchBraveFooter

    public static let tasks =
        "Tasks send the assignment to the AI provider you chose. A task can run Research, so the same search disclosure applies. Tasks cannot see email or calendar."

    public static let documents =
        "Documents send the text you ask the AI to write or edit to the AI provider you chose for Documents."

    public static let email =
        "Email stays on this device for Apple Mail. Connected Gmail accounts send requests to Google. The assistant can read mail only if you turn on Allow AI to access Email."

    public static let calendar =
        "Calendar events are read from this device. Connected Google Calendar accounts send requests to Google. The assistant can read or create events only if you turn on Allow AI to access Calendar."

    public static let gallery =
        "Gallery image generation sends your prompt to the AI provider you chose for images. Importing from Photos stays on this device."

    public static let memory =
        "Memories are stored on this device. When Chat recalls a memory, that text is sent with the chat to the AI provider you chose."

    public static let compare =
        "Compare sends each prompt to the AI providers you selected for that run."

    public static func chatWebSearchFooter(engine: ChatWebSearchEngine) -> String {
        switch engine {
        case .brave: chatBraveFooter
        case .aiProvider: chatProviderFooter
        case .searchServer: chatSearchServerFooter
        case .quickFacts: chatQuickFactsFooter
        }
    }

    /// Research runs are owned by the app, not the screen (iOS gives ~30 s once backgrounded).
    public static let researchRunsWhileOpen = "Runs keep going while the app is open."

    public static func researchFooter(engine: ChatWebSearchEngine) -> String {
        let base: String
        switch engine {
        case .brave: base = researchBraveFooter
        case .aiProvider: base = researchProviderFooter
        case .searchServer: base = researchSearchServerFooter
        case .quickFacts: base = researchQuickFactsFooter
        }
        return base + " " + researchRunsWhileOpen
    }

    public static func chatDisclosure(
        isWebSearchAllowed: Bool,
        engine: ChatWebSearchEngine
    ) -> String {
        guard isWebSearchAllowed else { return chatMessages }
        return chatMessages + " " + chatWebSearchFooter(engine: engine)
    }

    public static func disclosure(
        for tab: PrivacyTab,
        chatWebSearchAllowed: Bool = false,
        chatEngine: ChatWebSearchEngine = .brave
    ) -> String {
        switch tab {
        case .chats:
            chatDisclosure(isWebSearchAllowed: chatWebSearchAllowed, engine: chatEngine)
        case .research:
            researchFooter(engine: chatEngine)
        case .search, .notes:
            nothingLeaves
        case .tasks:
            tasks
        case .documents:
            documents
        case .email:
            email
        case .calendar:
            calendar
        case .gallery:
            gallery
        case .memory:
            memory
        case .compare:
            compare
        }
    }
}
