// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import AnAIOdysseyCore
import AIModelOptions
import SwiftUI

#if os(iOS)

/// iPhone shell: five-tab `TabView` with per-tab `NavigationStack`s.
public struct PhoneRootView: View {
    /// What the Library tab is showing. `nil` means "the default": the promoted
    /// section when one is set, otherwise the grid. All Library navigation flows
    /// through this one value (see `resolvedLibraryDisplay`).
    private enum LibraryDisplay: Equatable {
        case grid
        case section(AppSection)
    }

    @Environment(\.repositories) private var repositories
    @SceneStorage(WorkspaceNavigationPolicy.phoneTabSceneKey) private var selectedTabRaw = "chats"
    private var selectedTab: PhoneTab {
        get { PhoneTab(rawValue: WorkspaceNavigationPolicy.restoredPhoneTab(selectedTabRaw)) ?? .chats }
        nonmutating set { selectedTabRaw = newValue.rawValue }
    }
    private var selectedTabBinding: Binding<PhoneTab> {
        Binding(
            get: { selectedTab },
            set: { selectedTab = $0 }
        )
    }
    @State private var showSettings = false
    @State private var settingsInitialPage: SettingsPage?
    @State private var settingsInitialFocus: SettingsOpenFocus?
    @State private var settingsInitialConnectionID: String?
    @State private var libraryDisplay: LibraryDisplay?
    @AppStorage(FeatureSettings.galleryEnabledKey) private var galleryEnabled = false
    @AppStorage(PhoneTabSettings.promotedSectionKey) private var promotedSectionRaw: String?
    let storageMode: StorageMode

    public init(storageMode: StorageMode = .local) {
        self.storageMode = storageMode
    }

    private var promotedSection: AppSection? {
        promotedSectionRaw.flatMap(AppSection.init(rawValue:))
    }

    /// The single source of truth for what the Library tab renders.
    private var resolvedLibraryDisplay: LibraryDisplay {
        libraryDisplay ?? promotedSection.map { .section($0) } ?? .grid
    }

