// SPDX-License-Identifier: MIT
import Foundation

/// Keeps the last spoken assistant reply so the voice UI can replay it.
public struct VoiceReplayStore: Equatable, Sendable {
    public private(set) var lastReply: String?

    public init(lastReply: String? = nil) {
        self.lastReply = lastReply
    }

    public var canReplay: Bool { lastReply != nil }

    /// Records a finished spoken reply; blank text keeps the previous one.
    public mutating func record(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lastReply = trimmed
    }

    public mutating func clear() {
        lastReply = nil
    }
}
