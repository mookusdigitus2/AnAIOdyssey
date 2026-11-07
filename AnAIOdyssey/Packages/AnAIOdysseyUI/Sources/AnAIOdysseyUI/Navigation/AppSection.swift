// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import AnAIOdysseyCore

/// The top-level workspaces a user can switch between from the app sidebar.
///
/// Each case is a self-contained feature area (Chats, Notes, Gallery, …). The
/// enum centralizes everything the navigation chrome needs to render a sidebar
/// entry — its stable identity, display title, and SF Symbol — and which
/// sections are offered per platform. `String`-backed raw values double as
/// stable accessibility identifiers for UI tests.
public enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case chats
    case documents
    case notes
    case memory
    case gallery
    case research
    case search
    case compare
    case calendar
    case tasks
    case email
    case settings

    /// Stable identity for `ForEach`/`List` selection; reuses the raw value.
    public var id: String { rawValue }

    /// Human-readable label shown in the sidebar and as the navigation title.
    public var title: String {
        switch self {
        case .chats: "Chats"
        case .documents: "Documents"
        case .notes: "Notes"
        case .memory: "Memory"
        case .gallery: "Gallery"
        case .research: "Research"
        case .search: "Search"
        case .compare: "Compare"
        case .calendar: "Calendar"
        case .tasks: "Tasks"
        case .email: "Email"
        case .settings: "Settings"
        }
    }

    /// SF Symbol name used for the sidebar icon next to each section title.
    public var systemImage: String {
        switch self {
        case .chats: "bubble.left.and.bubble.right"
        case .documents: "doc.text"
        case .notes: "note.text"
        case .memory: "brain.head.profile"
        case .gallery: "photo.on.rectangle.angled"
        case .research: "magnifyingglass.circle"
        case .search: "sparkle.magnifyingglass"
        case .compare: "arrow.left.arrow.right"
        case .calendar: "calendar"
        case .tasks: "checklist"
        case .email: "envelope"
        case .settings: "gearshape"
        }
    }

    /// Ordered list of top-level sections shown in the top tab bar, tailored per
    /// platform and optional feature flags.
    ///
    /// Gallery is off by default; enable it in Settings → Features. macOS reaches
    /// Settings through the menu-bar Settings window, so it is omitted on macOS;
    /// iOS shows Settings inline as a pinned trailing tab.
    public static func topLevelSections(galleryEnabled: Bool = FeatureSettings.isGalleryEnabled) -> [AppSection] {
        var sections: [AppSection] = [.chats, .documents, .notes, .memory]
        if galleryEnabled {
            sections.append(.gallery)
        }
        sections.append(contentsOf: [.research, .search, .compare, .calendar, .tasks, .email])
        #if os(iOS)
        sections.append(.settings)
        #endif
        return sections
    }

    /// Backward-compatible alias; prefer `topLevelSections(galleryEnabled:)` in UI.
    public static var topLevelSections: [AppSection] {
        topLevelSections(galleryEnabled: FeatureSettings.isGalleryEnabled)
    }

    /// One titled group of sections in the Mac/iPad sidebar.
    public struct SidebarGroup: Identifiable {
        public let title: String
        public let sections: [AppSection]
        public var id: String { title }
    }

    /// Grouped top-level sections for the Mac and regular-width iPad sidebar.
    ///
    /// Settings is not listed here: macOS reaches it via the menu-bar Settings
    /// window (⌘,), and iPadOS pins it as its own trailing sidebar section in
    /// `RootView`. Gallery stays behind its feature flag.
    public static func sidebarGroups(galleryEnabled: Bool = FeatureSettings.isGalleryEnabled) -> [SidebarGroup] {
        var groups: [SidebarGroup] = [
            SidebarGroup(title: "Work", sections: [.chats, .documents, .notes, .email, .calendar, .tasks]),
            SidebarGroup(title: "AI", sections: [.research, .search, .compare, .memory]),
        ]
        if galleryEnabled {
            groups.append(SidebarGroup(title: "Library", sections: [.gallery]))
        }
        return groups
    }

    /// Ordered sections surfaced inside the iPhone Library tab's grid.
    public static func librarySections(galleryEnabled: Bool = FeatureSettings.isGalleryEnabled) -> [AppSection] {
        var sections: [AppSection] = [.documents, .notes, .email, .calendar]
        if galleryEnabled {
            sections.append(.gallery)
        }
        sections.append(contentsOf: [.memory, .compare])
        return sections
    }
}