    public var body: some View {
        Group {
            if repositories != nil {
                TabView(selection: selectedTabBinding) {
                    tabStack(.chats) { ChatsView() }
                    tabStack(.research) { ResearchView() }
                    tabStack(.search) { UnifiedSearchView() }
                    tabStack(.tasks) { TasksView() }
                    libraryTabStack
                }
                // No hardcoded tint here: ThemeContainer at the scene root applies
                // the user's chosen accent, which a fixed Aegean tint would override.
            } else {
                ContentUnavailableView(
                    "Setup Error",
                    systemImage: "exclamationmark.triangle",
                    description: Text("Repositories were not injected.")
                )
            }
        }
        .firstRunModelSetup()
        .sheet(isPresented: $showSettings, onDismiss: {
            settingsInitialPage = nil
            settingsInitialFocus = nil
            settingsInitialConnectionID = nil
        }) {
            SettingsView(
                storageMode: storageMode,
                initialPage: settingsInitialPage,
                initialFocus: settingsInitialFocus,
                initialConnectionID: settingsInitialConnectionID
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: SettingsOpenRequest.notification)) { note in
            settingsInitialPage = SettingsOpenRequest.page(from: note)
            settingsInitialFocus = SettingsOpenRequest.focus(from: note)
            settingsInitialConnectionID = SettingsOpenRequest.connectionID(from: note)
            showSettings = true
        }
        .onChange(of: promotedSectionRaw) { _, _ in
            libraryDisplay = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: FeatureSettings.galleryEnabledDidChange)) { _ in
            galleryEnabled = true
        }
        .onReceive(NotificationCenter.default.publisher(for: WorkspaceOpenRequest.notification)) { note in
            guard let request = WorkspaceOpenRequest(notification: note) else { return }
            switch request.kind {
            case .document:
                selectedTab = .library
                libraryDisplay = .section(.documents)
            case .research:
                selectedTab = .research
            }
        }
    }

    @ViewBuilder
    private var libraryTabStack: some View {
        NavigationStack {
            switch resolvedLibraryDisplay {
            case .grid:
                libraryGrid
            case .section(let section):
                libraryWorkspace(for: section)
            }
        }
        .tabItem {
            Label(libraryTabLabel.title, systemImage: libraryTabLabel.icon)
        }
        .tag(PhoneTab.library)
    }

    /// Tab-bar label mirrors what the Library tab is showing.
    private var libraryTabLabel: (title: String, icon: String) {
        switch resolvedLibraryDisplay {
        case .grid:
            (PhoneTab.library.title, PhoneTab.library.systemImage)
        case .section(let section):
            (section.title, section.systemImage)
        }
    }

    private var libraryGrid: some View {
        LibraryGridView(galleryEnabled: galleryEnabled) { section in
            libraryDisplay = .section(section)
        }
        .navigationTitle(PhoneTab.library.title)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                HStack(spacing: 8) {
                    StorageSyncBadge(storageMode: storageMode)
                    // The grid only renders over a promotion when explicitly
                    // opened, so offer a way back to the promoted workspace.
                    if let promoted = promotedSection {
                        Button {
                            libraryDisplay = nil
                        } label: {
                            Label(promoted.title, systemImage: "chevron.left")
                        }
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                settingsButton
            }
        }
    }

    /// A Library workspace shown as the stack root (not pushed), with a uniform
    /// "Library" button back to the grid.
    @ViewBuilder
    private func libraryWorkspace(for section: AppSection) -> some View {
        libraryDestination(for: section)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 8) {
                        StorageSyncBadge(storageMode: storageMode)
                        Button("Library") {
                            libraryDisplay = .grid
                        }
                    }
                }
            }
    }

    @ObservedObject private var chatRuns = ChatGenerationCenter.shared
    @ObservedObject private var researchRuns = ResearchRunCenter.shared

    /// Tab dot: how many Chat / Research runs are still going.
    private func runningCount(for tab: PhoneTab) -> Int {
        switch tab {
        case .chats: chatRuns.activeRunCount
        case .research: researchRuns.activeRunCount
        default: 0
        }
    }

    @ViewBuilder
    private func tabStack<Content: View>(
        _ tab: PhoneTab,
        @ViewBuilder content: () -> Content
    ) -> some View {
        NavigationStack {
            content()
                .navigationTitle(tab.title)
                .navigationBarTitleDisplayMode(tab == .search ? .inline : .large)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        StorageSyncBadge(storageMode: storageMode)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        settingsButton
                    }
                }
        }
        .tabItem {
            Label(tab.title, systemImage: tab.systemImage)
        }
        .badge(runningCount(for: tab))
        .tag(tab)
    }

    private var settingsButton: some View {
        Button {
            showSettings = true
        } label: {
            // Settings is settings, not a profile: use the gear glyph.
            Image(systemName: "gearshape")
        }
        .accessibilityLabel("Settings")
    }

    @ViewBuilder
    private func libraryDestination(for section: AppSection) -> some View {
        switch section {
        case .documents: DocumentsWorkspaceView()
        case .notes: NotesView()
        case .email: EmailView()
        case .calendar: AppCalendarView()
        case .gallery: GalleryView()
        case .memory: MemoryView()
        case .compare: CompareView()
        default: EmptyView()
        }
    }
}

/// Library grid of secondary workspaces on iPhone.
struct LibraryGridView: View {
    let galleryEnabled: Bool
    let onSelect: (AppSection) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(PhoneTabSettings.promotedSectionKey) private var promotedSectionRaw: String?

    private let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(AppSection.librarySections(galleryEnabled: galleryEnabled)) { section in
                    Button {
                        onSelect(section)
                    } label: {
                        LibraryTile(section: section, isPromoted: section.rawValue == promotedSectionRaw)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("library-\(section.rawValue)")
                    .contextMenu {
                        if section.rawValue == promotedSectionRaw {
                            Button("Remove from Tab Bar") {
                                PhoneTabSettings.promotedLibrarySection = nil
                            }
                        } else {
                            Button("Add to Tab Bar") {
                                PhoneTabSettings.promotedLibrarySection = section
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .background(AegeanColors.groupedBackground(colorScheme))
    }
}

private struct LibraryTile: View {
    let section: AppSection
    var isPromoted: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: section.systemImage)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.tint)
            Text(section.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AegeanColors.label(colorScheme))
            if isPromoted {
                Text("On Tab Bar")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tint)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 100)
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AegeanColors.surface(colorScheme))
        )
    }
}

#endif
