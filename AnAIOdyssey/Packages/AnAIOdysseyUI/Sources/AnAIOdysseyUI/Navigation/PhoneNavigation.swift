// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import AnAIOdysseyCore

/// iPhone tab-bar destinations (five items per HIG).
public enum PhoneTab: String, CaseIterable, Identifiable, Hashable {
    case chats
    case research
    case search
    case tasks
    case library

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .chats: "Chats"
        case .research: "Research"
        case .search: "Search"
        case .tasks: "Tasks"
        case .library: "Library"
        }
    }

    public var systemImage: String {
        switch self {
        case .chats: "bubble.left.and.bubble.right.fill"
        case .research: "magnifyingglass.circle.fill"
        case .search: "sparkle.magnifyingglass"
        case .tasks: "checklist"
        case .library: "books.vertical.fill"
        }
    }
}
