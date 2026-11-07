// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import Combine

/// Half-typed chat messages, per chat, kept outside the chat view. On the iPhone Duo, folding
/// or unfolding swaps the root view (phone ↔ tablet shell) and rebuilds the open chat; the
/// draft comes back from here. In memory only, like a text field's own state.
@MainActor
public final class ChatDraftStore: ObservableObject {
    public static let shared = ChatDraftStore()
    private var drafts: [String: String] = [:]

    public init() {}

    public func draft(for sessionID: String) -> String { drafts[sessionID] ?? "" }

    public func setDraft(_ text: String, for sessionID: String) {
        if text.isEmpty { drafts[sessionID] = nil } else { drafts[sessionID] = text }
    }

    public var isEmpty: Bool { drafts.isEmpty }
}
