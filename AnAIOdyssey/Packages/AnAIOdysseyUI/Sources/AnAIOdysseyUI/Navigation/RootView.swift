// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import AnAIOdysseyAI
import AnAIOdysseyCore
import AIModelOptions
import SwiftUI

/// The app's primary shell on Mac and regular-width iPad: a **sidebar** of
/// grouped top-level ``AppSection`` areas (Work / AI / Library) beside the
/// selected feature view. iPhone (compact width) uses ``PhoneRootView``'s
/// five-tab bar instead.
///
/// Each feature view (Email, Notes, Documents, …) still owns its *own*
/// `NavigationSplitView` for navigation *within* that function; those nested
/// split views render inside this shell's detail column.
///
/// `RootView` also guards against a missing dependency graph: feature views read
/// their services from the SwiftUI environment, so if `repositories` was never
/// injected the whole UI would silently fail — instead we show an explicit
/// setup-error state.
public struct RootView: View {
    /// The repository bundle injected by the host app. `nil` means the
    /// composition root never wired up persistence, which is treated as a fatal
    /// setup error rather than rendered as empty screens.
    @Environment(\.repositories) private var repositories
    @Environment(\.llmService) private var llmService
    @EnvironmentObject private var agentRegistrySettings: AgentRegistrySettings
    @EnvironmentObject private var providerSettings: ProviderSettings
    /// Currently selected top-level section; drives `detailView`. Defaults to Chats.
    /// Scene-scoped so rotation / background does not reset the sidebar.
    @SceneStorage(WorkspaceNavigationPolicy.tabletSectionSceneKey) private var selectionRaw = "chats"
    private var selection: AppSection {
        get { AppSection(rawValue: WorkspaceNavigationPolicy.restoredTabletSection(selectionRaw)) ?? .chats }
        nonmutating set { selectionRaw = newValue.rawValue }
    }
    /// Active storage mode, forwarded to Settings so it can report local vs. iCloud.
    let storageMode: StorageMode
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif

    public init(storageMode: StorageMode = .local) {
        self.storageMode = storageMode
    }

    /// Renders the sidebar shell once dependencies are present, or a setup-error
    /// placeholder if the repository graph was never injected.
    @AppStorage(FeatureSettings.galleryEnabledKey) private var galleryEnabled = false
    @State private var settingsInitialPage: SettingsPage?
    @State private var settingsInitialFocus: SettingsOpenFocus?
    @State private var settingsInitialConnectionID: String?

    public var body: some View {
        Group {
            if repositories != nil {
                #if os(iOS)
                if WorkspaceNavigationPolicy.rootKind(
                    idiomIsPhone: WorkspaceIdiom.isPhone,
                    horizontalSizeClassIsRegular: horizontalSizeClass == .regular,
                    verticalSizeClassIsRegular: verticalSizeClass == .regular
                ) == .phone {
                    PhoneRootView(storageMode: storageMode)
                } else {
                    tabletShell
                }
                #else
                tabletShell
                #endif
            } else {
                // Fail loudly and legibly when bootstrap wiring is missing.
                ContentUnavailableView(
                    "Setup Error",
                    systemImage: "exclamationmark.triangle",
                    description: Text("Repositories were not injected.")
                )
            }
        }
        .workspaceSceneRoot()
        .firstRunModelSetup()
        .unexpectedTerminationAudioLogPrompt()
        .accessibilityIdentifier("root-view")
        .onChange(of: galleryEnabled) { _, enabled in
            if !enabled, selection == .gallery {
                selection = .chats
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: FeatureSettings.galleryEnabledDidChange)) { _ in
            galleryEnabled = true
        }
        .onAppear {
            if !galleryEnabled, selection == .gallery {
                selection = .chats
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: WorkspaceOpenRequest.notification)) { note in
            guard let request = WorkspaceOpenRequest(notification: note) else { return }
            switch request.kind {
            case .document:
                selection = .documents
            case .research:
                selection = .research
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: SettingsOpenRequest.notification)) { note in
            settingsInitialPage = SettingsOpenRequest.page(from: note)
            settingsInitialFocus = SettingsOpenRequest.focus(from: note)
            settingsInitialConnectionID = SettingsOpenRequest.connectionID(from: note)
            #if os(iOS)
            selection = .settings
            #endif
        }
    }

    /// Mac / regular-width iPad shell: a real sidebar of grouped sections with
    /// list selection, so every destination stays visible and VoiceOver reads
    /// the selected row, per Apple's navigation guidance. On the open iPhone Duo
    /// the same sidebar sits on the right (``DuoNavigationPolicy``).
    @ViewBuilder
    private var tabletShell: some View {
        #if os(iOS)
        if sidebarEdge == .trailing {
            duoShell
        } else {
            splitShell
        }
        #else
        splitShell
        #endif
    }

    #if os(iOS)
    /// Which side the section sidebar is on. DEBUG `-DuoLayout` treats the device
    /// as a phone here, so an iPad simulator can stand in for the open Duo.
    private var sidebarEdge: SidebarEdge {
        var idiomIsPhone = WorkspaceIdiom.isPhone
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains(DuoNavigationPolicy.simulateDuoArgument) {
            idiomIsPhone = true
        }
        #endif
        return DuoNavigationPolicy.sectionSidebarEdge(
            idiomIsPhone: idiomIsPhone,
            horizontalSizeClassIsRegular: horizontalSizeClass == .regular,
            verticalSizeClassIsRegular: verticalSizeClass == .regular
        )
    }

