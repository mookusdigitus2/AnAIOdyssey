// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation

/// A single row in a checklist-style `Note`.
///
/// Checklist items are stored inline on `Note.checklistItems` (rather than as a
/// separate persisted model), so this is a lightweight value type. `Codable`
/// lets it round-trip through SwiftData / legacy JSON imports, and `Hashable` +
/// `Sendable` make it safe to diff in SwiftUI and pass across actors.
public struct ChecklistItem: Codable, Hashable, Sendable, Identifiable {
    /// Stable identity so SwiftUI lists don't key rows by array position.
    public var id: UUID
    /// The user-visible label for this checklist line.
    public var text: String
    /// Whether the item has been checked off.
    public var done: Bool

    /// Creates a checklist item, defaulting to an unchecked state.
    public init(id: UUID = UUID(), text: String, done: Bool = false) {
        self.id = id
        self.text = text
        self.done = done
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case text
        case done
    }

    /// Custom decoding so records saved before `id` existed (and Python-era
    /// legacy imports) still decode — they get a fresh identity.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try container.decode(String.self, forKey: .text)
        done = try container.decodeIfPresent(Bool.self, forKey: .done) ?? false
    }
}
