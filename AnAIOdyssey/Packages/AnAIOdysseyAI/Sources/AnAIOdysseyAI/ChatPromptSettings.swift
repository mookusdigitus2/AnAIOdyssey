// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import AnAIOdysseyCore

/// Odyssey's chat persona prompt. Kept out of the shared connection settings,
/// which hold no app prompts. Uses the same storage key as before.
@MainActor
public final class ChatPromptSettings: ObservableObject {
    public static let shared = ChatPromptSettings()

    private static let storageKey = "anaiodyssey.chat.systemPrompt"

    public static let defaultChatSystemPrompt = """
        You are \(AppBranding.appName), a helpful conversational assistant.
        Answer directly and concisely in a natural, friendly tone.
        Prefer short paragraphs and plain prose; only use headings, bullet lists, or tables when the user explicitly asks or the content truly calls for it.
        You are having a conversation, not writing a formal report.
        """

    @Published public var chatSystemPrompt: String {
        didSet { defaults.set(chatSystemPrompt, forKey: Self.storageKey) }
    }

    public var effectiveChatSystemPrompt: String? {
        let trimmed = chatSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private let defaults: UserDefaults
    private var cloudSyncObserver: NSObjectProtocol?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        chatSystemPrompt = defaults.string(forKey: Self.storageKey) ?? Self.defaultChatSystemPrompt
        cloudSyncObserver = NotificationCenter.default.addObserver(
            forName: CloudDefaultsSync.didApplyRemoteChanges,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    deinit {
        if let cloudSyncObserver {
            NotificationCenter.default.removeObserver(cloudSyncObserver)
        }
    }

    private func reload() {
        let stored = defaults.string(forKey: Self.storageKey) ?? Self.defaultChatSystemPrompt
        if stored != chatSystemPrompt { chatSystemPrompt = stored }
    }
}