    /// Open iPhone Duo: the selected feature on the left, the section sidebar on
    /// the right. `NavigationSplitView` always puts its sidebar first (left), so
    /// this shell lays the two out itself; the sidebar is always shown.
    private var duoShell: some View {
        HStack(spacing: 0) {
            detailView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .workspaceFillDetailPane()
            Divider()
                .ignoresSafeArea()
            NavigationStack {
                duoSectionSidebar
            }
            .frame(width: 260)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("duo-shell")
    }

    /// The same grouped sections for the Duo shell. Outside a `NavigationSplitView`
    /// sidebar, `List(selection:)` only selects in edit mode on iOS, so each row is a
    /// button that sets the section and marks itself selected.
    private var duoSectionSidebar: some View {
        List {
            ForEach(AppSection.sidebarGroups(galleryEnabled: galleryEnabled)) { group in
                Section(group.title) {
                    ForEach(group.sections) { section in
                        duoSidebarRow(section)
                    }
                }
            }
            Section {
                duoSidebarRow(.settings)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle(AppBranding.appName)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("section-sidebar")
        .safeAreaInset(edge: .bottom) {
            HStack {
                StorageSyncBadge(storageMode: storageMode)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    private func duoSidebarRow(_ section: AppSection) -> some View {
        let isSelected = selection == section
        return Button {
            selection = section
        } label: {
            Label(section.title, systemImage: section.systemImage)
                .badge(runningCount(for: section))
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .listRowBackground(
            isSelected ? RoundedRectangle(cornerRadius: 10).fill(Color.accentColor) : nil
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("sidebar-\(section.rawValue)")
    }
    #endif

    private var splitShell: some View {
        NavigationSplitView {
            sectionSidebar
        } detail: {
            detailView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .workspaceFillDetailPane()
        }
        .navigationSplitViewStyle(.balanced)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The grouped section list. Uses system `List` selection (not custom
    /// buttons) so rows get the standard selection style and accessibility
    /// traits for free.
    @ObservedObject private var chatRuns = ChatGenerationCenter.shared
    @ObservedObject private var researchRuns = ResearchRunCenter.shared

    /// Sidebar dot: how many Chat / Research runs are still going.
    private func runningCount(for section: AppSection) -> Int {
        switch section {
        case .chats: chatRuns.activeRunCount
        case .research: researchRuns.activeRunCount
        default: 0
        }
    }

    private var sectionSidebar: some View {
        List(selection: sidebarSelection) {
            ForEach(AppSection.sidebarGroups(galleryEnabled: galleryEnabled)) { group in
                Section(group.title) {
                    ForEach(group.sections) { section in
                        Label(section.title, systemImage: section.systemImage)
                            .badge(runningCount(for: section))
                            .tag(section)
                            // Identifier kept from the old tab bar for UI tests.
                            .accessibilityIdentifier("sidebar-\(section.rawValue)")
                    }
                }
            }
            #if os(iOS)
            // macOS reaches Settings via the menu bar (⌘,); iPad lists it here.
            Section {
                Label(AppSection.settings.title, systemImage: AppSection.settings.systemImage)
                    .tag(AppSection.settings)
                    .accessibilityIdentifier("sidebar-\(AppSection.settings.rawValue)")
            }
            #endif
        }
        #if os(macOS)
        .listStyle(.sidebar)
        #endif
        .navigationTitle(AppBranding.appName)
        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        .accessibilityIdentifier("section-sidebar")
        .safeAreaInset(edge: .bottom) {
            HStack {
                StorageSyncBadge(storageMode: storageMode)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    /// Bridges the always-selected section to the optional selection `List` wants;
    /// a sidebar tap can never deselect everything.
    private var sidebarSelection: Binding<AppSection?> {
        Binding(
            get: { selection },
            set: { newValue in
                if let newValue {
                    selection = newValue
                }
            }
        )
    }

    /// The body area: resolves the current `selection` to its feature view.
    ///
    /// This is the app's routing table. Email and Settings are platform-gated:
    /// Email's reader services exist only on macOS, and Settings is presented
    /// inline on iOS but via the menu-bar Settings window on macOS — so each
    /// shows an explanatory placeholder on the platform where it isn't native.
    @ViewBuilder
    private var detailView: some View {
        Group {
            switch selection {
            case .chats:
                ChatsView()
            case .documents:
                DocumentsWorkspaceView()
            case .notes:
                NotesView()
            case .memory:
                MemoryView()
            case .gallery:
                GalleryView()
            case .research:
                ResearchView()
            case .search:
                UnifiedSearchView()
            case .compare:
                CompareView()
            case .calendar:
                AppCalendarView()
            case .tasks:
                TasksView()
            case .email:
                // Email is cross-platform: Gmail via OAuth on iPad/Mac, plus Apple Mail on Mac.
                EmailView()
            #if os(iOS)
            case .settings:
                SettingsView(
                    storageMode: storageMode,
                    initialPage: settingsInitialPage,
                    initialFocus: settingsInitialFocus,
                    initialConnectionID: settingsInitialConnectionID
                )
            #else
            case .settings:
                ContentUnavailableView(
                    "Settings",
                    systemImage: "gearshape",
                    description: Text("Choose \(AppBranding.appName) ▸ Settings (⌘,) from the menu bar.")
                )
            #endif
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

