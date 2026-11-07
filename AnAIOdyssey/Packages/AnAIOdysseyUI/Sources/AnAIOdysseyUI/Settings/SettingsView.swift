// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import AnAIOdysseyAI
import AnAIOdysseyCore
import AIModelOptions
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
// Mail accounts (Gmail OAuth) and Google connections are cross-platform.
import AnAIOdysseyMail

/// The top-level Settings categories, each rendered as its own page.
///
/// iOS shows a root list that pushes one page at a time; macOS shows the pages
/// as tabs of the menu-bar Settings window. Raw values double as stable
/// accessibility identifiers for UI tests.
public enum SettingsPage: String, CaseIterable, Identifiable {
    case general
    case accounts
    case aiModels
    case voice
    case privacy
    case notifications
    case data
    case about

    public var id: String { rawValue }

    /// Human-readable page title.
    public var title: String {
        switch self {
        case .general: "General"
        case .accounts: "Accounts"
        case .aiModels: "AI Models"
        case .voice: "Voice"
        case .privacy: "Privacy"
        case .notifications: "Notifications"
        case .data: "Data & Storage"
        case .about: "About"
        }
    }

    /// SF Symbol shown next to the page title.
    public var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .accounts: "person.crop.circle"
        case .aiModels: "cpu"
        case .voice: "waveform"
        case .privacy: "hand.raised"
        case .notifications: "bell"
        case .data: "externaldrive"
        case .about: "info.circle"
        }
    }
}

/// The Settings screen: configuration grouped into focused pages (General,
/// Accounts, AI Models, Voice, Privacy, Notifications, Data & Storage, About)
/// instead of one endless scrolling form.
///
/// It is `public` because the host app presents it both inline on iOS and as the
/// macOS menu-bar Settings window. Each section is factored into its own computed
/// property; most actions are async network/IO tasks whose progress and results
/// are mirrored into dedicated `@State` so the UI can show spinners and outcomes.
public struct SettingsView: View {
    /// Local/remote model service used for model selection, loading, and status.
    @Environment(\.llmService) private var llmService
    /// Manager for downloading/deleting on-device model weights.
    @Environment(\.localModelManager) private var localModelManager
    /// Remote provider configuration (base URL, key, model) edited here.
    @EnvironmentObject private var providerSettings: ProviderSettings
    @ObservedObject private var chatPromptSettings = ChatPromptSettings.shared
    /// App-wide appearance (accent palette + light/dark), shared across windows.
    @EnvironmentObject private var themeSettings: ThemeSettings
    /// Multi-agent controller preferences.
    @EnvironmentObject private var agentRegistrySettings: AgentRegistrySettings
    /// Per-feature default model selections.
    @EnvironmentObject private var featureModelSettings: FeatureModelSettings
    @Environment(\.agentController) private var agentController
    /// Multi-account mail store (Gmail OAuth) — cross-platform.
    @EnvironmentObject private var mailAccountStore: MailAccountStore
    /// Singleton connection manager (Google Auth email/calendar adapters).
    @EnvironmentObject private var connectionManager: WorkspaceConnectionManager
    /// Google Gemini/Calendar settings.
    @EnvironmentObject private var googleSettings: GoogleSettings
    @EnvironmentObject private var chatGPTAccounts: ChatGPTAccountService
    /// Web search backend used by the "Test Web Search" action.
    @Environment(\.webSearchService) private var webSearchService
    /// Persistence used by the workspace and Notion importers.
    @Environment(\.repositories) private var repositories
    /// SwiftData context handed to the import services.
    @Environment(\.modelContext) private var modelContext
    /// Used after a workspace import to re-embed newly restored memories.
    @Environment(\.memoryService) private var memoryService
    /// FTS sidecar rebuilt after a replace import so search matches the new store.
    @Environment(\.searchIndexStore) private var searchIndexStore
    /// Unified mail reader rebuilt after Gmail sign-in so download can start immediately.
    @Environment(\.mailReader) private var mailReader
    /// Active storage mode shown in the Storage section.
    let storageMode: StorageMode
    /// Resolved appearance, used to pick each accent's light/dark pair.
    @Environment(\.colorScheme) private var colorScheme
    /// Live CloudKit mirroring activity (setup/import/export outcomes + errors).
    @ObservedObject private var syncMonitor = CloudKitSyncMonitor.shared

    /// AI data-access permissions (privacy-gated; default off). Stored under the
    /// `anaiodyssey.` prefix so they sync across devices via `CloudDefaultsSync`.
    @AppStorage(AIDataAccess.emailKey) private var allowAIEmailAccess = false
    @AppStorage(AIDataAccess.calendarKey) private var allowAICalendarAccess = false
    @AppStorage(AIDataAccess.chatWebSearchKey) private var allowChatWebSearch = false
    @AppStorage(AIDataAccess.chatWebSearchEngineKey) private var chatWebSearchEngine = ChatWebSearchEngine.brave
    @AppStorage(AIDataAccess.searxBaseURLKey) private var searxBaseURL = ""
    /// macOS: Settings > About > Acknowledgements opens as a sheet (the
    /// Settings window is a TabView with no navigation stack).
    @State private var showingAcknowledgements = false
    @State private var showAdvancedSearchEngines = false
    @State private var braveSearchAPIKey = ""
    @State private var didLoadBraveSearchKey = false
    @State private var isProbingSearchServer = false
    @State private var searchServerProbe: SearXNGProbeStatus?
    @State private var isProbingBrave = false
    @State private var braveProbe: BraveSearchCodec.ProbeStatus?
    @FocusState private var focusedSearchField: SettingsOpenFocus?
    @AppStorage(FeatureSettings.galleryEnabledKey) private var galleryEnabled = false
    @State private var photosLibraryAllowed = false
    @State private var photosLibraryReadable = false
    @State private var photosLibraryNeedsSettings = false

    /// Page to push (iOS) or select (macOS) when Settings opens, e.g. Privacy from Chat.
    var initialPage: SettingsPage?
    var initialFocus: SettingsOpenFocus?
    /// When set, AI Models opens that connection's editor (Tool Format).
    var initialConnectionID: String?
    #if os(iOS)
    @State private var settingsPath = NavigationPath()
    #else
    @State private var selectedSettingsTab: SettingsPage = .general
    #endif
    @State private var didApplyInitialSettingsPage = false
    @State private var pendingFocus: SettingsOpenFocus?

    public init(
        storageMode: StorageMode,
        initialPage: SettingsPage? = nil,
        initialFocus: SettingsOpenFocus? = nil,
        initialConnectionID: String? = nil
    ) {
        self.storageMode = storageMode
        self.initialPage = initialPage
        self.initialFocus = initialFocus
        self.initialConnectionID = initialConnectionID
        _pendingFocus = State(initialValue: initialFocus)
    }

    /// On-device model management state: current per-model statuses, the model
    /// being downloaded (if any) with its progress, and the most recent error.
    @State private var localModelStatuses: [LocalModelStatus] = []
    @State private var downloadingModelID: String?
    @State private var downloadProgress: Double?
    @State private var downloadTask: Task<Void, Never>?
    @State private var loadingModelID: String?
    @State private var rowErrors: [String: String] = [:]
    @State private var modelPendingDelete: LocalModelStatus?

    /// Mail-account management state (cross-platform Gmail OAuth).
    @State private var isAddingMailAccount = false
    @State private var mailAccountError: String?

    /// Web-search test state.
    @State private var isSearchingWeb = false
    @State private var webSearchQuery = "\(AppBranding.appName) AI assistant"
    @State private var webSearchResults: [WebSearchResult] = []
    @State private var webSearchError: String?

    /// Notion export import state and progress.
    @State private var showNotionImportPicker = false
    @State private var isNotionImporting = false
    @State private var notionImportStage = ""
    @State private var notionImportProgress: Double = 0
    @State private var notionImportResultMessage: String?
    @State private var notionImportError: String?

    /// Workspace backup (export/import) state.
    @State private var isPreparingExport = false
    @State private var showWorkspaceExportPicker = false
    @State private var workspaceExportDocument = WorkspaceArchiveDocument()
    @State private var workspaceExportFileName = WorkspaceArchive.suggestedFileName()
    @State private var exportStage = ""
    @State private var exportProgress: Double = 0
    @State private var exportResultMessage: String?
    @State private var exportError: String?
    @State private var pendingExportSummary: String?

    @State private var showWorkspaceImportPicker = false
    @State private var isWorkspaceImporting = false
    @State private var workspaceImportStage = ""
    @State private var workspaceImportProgress: Double = 0
    @State private var workspaceImportResultMessage: String?
    @State private var workspaceImportError: String?
    @State private var eraseExistingOnImport = false
    @State private var pendingImportURL: URL?
    @State private var pendingImportDidAccess = false
    @State private var showReplaceImportConfirmation = false


    /// Google Calendar sync state.
    @State private var isSyncingGoogleCalendar = false
    @State private var googleCalendarSyncResult: String?
    @State private var googleCalendarSyncError: String?

    /// Remote connection currently being edited. Owned here so presentation
    /// attaches to the Settings form (stable) rather than the connections
    /// section (which rebuilds when `ProviderSettings` publishes).
    @State private var editingRemoteConnection: RemoteConnection?

    /// Model rows for the AI Models page, built once per catalog change.
    /// The form itself only shows the selected label.
    @State private var settingsModelChoices: [ConfiguredModelChoice] = []

    /// Pushed pages on the AI Models form. Kept off the scrolling rows so a
    /// fling through the model section does not build every option or a
    /// multiline text view.
    private enum AIModelsDestination: Hashable {
        case model(SettingsModelPickerRoute)
        case chatPrompt
    }

    /// Settings shell: a pushed-page list on iOS, tabs in the macOS Settings
    /// window. Each page is a focused form of related sections.
    public var body: some View {
        #if os(iOS)
        NavigationStack(path: $settingsPath) {
            List {
                ForEach(SettingsPage.allCases) { page in
                    NavigationLink(value: page) {
                        Label(page.title, systemImage: page.systemImage)
                    }
                    .accessibilityIdentifier("settings-page-\(page.rawValue)")
                }
            }
            .navigationTitle("Settings")
            .navigationDestination(for: SettingsPage.self) { page in
                pageForm(page)
            }
            .accessibilityIdentifier("settings-view")
        }
        .onAppear { applyInitialSettingsPageIfNeeded() }
        .onReceive(NotificationCenter.default.publisher(for: SettingsOpenRequest.notification)) { note in
            if let page = SettingsOpenRequest.page(from: note) {
                pendingFocus = SettingsOpenRequest.focus(from: note)
                navigate(to: page)
                openConnectionEditor(id: SettingsOpenRequest.connectionID(from: note))
            }
        }
        #else
        TabView(selection: $selectedSettingsTab) {
            ForEach(SettingsPage.allCases) { page in
                pageForm(page)
                    .tabItem {
                        Label(page.title, systemImage: page.systemImage)
                    }
                    .tag(page)
            }
        }
        .frame(minWidth: 640, minHeight: 440)
        .accessibilityIdentifier("settings-view")
        .onAppear { applyInitialSettingsPageIfNeeded() }
        .onReceive(NotificationCenter.default.publisher(for: SettingsOpenRequest.notification)) { note in
            if let page = SettingsOpenRequest.page(from: note) {
                pendingFocus = SettingsOpenRequest.focus(from: note)
                navigate(to: page)
                openConnectionEditor(id: SettingsOpenRequest.connectionID(from: note))
            }
        }
        #endif
    }

    private func applyInitialSettingsPageIfNeeded() {
        ChatWebSearchEngine.migrateStoredEngine()
        chatWebSearchEngine = ChatWebSearchEngine.resolvedSelectable(chatWebSearchEngine.rawValue)
        guard !didApplyInitialSettingsPage else { return }
        didApplyInitialSettingsPage = true
        if let initialFocus {
            pendingFocus = initialFocus
        }
        if let initialPage {
            navigate(to: initialPage)
        }
        openConnectionEditor(id: initialConnectionID)
    }

    private func navigate(to page: SettingsPage) {
        #if os(iOS)
        settingsPath = NavigationPath()
        settingsPath.append(page)
        #else
        selectedSettingsTab = page
        #endif
    }

    private func openConnectionEditor(id: String?) {
        guard let id, let connection = providerSettings.connection(id: id) else { return }
        Task { @MainActor in
            editingRemoteConnection = connection
        }
    }

    /// One settings page: the form of sections belonging to that category, with
    /// the page-specific presentation plumbing (pickers, editors, alerts).
    @ViewBuilder
    private func pageForm(_ page: SettingsPage) -> some View {
        Group {
            switch page {
            case .general:
                Form {
                    appearanceSection
                    featuresSection
                }
            case .accounts:
                Form {
                    mailAccountsSection
                    googleCalendarSection
                }
            case .aiModels:
                aiModelsForm
            case .voice:
                Form {
                    agentControllerSection
                    voiceAdvancedSection
                }
            case .privacy:
                Form {
                    ForEach(PrivacyTab.allCases, id: \.self) { tab in
                        privacySection(for: tab)
                    }
                }
            case .notifications:
                Form {
                    NotificationSettingsSection()
                }
            case .data:
                dataForm
            case .about:
                Form {
                    aboutSection
                }
            }
        }
        .workspaceSettingsForm()
        .navigationTitle(page.title)
        .accessibilityIdentifier("settings-page-form-\(page.rawValue)")
    }

    /// AI Models page: local weights, remote connections, per-feature defaults,
    /// chat prompt, Gemini, and the web-search test — plus the connection editor.
    ///
    /// Model defaults are navigation rows, not in-form pickers. A `Picker` builds
    /// every option while its row is on screen, which stalled scrolling through
    /// this section. The choice list is loaded once and shown only after a tap.
    private var aiModelsForm: some View {
        Form {
            if OnDeviceLanguageModelSupport.shouldShowLocalModelsSection(manager: localModelManager) {
                localModelSection
            }
            RemoteConnectionsSection(
                providerSettings: providerSettings,
                featureModelSettings: featureModelSettings,
                llmService: llmService,
                editingConnection: $editingRemoteConnection
            )
            featureModelDefaultsSection
            chatSection
            geminiSection
            webSearchSection
        }
        // Refresh on-device model download state when the page appears.
        .onAppear {
            reloadLocalModelStatuses()
            featureModelSettings.syncDefaultsIfNeeded(providerSettings: providerSettings)
            reloadSettingsModelChoices()
        }
        .onChange(of: localModelStatuses) { _, _ in
            reloadSettingsModelChoices()
        }
        .onChange(of: providerSettings.remoteConnections) { _, _ in
            reloadSettingsModelChoices()
        }
        // On iPhone Settings is already a sheet; push the editor instead of nesting sheets.
        #if os(iOS)
        .navigationDestination(for: AIModelsDestination.self) { destination in
            switch destination {
            case .model(let route):
                SettingsModelChoiceList(
                    title: modelPickerTitle(for: route),
                    selectionKey: modelSelectionBinding(for: route),
                    choices: modelChoicesForRoute(route),
                    resetLabel: modelResetLabel(for: route),
                    resetDisabled: modelResetDisabled(for: route),
                    onReset: { resetModelSelection(route) }
                )
            case .chatPrompt:
                ChatSystemPromptEditor(prompt: $chatPromptSettings.chatSystemPrompt)
            }
        }
        .navigationDestination(item: $editingRemoteConnection) { connection in
            RemoteConnectionEditorView(
                connection: connection,
                onSave: { updated in
                    providerSettings.updateConnection(updated)
                    editingRemoteConnection = nil
                },
                onCancel: { editingRemoteConnection = nil },
                onSignOut: {
                    Task {
                        await chatGPTAccounts.signOut(
                            connection: connection,
                            providerSettings: providerSettings
                        )
                        editingRemoteConnection = nil
                    }
                }
            )
        }
        #else
        .sheet(item: $editingRemoteConnection) { connection in
            NavigationStack {
                RemoteConnectionEditorView(
                    connection: connection,
                    onSave: { updated in
                        providerSettings.updateConnection(updated)
                        editingRemoteConnection = nil
                    },
                    onCancel: { editingRemoteConnection = nil },
                    onSignOut: {
                        Task {
                            await chatGPTAccounts.signOut(
                                connection: connection,
                                providerSettings: providerSettings
                            )
                            editingRemoteConnection = nil
                        }
                    }
                )
            }
        }
        #endif
    }

    /// Data & Storage page: storage mode, workspace backup, and Notion import —
    /// plus the file pickers and the destructive-import confirmation.
    private var dataForm: some View {
        Form {
            storageSection
            workspaceBackupSection
            notionImportSection
        }
        // Picker for a Notion export (folder or .zip).
        .fileImporter(
            isPresented: $showNotionImportPicker,
            allowedContentTypes: [.folder, .zip],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task { await importNotionExport(from: url) }
            case .failure(let error):
                notionImportError = error.localizedDescription
            }
        }
        .fileExporter(
            isPresented: $showWorkspaceExportPicker,
            document: workspaceExportDocument,
            contentType: .zip,
            defaultFilename: workspaceExportFileName
        ) { result in
            switch result {
            case .success:
                exportResultMessage = pendingExportSummary
            case .failure(let error):
                exportError = error.localizedDescription
            }
            pendingExportSummary = nil
            workspaceExportDocument = WorkspaceArchiveDocument()
        }
        .fileImporter(
            isPresented: $showWorkspaceImportPicker,
            allowedContentTypes: [.zip],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                if eraseExistingOnImport {
                    pendingImportURL = url
                    pendingImportDidAccess = url.startAccessingSecurityScopedResource()
                    showReplaceImportConfirmation = true
                } else {
                    Task { await importWorkspaceArchive(from: url, replaceExisting: false) }
                }
            case .failure(let error):
                workspaceImportError = error.localizedDescription
            }
        }
        .alert(
            "Erase existing content?",
            isPresented: $showReplaceImportConfirmation
        ) {
            Button("Erase and Import", role: .destructive) {
                guard let url = pendingImportURL else { return }
                Task {
                    await importWorkspaceArchive(from: url, replaceExisting: true)
                    finishPendingImportAccess()
                }
            }
            Button("Cancel", role: .cancel) {
                finishPendingImportAccess()
            }
        } message: {
            Text("This permanently deletes chats, documents, notes, memories, gallery, research, tasks, and agent work in this workspace, then imports the archive. Email and calendar are left alone.")
        }
    }

    /// App appearance: light/dark/system and a changeable accent palette. Choices
    /// are shared live with every window (including pop-outs) and sync via iCloud.
    private var appearanceSection: some View {
        Section("Appearance") {
            Picker("Theme", selection: $themeSettings.appearance) {
                ForEach(AppAppearance.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("appearance-mode-picker")

            VStack(alignment: .leading, spacing: 8) {
                Text("Accent Color")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // Adaptive grid so the 44pt swatches wrap instead of clipping on
                // narrow (iPhone) widths.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 4)], spacing: 4) {
                    ForEach(AppAccent.allCases) { accent in
                        accentSwatch(accent)
                    }
                }
                // Confirms the live selection by name (and proves the tint took
                // effect, since this text renders in the selected accent).
                Text(themeSettings.accent.displayName)
                    .font(.caption)
                    .foregroundStyle(.tint)
            }
            .accessibilityElement(children: .contain)
        }
    }

    /// One accent swatch: a real, individually hittable button with at least a
    /// 44×44pt target, a visible selection ring, a spoken name, and the selected
    /// trait. The swatch fill uses the accent's light/dark pair, and the check is
    /// drawn in a contrast color picked from the accent's luminance (not fixed
    /// white).
    ///
    /// `.borderless` (not `.plain`) keeps each button's tap target independent
    /// inside the Form row, and the explicit `contentShape` stops neighboring
    /// swatches' hit areas from overlapping.
    private func accentSwatch(_ accent: AppAccent) -> some View {
        let isSelected = themeSettings.accent == accent
        return Button {
            themeSettings.accent = accent
        } label: {
            Circle()
                .fill(accent.color(for: colorScheme))
                .frame(width: 32, height: 32)
                .overlay {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(accent.onAccentColor(for: colorScheme))
                    }
                }
                .overlay {
                    Circle()
                        .strokeBorder(.primary.opacity(isSelected ? 0.5 : 0.15), lineWidth: isSelected ? 2 : 1)
                }
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(accent.displayName)
        .accessibilityLabel(accent.displayName)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityIdentifier("accent-\(accent.rawValue)")
    }

    /// Optional workspaces hidden from the tab bar until explicitly enabled.
    private var featuresSection: some View {
        Section("Features") {
            Toggle("Show Gallery (Photos)", isOn: $galleryEnabled)
                .accessibilityIdentifier("feature-gallery-toggle")
            Text("When off, the Gallery tab is hidden from the top tab bar.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Allow Photos Library Access") {
                Task {
                    photosLibraryReadable = await SystemPhotoLibrary.requestAccess()
                    photosLibraryAllowed = SystemPhotoLibrary.canAddPhotos
                    photosLibraryNeedsSettings = !photosLibraryReadable
                        && (SystemPhotoLibrary.isAddOnly
                            || SystemPhotoLibrary.authorizationStatus == .denied)
                }
            }
            .disabled(photosLibraryReadable)
            .accessibilityIdentifier("photos-library-access-button")
            if photosLibraryNeedsSettings {
                Button("Open Settings") {
                    SystemPhotoLibrary.openAppSettings()
                }
            }
            Text(photosAccessCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear {
            photosLibraryAllowed = SystemPhotoLibrary.canAddPhotos
            photosLibraryReadable = SystemPhotoLibrary.canReadPhotos
            photosLibraryNeedsSettings = SystemPhotoLibrary.isAddOnly
                || (!photosLibraryReadable && SystemPhotoLibrary.authorizationStatus == .denied)
        }
    }

    /// Explains the current Photos grant: full access, add-only, or none.
    private var photosAccessCaption: String {
        if photosLibraryReadable {
            return "Generated images are saved to an “AI Generated” album in the Photos app. You can also import from your library."
        }
        if photosLibraryAllowed {
            return "The app can save photos but cannot read your library. Import still works from the system picker. Open Settings and choose Full Access to file images into albums."
        }
        return "Allow access so generated images can be stored in Photos. Importing from the Photos picker does not require library access."
    }

    /// Reports the active persistence mode and nudges toward iCloud when local.
    private var storageSection: some View {
        Section("Storage") {
            LabeledContent("Mode", value: storageMode == .cloudKit ? "iCloud (CloudKit)" : "Local")
            LabeledContent("iCloud Account", value: ICloudAvailability.isAccountSignedIn ? "Signed In" : "Not Signed In")
            if storageMode == .cloudKit {
                LabeledContent("Setup", value: syncMonitor.lastSetup ?? "—")
                LabeledContent("Last Download", value: syncMonitor.lastImport ?? "—")
                LabeledContent("Last Upload", value: syncMonitor.lastExport ?? "—")
                if let error = syncMonitor.lastError {
                    Text("Sync error: \(error)")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                Button {
                    syncMonitor.requestSync()
                } label: {
                    Label("Sync Now", systemImage: "arrow.triangle.2.circlepath.icloud")
                }
                .accessibilityIdentifier("sync-now-button")
            }
            if storageMode == .local {
                if !ICloudAvailability.isAccountSignedIn {
                    Text("Sign into iCloud on this device for cross-device sync.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !ICloudAvailability.hasICloudContainerEntitlement {
                    Text("This build is missing the iCloud container entitlement. Reinstall from Xcode with CloudKit enabled on the App ID.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("CloudKit could not be opened at launch, so data stays on this device. Force-quit and reopen the app after enabling iCloud for \(AppBranding.appName).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Shown when this device has on-device AI to offer. Ineligible hardware with
    /// no MLX hides the whole section. Apple On-Device stays when Intelligence is
    /// off or still preparing (no Download). A supported device with nothing
    /// downloaded still lists each MLX model with Download.
    private var localModelSection: some View {
        Section("Local Models") {
            appleFoundationRows

            if OnDeviceLanguageModelSupport.shouldOfferLocalMLX(manager: localModelManager) {
                Text(ModelCatalogService.memorySummaryText())
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(localModelStatuses) { status in
                    localModelRow(status)
                }
            }

            if let llmService {
                LabeledContent("Active backend", value: backendLabel(for: llmService))
                LabeledContent("Status", value: llmService.loadStatus)
            }
        }
        .alert(
            LocalModelDownloadPolicy.deleteAlertTitle(
                displayName: modelPendingDelete?.option.displayName ?? ""
            ),
            isPresented: Binding(
                get: { modelPendingDelete != nil },
                set: { if !$0 { modelPendingDelete = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                if let status = modelPendingDelete {
                    deleteModel(status)
                }
                modelPendingDelete = nil
            }
            Button("Cancel", role: .cancel) {
                modelPendingDelete = nil
            }
        } message: {
            Text(
                LocalModelDownloadPolicy.deleteAlertMessage(
                    sizeText: deleteSizeText(modelPendingDelete)
                )
            )
        }
    }

    @ViewBuilder
    private var appleFoundationRows: some View {
        let availability = OnDeviceLanguageModelSupport.appleFoundationAvailability
        if LocalOnDevicePolicy.shouldOfferAppleFoundation(
            OnDeviceLanguageModelSupport.liveFacts
        ) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(AppleFoundationModel.displayName)
                        Text(LocalOnDevicePolicy.appleFoundationUserMessage(availability))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if availability == .available {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
                Text(LocalOnDevicePolicy.appleOnDeviceCapabilityNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier(appleFoundationAccessibilityID(availability))
        }
    }

    private func appleFoundationAccessibilityID(_ availability: AppleFoundationAvailability) -> String {
        switch availability {
        case .available: "apple-on-device-ready"
        case .appleIntelligenceNotEnabled: "apple-on-device-enable-intelligence"
        case .modelNotReady: "apple-on-device-getting-ready"
        case .deviceNotEligible, .unsupportedOS: "apple-on-device-hidden"
        }
    }

    /// One row: a single status line and one isolated button (not a Form row action).
    @ViewBuilder
    private func localModelRow(_ status: LocalModelStatus) -> some View {
        let presentation = localModelPresentation(for: status)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(status.option.displayName)
                    HStack(spacing: 6) {
                        if presentation.showsLoadedCheckmark {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .accessibilityHidden(true)
                        }
                        if presentation.showsProgress {
                            ProgressView(value: presentation.progress)
                                .frame(maxWidth: 88)
                        }
                        Text(presentation.statusLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if !status.fitsMemoryBudget {
                    Text("Unavailable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let action = presentation.action {
                    Button(action.title, role: action.isDestructive ? .destructive : nil) {
                        handleLocalModelAction(action, status: status)
                    }
                    .isolatedFormButton()
                    .disabled(downloadingModelID != nil && action != .cancel)
                    .accessibilityIdentifier("local-model-\(action.rawValue)-\(status.id)")
                }
            }
        }
    }

    private func localModelPresentation(for status: LocalModelStatus) -> LocalModelRowPresentation {
        guard status.fitsMemoryBudget else {
            return LocalModelRowPresentation(
                statusLine: String(
                    format: "Requires ~%.1f GB — too large for this device",
                    status.option.estimatedMemoryGB
                )
            )
        }
        let manifest = LocalModelDownloadPolicy.manifest(forCatalogID: status.id)
        return LocalModelDownloadPolicy.present(
            LocalModelRowInput(
                catalogID: status.id,
                displayName: status.option.displayName,
                manifestSizeText: manifest?.sizeText
                    ?? String(format: "%.1f GB", status.option.estimatedMemoryGB),
                completeness: status.completeness,
                downloadedSizeBytes: status.sizeBytes,
                isDownloading: downloadingModelID == status.id,
                downloadProgress: downloadingModelID == status.id ? downloadProgress : nil,
                isLoading: loadingModelID == status.id
                    || llmService?.loadingLocalModelID == status.id,
                isLoaded: llmService?.loadedLocalModelID == status.id,
                errorMessage: rowErrors[status.id]
            )
        )
    }

    private func handleLocalModelAction(_ action: LocalModelRowAction, status: LocalModelStatus) {
        switch action {
        case .download:
            startDownload(status.id, wipeFirst: false)
        case .downloadAgain, .tryAgain:
            if action == .tryAgain, status.completeness == .complete {
                Task { await loadLocalModel(status.id) }
            } else {
                startDownload(status.id, wipeFirst: true)
            }
        case .cancel:
            cancelDownload(status.id)
        case .delete:
            modelPendingDelete = status
        }
    }

    private func deleteSizeText(_ status: LocalModelStatus?) -> String {
        guard let status else { return "" }
        if let bytes = status.sizeBytes, bytes > 0 {
            return LocalModelDownloadPolicy.sizeText(bytes: bytes)
        }
        return LocalModelDownloadPolicy.manifest(forCatalogID: status.id)?.sizeText
            ?? String(format: "%.1f GB", status.option.estimatedMemoryGB)
    }

    /// Mail + calendar connections: Google Auth is one adapter covering both Gmail
    /// and Google Calendar; Apple Mail (macOS) and on-device calendars are the others.
    private var mailAccountsSection: some View {
        Section("Accounts & Connections") {
            Text("Connect Gmail accounts to read mail and calendar securely over OAuth. Create an OAuth Client ID (iOS or Desktop) in Google Cloud Console with Gmail + Calendar APIs enabled, then paste it below. A Client ID is not the same as Google approving the app: if the OAuth consent screen is still in Testing, Google expires the login after 7 days. Publish the app (APIs & Services → OAuth consent screen) for a personal long-lived login. Gmail scopes are restricted, so letting other people use the app requires Google’s verification process.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Google OAuth Client ID", text: $mailAccountStore.oauthClientID)
                .workspaceSettingsField()
                .accessibilityIdentifier("google-oauth-client-id-field")

            ForEach(connectionManager.connections) { connection in
                HStack {
                    Label(connection.displayName, systemImage: connection.kind.systemImage)
                    Spacer()
                    Text(connectionStatus(connection))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if connection.kind == .google {
                        googleAccountButtons(connection)
                    }
                }
            }

            Button(isAddingMailAccount ? "Connecting…" : "Add Gmail Account") {
                Task { await addGoogleAccount() }
            }
            .disabled(isAddingMailAccount || !mailAccountStore.isOAuthConfigured)
            .accessibilityIdentifier("add-gmail-account-settings-button")

            if let mailAccountError {
                StatusMessage(kind: .error, text: mailAccountError)
            }
            if let googleCalendarSyncResult {
                StatusMessage(kind: .success, text: googleCalendarSyncResult)
            }
        }
    }

    private func connectionStatus(_ connection: WorkspaceConnection) -> String {
        if connection.kind == .google {
            return connection.isConnected ? "Gmail + Calendar" : "Needs sign-in"
        }
        if connection.capabilities.contains(.emailAndCalendar) {
            return "Email + Calendar"
        }
        if connection.capabilities.contains(.email) { return "Email" }
        return "Calendar"
    }

    @ViewBuilder
    private func googleAccountButtons(_ connection: WorkspaceConnection) -> some View {
        let accountID = String(connection.id.dropFirst("google:".count))
        if let account = mailAccountStore.accounts.first(where: { $0.id == accountID }) {
            if !mailAccountStore.isSignedIn(account) {
                Button("Sign In") {
                    Task { await reconnectGoogleAccount(account) }
                }
                .buttonStyle(.borderless)
                .disabled(isAddingMailAccount)
                .accessibilityIdentifier("reconnect-account-\(account.id)")
            }
            Button(role: .destructive) {
                connectionManager.disconnect(id: connection.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("remove-account-\(account.id)")
        }
    }

    /// Google Calendar sync: imports the next 90 days using the first connected
    /// Gmail account's credentials (also refreshed automatically when the AI lists events).
    private var googleCalendarSection: some View {
        Section("Google Calendar") {
            if let account = mailAccountStore.primaryGoogleAccount {
                LabeledContent("Account", value: account.label)
                Button(isSyncingGoogleCalendar ? "Syncing..." : "Sync Google Calendar (90 days)") {
                    Task { await syncGoogleCalendar() }
                }
                .disabled(isSyncingGoogleCalendar || !mailAccountStore.isSignedIn(account))
            } else {
                Text("Connect a Gmail account above to sync Google Calendar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let googleCalendarSyncResult {
                StatusMessage(kind: .success, text: googleCalendarSyncResult)
            }
            if let googleCalendarSyncError {
                StatusMessage(kind: .error, text: googleCalendarSyncError)
            }
        }
    }

    /// Gemini configuration: API key/model and a shortcut to wire Gemini in as
    /// the remote provider via its OpenAI-compatible endpoint.
    private var geminiSection: some View {
        Section("Gemini") {
            SecureField("Gemini API Key", text: $googleSettings.geminiAPIKey)
                .workspaceSettingsField()

            TextField("Gemini Model", text: $googleSettings.geminiModel)
                .workspaceSettingsField()

            Button("Use Gemini for Remote API") {
                googleSettings.applyGeminiToProviderSettings(providerSettings)
            }
            .disabled(!googleSettings.isGeminiConfigured)

            Text("Uses Google's OpenAI-compatible endpoint at generativelanguage.googleapis.com.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Global default plus per-tab overrides for AI workspaces.
    private var featureModelDefaultsSection: some View {
        Group {
            Section("Default Model (All Tabs)") {
                Text("Applies to every AI tab unless that tab has its own override below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                #if os(iOS)
                settingsModelLink(
                    route: .global,
                    title: "All tabs",
                    accessibilityIdentifier: "feature-model-global-picker"
                )
                #else
                FeatureDefaultModelPickerRows(
                    title: "All tabs",
                    selectionKey: globalDefaultBinding,
                    providerSettings: providerSettings,
                    accessibilityIdentifier: "feature-model-global-picker",
                    downloadedLocalModelIDs: downloadedLocalModelIDs,
                    onReset: { featureModelSettings.clearGlobalSelectionKey() },
                    resetLabel: "Use Controller Agent Default",
                    resetDisabled: !featureModelSettings.hasGlobalOverride,
                    optionsStyle: .expanded
                )
                #endif
            }

            Section("Default Models by Tab") {
                Text("Optional overrides for individual tabs. Tabs without an override use the global default above. Each tab picker lists the 10 newest chat models by release date, newest first. Compare uses its own searchable list and has no default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                #if os(iOS)
                ForEach(WorkspaceFeature.allCases) { feature in
                    settingsModelLink(
                        route: .feature(feature),
                        title: feature.title,
                        accessibilityIdentifier: "feature-model-\(feature.rawValue)-picker"
                    )
                }
                #else
                ForEach(WorkspaceFeature.allCases) { feature in
                    FeatureDefaultModelPickerRows(
                        title: feature.title,
                        selectionKey: featureDefaultBinding(for: feature),
                        providerSettings: providerSettings,
                        accessibilityIdentifier: "feature-model-\(feature.rawValue)-picker",
                        downloadedLocalModelIDs: downloadedLocalModelIDs,
                        onReset: { featureModelSettings.clearSelectionKey(for: feature) },
                        resetLabel: "Use Global Default",
                        resetDisabled: !featureModelSettings.hasFeatureOverride(for: feature),
                        optionsStyle: .collapsed,
                        inheritsGlobalOptions: !featureModelSettings.hasFeatureOverride(for: feature)
                    )
                }
                #endif
            }
        }
    }

    #if os(iOS)
    /// Current choice as its own Form row; Options on the next row.
    /// `@ViewBuilder` so Form flattens them — a `VStack` would fire both on one tap.
    @ViewBuilder
    private func settingsModelLink(
        route: SettingsModelPickerRoute,
        title: String,
        accessibilityIdentifier: String
    ) -> some View {
        let key = resolvedSelectionKey(for: route)
        let optionsStyle: ModelPickerOptionsStyle = {
            switch route {
            case .global: .expanded
            case .feature: .collapsed
            }
        }()
        let isEditable: Bool = {
            switch route {
            case .global:
                true
            case .feature(let feature):
                ModelOptionsFormatting.shouldShowEditableOptions(
                    hasOwnModelSelection: featureModelSettings.hasFeatureOverride(for: feature)
                )
            }
        }()
        NavigationLink(value: AIModelsDestination.model(route)) {
            LabeledContent(title, value: modelChoiceLabel(for: key))
        }
        .accessibilityIdentifier(accessibilityIdentifier)
        ModelPickerOptionsView(
            selectionKey: key,
            style: optionsStyle,
            isEditable: isEditable
        )
    }

    private func resolvedSelectionKey(for route: SettingsModelPickerRoute) -> String {
        switch route {
        case .global:
            featureModelSettings.resolvedGlobalSelectionKey(
                providerSettings: providerSettings,
                agentSettings: agentRegistrySettings
            )
        case .feature(let feature):
            featureModelSettings.resolvedSelectionKey(
                for: feature,
                providerSettings: providerSettings,
                agentSettings: agentRegistrySettings
            )
        }
    }

    private func modelChoiceLabel(for selectionKey: String) -> String {
        settingsModelChoices.first { $0.selectionKey == selectionKey }?.pickerLabel
            ?? ConfiguredModelRegistry.choice(
                forSelectionKey: selectionKey,
                providerSettings: providerSettings
            )?.pickerLabel
            ?? "Select a model"
    }

    private func modelPickerTitle(for route: SettingsModelPickerRoute) -> String {
        switch route {
        case .global: "All Tabs"
        case .feature(let feature): feature.title
        }
    }

    private func modelChoicesForRoute(_ route: SettingsModelPickerRoute) -> [ConfiguredModelChoice] {
        ConfiguredModelRegistry.pickerChoices(
            providerSettings: providerSettings,
            downloadedLocalModelIDs: downloadedLocalModelIDs,
            selectionKey: resolvedSelectionKey(for: route),
            offerLocalMLX: OnDeviceLanguageModelSupport.shouldOfferLocalMLX(manager: localModelManager),
            offerAppleFoundation: OnDeviceLanguageModelSupport.shouldOfferAppleFoundation
        )
    }

    private func modelSelectionBinding(for route: SettingsModelPickerRoute) -> Binding<String> {
        switch route {
        case .global: globalDefaultBinding
        case .feature(let feature): featureDefaultBinding(for: feature)
        }
    }

    private func modelResetLabel(for route: SettingsModelPickerRoute) -> String {
        switch route {
        case .global: "Use Controller Agent Default"
        case .feature: "Use Global Default"
        }
    }

    private func modelResetDisabled(for route: SettingsModelPickerRoute) -> Bool {
        switch route {
        case .global: !featureModelSettings.hasGlobalOverride
        case .feature(let feature): !featureModelSettings.hasFeatureOverride(for: feature)
        }
    }

    private func resetModelSelection(_ route: SettingsModelPickerRoute) {
        switch route {
        case .global: featureModelSettings.clearGlobalSelectionKey()
        case .feature(let feature): featureModelSettings.clearSelectionKey(for: feature)
        }
    }
    #endif

    /// Downloaded local MLX ids already loaded for the Local Models section.
    /// Shared with every feature picker so scrolling does not rescan the cache.
    /// Empty when this device cannot run MLX, so pickers never list Llama there.
    private var downloadedLocalModelIDs: Set<String> {
        guard OnDeviceLanguageModelSupport.shouldOfferLocalMLX(manager: localModelManager) else {
            return []
        }
        return Set(localModelStatuses.filter(\.isDownloaded).map(\.id))
    }

    private var globalDefaultBinding: Binding<String> {
        Binding(
            get: {
                featureModelSettings.resolvedGlobalSelectionKey(
                    providerSettings: providerSettings,
                    agentSettings: agentRegistrySettings
                )
            },
            set: { newValue in
                featureModelSettings.setGlobalSelectionKey(newValue)
            }
        )
    }

    private func featureDefaultBinding(for feature: WorkspaceFeature) -> Binding<String> {
        Binding(
            get: {
                featureModelSettings.resolvedSelectionKey(
                    for: feature,
                    providerSettings: providerSettings,
                    agentSettings: agentRegistrySettings
                )
            },
            set: { newValue in
                featureModelSettings.setSelectionKey(newValue, for: feature)
            }
        )
    }

    /// Lets the user customize the conversational Chat workspace's system prompt,
    /// distinct from the Research synthesis prompt. Includes a reset to the default.
    private var chatSection: some View {
        Section("Chat") {
            Text("This system prompt sets the assistant's voice in the Chat workspace. It's separate from Research, which uses its own report-style prompt.")
                .font(.caption)
                .foregroundStyle(.secondary)

            #if os(iOS)
            NavigationLink(value: AIModelsDestination.chatPrompt) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Chat system prompt")
                    Text(chatPromptSettings.chatSystemPrompt)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            .accessibilityIdentifier("chat-system-prompt-field")
            #else
            TextField(
                "Chat system prompt",
                text: $chatPromptSettings.chatSystemPrompt,
                axis: .vertical
            )
            .lineLimit(4...12)
            .workspaceSettingsField()
            .accessibilityIdentifier("chat-system-prompt-field")

            Button("Reset to Default") {
                chatPromptSettings.chatSystemPrompt = ChatPromptSettings.defaultChatSystemPrompt
            }
            .disabled(chatPromptSettings.chatSystemPrompt == ChatPromptSettings.defaultChatSystemPrompt)
            .accessibilityIdentifier("reset-chat-system-prompt-button")
            #endif
        }
    }

    /// Hides the external CLI-agent controls (Claude / Codex / Cursor picker,
    /// availability rows, and the Cursor CLI path field). The registry and its
    /// stored settings keep working; only the controls are hidden. Flip this to
    /// re-show them if the agent integrations become user-facing again.
    private static let showsAgentControllerControls = false

    /// Multi-agent orchestration: controller selection, registered agents, voice.
    /// With the agent controls hidden this renders as a plain "Voice" section.
    private var agentControllerSection: some View {
        Section(Self.showsAgentControllerControls ? "Agents & Controller" : "Voice") {
            if Self.showsAgentControllerControls {
                Text("Configure the controller AI and registered agents. The active controller is used when no global or per-tab model default is set above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let agentController {
                    Picker("Controller AI", selection: $agentRegistrySettings.controllerAgentID) {
                        ForEach(agentController.registry.allAdapters.map(\.attributes), id: \.id) { attr in
                            Text(attr.displayName).tag(attr.id)
                        }
                    }
                    .accessibilityIdentifier("controller-agent-picker")
                    .onChange(of: agentRegistrySettings.controllerAgentID) { _, _ in
                        applyAgentDefaultModel()
                    }

                    LabeledContent("Active controller", value: agentRegistrySettings.resolvedControllerID)

                    ForEach(agentController.registry.allAdapters.map(\.attributes), id: \.id) { attr in
                        let adapter = agentController.registry.adapter(id: attr.id)
                        let available = adapter?.isAvailable ?? false
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(attr.displayName)
                                Text(attr.tags.joined(separator: ", "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(available ? "Available" : "Unavailable")
                                .font(.caption)
                                .foregroundStyle(available ? .secondary : .tertiary)
                        }
                    }

                    #if os(macOS)
                    TextField("Cursor CLI path", text: $agentRegistrySettings.cursorCLIPath)
                        .workspaceSettingsField()
                    #endif
                }
            }

            SpokenReplyPickerRows(
                agentRegistrySettings: agentRegistrySettings,
                providerSettings: providerSettings
            )
        }
    }

    private var voiceAdvancedSection: some View {
        Section("Advanced") {
            Text("If the app closed while talking in the car, share this log so we can see the last audio events.")
                .font(.caption)
                .foregroundStyle(.secondary)
            AudioDebugLogShareLink()
        }
    }

    /// Controls whether the AI assistant's tools may read the user's private
    /// One Privacy section per app tab. Switches stay on their stored keys;
    /// the footer is `PrivacyDisclosures`.
    @ViewBuilder
    private func privacySection(for tab: PrivacyTab) -> some View {
        Section {
            switch tab {
            case .chats:
                Toggle(ChatWebSearchPolicy.privacyToggleTitle, isOn: $allowChatWebSearch)
                    .accessibilityIdentifier("ai-allow-chat-web-search-toggle")
                if allowChatWebSearch {
                    chatWebSearchEnginePicker
                }
            case .email:
                Toggle("Allow AI to access Email", isOn: $allowAIEmailAccess)
                    .accessibilityIdentifier("ai-allow-email-toggle")
            case .calendar:
                Toggle("Allow AI to access Calendar", isOn: $allowAICalendarAccess)
                    .accessibilityIdentifier("ai-allow-calendar-toggle")
                Text("Calendar also requires system permission (Settings → \(AppBranding.appName) → Calendars on iOS) and, for Google Calendar, a connected Gmail account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            default:
                EmptyView()
            }
        } header: {
            Label(tab.title, systemImage: tab.systemImage)
        } footer: {
            Text(
                PrivacyDisclosures.disclosure(
                    for: tab,
                    chatWebSearchAllowed: allowChatWebSearch,
                    chatEngine: ChatWebSearchEngine.resolvedSelectable(chatWebSearchEngine.rawValue)
                )
            )
        }
        .accessibilityIdentifier("privacy-section-\(tab.rawValue)")
    }

    @ViewBuilder
    private var chatWebSearchEnginePicker: some View {
        Picker("Search engine", selection: $chatWebSearchEngine) {
            ForEach(ChatWebSearchEngine.primaryCases, id: \.self) { engine in
                Text(engine.pickerTitle).tag(engine)
            }
            if chatWebSearchEngine.isAdvanced {
                Text(chatWebSearchEngine.pickerTitle).tag(chatWebSearchEngine)
            }
        }
        .accessibilityIdentifier("chat-web-search-engine-picker")

        if chatWebSearchEngine == .brave {
            braveSearchKeyRow
        }

        DisclosureGroup("Advanced", isExpanded: $showAdvancedSearchEngines) {
            ForEach(ChatWebSearchEngine.advancedCases, id: \.self) { engine in
                Button {
                    chatWebSearchEngine = engine
                } label: {
                    HStack {
                        Image(systemName: chatWebSearchEngine == engine ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(chatWebSearchEngine == engine ? Color.accentColor : Color.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(engine.pickerTitle)
                                .foregroundStyle(.primary)
                            if engine == .brave {
                                Text(ChatWebSearchPolicy.braveAttributionLine)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                }
                .accessibilityIdentifier("chat-web-search-engine-\(engine.rawValue)")
            }

            Text("My Search Server is a SearXNG instance you run yourself.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if chatWebSearchEngine == .searchServer {
                HStack {
                    TextField("https://searx.example", text: $searxBaseURL)
                        .workspaceSettingsField()
                        #if os(iOS)
                        .keyboardType(.URL)
                        #endif
                        .accessibilityIdentifier("searx-base-url-field")
                    Button(isProbingSearchServer ? "Testing…" : "Test") {
                        Task { await probeSearchServer() }
                    }
                    .disabled(isProbingSearchServer || searxBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("searx-test-button")
                }
                Text(SearXNGSearchCodec.helpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let searchServerProbe {
                    searchServerProbeRow(searchServerProbe)
                }
            }
        }
        .onAppear {
            loadBraveSearchKeyIfNeeded()
            applyPendingSearchFocusIfNeeded()
            if chatWebSearchEngine.isAdvanced {
                showAdvancedSearchEngines = true
            }
        }
        .onChange(of: braveSearchAPIKey) { _, newValue in
            guard didLoadBraveSearchKey else { return }
            RemoteAPIKeyStore().setAPIKey(newValue, for: AIDataAccess.braveSearchKeyAccount)
        }
        .onChange(of: chatWebSearchEngine) { _, newValue in
            if newValue.isAdvanced {
                showAdvancedSearchEngines = true
            }
        }
        .onChange(of: pendingFocus) { _, _ in
            applyPendingSearchFocusIfNeeded()
        }
    }

    @ViewBuilder
    private var braveSearchKeyRow: some View {
        HStack(alignment: .center, spacing: 8) {
            SecureField("Brave Search API key", text: $braveSearchAPIKey)
                .workspaceSettingsField()
                .focused($focusedSearchField, equals: .braveSearchKey)
                .accessibilityIdentifier("brave-search-api-key-field")
            if let signup = BraveSearchCodec.signupURL {
                Link(BraveSearchCodec.getFreeKeyTitle, destination: signup)
                    .accessibilityIdentifier("brave-search-get-key-link")
            }
            Button(isProbingBrave ? "Testing…" : BraveSearchCodec.testButtonTitle) {
                Task { await probeBraveSearch() }
            }
            .disabled(isProbingBrave || braveSearchAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("brave-search-test-button")
        }
        Text(BraveSearchCodec.cardFootnote)
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("brave-search-card-footnote")
        if let braveProbe {
            braveProbeRow(braveProbe)
        }
    }

    private func applyPendingSearchFocusIfNeeded() {
        guard pendingFocus == .braveSearchKey else { return }
        chatWebSearchEngine = .brave
        loadBraveSearchKeyIfNeeded()
        DispatchQueue.main.async {
            focusedSearchField = .braveSearchKey
            pendingFocus = nil
        }
    }

    @ViewBuilder
    private func searchServerProbeRow(_ status: SearXNGProbeStatus) -> some View {
        switch status {
        case .reachable:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel(SearXNGSearchCodec.reachableMessage)
                .accessibilityIdentifier("searx-probe-success")
        case .unreachable:
            Text(SearXNGSearchCodec.unreachableMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("searx-probe-unreachable")
        case .needsJSONOrLimiter:
            Text(SearXNGSearchCodec.needsJSONOrLimiterMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("searx-probe-json-limiter")
        }
    }

    private func loadBraveSearchKeyIfNeeded() {
        guard !didLoadBraveSearchKey else { return }
        braveSearchAPIKey = RemoteAPIKeyStore().apiKey(for: AIDataAccess.braveSearchKeyAccount)
        didLoadBraveSearchKey = true
    }

    @ViewBuilder
    private func braveProbeRow(_ status: BraveSearchCodec.ProbeStatus) -> some View {
        switch status {
        case .reachable:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel(BraveSearchCodec.probeMessage(status))
                .accessibilityIdentifier("brave-probe-success")
        case .missingKey, .rejected, .unreachable:
            Text(BraveSearchCodec.probeMessage(status))
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("brave-probe-\(String(describing: status))")
        }
    }

    private func probeBraveSearch() async {
        isProbingBrave = true
        defer { isProbingBrave = false }
        if let service = webSearchService as? WebSearchService {
            braveProbe = await service.probeBraveSearch(apiKey: braveSearchAPIKey)
            return
        }
        let key = braveSearchAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        braveProbe = BraveSearchCodec.mapProbe(statusCode: nil, error: nil, hasKey: !key.isEmpty)
    }

    private func probeSearchServer() async {
        isProbingSearchServer = true
        defer { isProbingSearchServer = false }
        if let service = webSearchService as? WebSearchService {
            searchServerProbe = await service.probeSearchServer(baseURL: searxBaseURL)
            return
        }
        guard let url = SearXNGSearchCodec.probeURL(baseURL: searxBaseURL) else {
            searchServerProbe = .unreachable
            return
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            searchServerProbe = SearXNGSearchCodec.mapProbe(
                statusCode: http?.statusCode,
                contentType: http?.value(forHTTPHeaderField: "Content-Type"),
                body: data,
                error: nil
            )
        } catch {
            searchServerProbe = SearXNGSearchCodec.mapProbe(
                statusCode: nil,
                contentType: nil,
                body: Data(),
                error: error
            )
        }
    }

    /// Lets the user verify the web-search backend by running a test query and
    /// listing the returned results.
    private var webSearchSection: some View {
        Section("Web Search") {
            TextField("Test query", text: $webSearchQuery)
                .workspaceSettingsField()

            Button(isSearchingWeb ? "Searching..." : "Test Web Search") {
                Task { await runWebSearch() }
            }
            .disabled(isSearchingWeb || webSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if let webSearchError {
                StatusMessage(kind: .error, text: webSearchError)
            }

            ForEach(webSearchResults) { result in
                VStack(alignment: .leading, spacing: 4) {
                    Text(result.title)
                        .font(.headline)
                    Text(result.url)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(result.snippet)
                        .font(.caption)
                }
            }
        }
    }

    /// Exports and imports chats, documents, notes, research, and related
    /// workspace data. Email drafts and calendar events are omitted on purpose.
    private var workspaceBackupSection: some View {
        Section("Workspace Backup") {
            Text("Export chats, research, documents, notes, memories, gallery, comparisons, tasks, and agent work to a zip file. Email and calendar are not included. Import is additive unless you choose to erase existing content first.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button(isPreparingExport ? "Preparing export..." : "Export workspace...") {
                Task { await prepareWorkspaceExport() }
            }
            .disabled(isPreparingExport || isWorkspaceImporting || repositories == nil)
            .accessibilityIdentifier("export-workspace-button")

            if isPreparingExport {
                ProgressView(value: exportProgress) {
                    Text(exportStage)
                }
            }

            if let exportResultMessage {
                StatusMessage(kind: .success, text: exportResultMessage)
            }

            if let exportError {
                StatusMessage(kind: .error, text: exportError)
            }

            Toggle("Erase existing content before import", isOn: $eraseExistingOnImport)
                .accessibilityIdentifier("erase-existing-on-import-toggle")

            if eraseExistingOnImport {
                Text("Chats, documents, notes, memories, gallery, research, tasks, and agent work currently in this workspace will be deleted, then replaced by the archive. Email and calendar are not affected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button(isWorkspaceImporting ? "Importing..." : "Import workspace...") {
                showWorkspaceImportPicker = true
            }
            .disabled(isPreparingExport || isWorkspaceImporting || repositories == nil)
            .accessibilityIdentifier("import-workspace-button")

            if isWorkspaceImporting {
                ProgressView(value: workspaceImportProgress) {
                    Text(workspaceImportStage)
                }
            }

            if let workspaceImportResultMessage {
                StatusMessage(kind: .success, text: workspaceImportResultMessage)
            }

            if let workspaceImportError {
                StatusMessage(kind: .error, text: workspaceImportError)
            }
        }
    }

    /// Imports a Notion Markdown export (folder or .zip) into documents, with
    /// staged progress and an imported-counts summary.
    private var notionImportSection: some View {
        Section("Notion Import") {
            Text("Import a Notion Markdown export folder or .zip. Pages become documents; database CSV exports become markdown tables. Folder hierarchy is preserved in document titles.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button(isNotionImporting ? "Importing..." : "Choose Notion export...") {
                showNotionImportPicker = true
            }
            .disabled(isNotionImporting || repositories == nil)
            .accessibilityIdentifier("import-notion-export-button")

            if isNotionImporting {
                ProgressView(value: notionImportProgress) {
                    Text(notionImportStage)
                }
            }

            if let notionImportResultMessage {
                StatusMessage(kind: .success, text: notionImportResultMessage)
            }

            if let notionImportError {
                StatusMessage(kind: .error, text: notionImportError)
            }
        }
    }

    /// App identity and version footer.
    private var aboutSection: some View {
        Section("About") {
            LabeledContent("App", value: AppBranding.appName)
            LabeledContent("Company", value: AppBranding.companyName)
            LabeledContent("Version", value: AnAIOdysseyCore.version)
            #if os(iOS)
            NavigationLink {
                AcknowledgementsView()
            } label: {
                Text("Acknowledgements")
            }
            .accessibilityIdentifier("settings-acknowledgements")
            #else
            Button("Acknowledgements") { showingAcknowledgements = true }
                .accessibilityIdentifier("settings-acknowledgements")
                .sheet(isPresented: $showingAcknowledgements) {
                    NavigationStack {
                        AcknowledgementsView()
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button("Done") { showingAcknowledgements = false }
                                }
                            }
                    }
                    .frame(minWidth: 560, minHeight: 640)
                }
            #endif
        }
    }

    /// Derives a human-readable backend label (MLX / Remote / Mock) from the
    /// service's capabilities and the current remote configuration.
    private func backendLabel(for llmService: any LLMServiceProtocol) -> String {
        if let selectable = llmService as? any LLMBackendSelectable {
            return selectable.activeBackendLabel
        }
        if llmService.usesMLXBackend {
            return "MLX"
        }
        if providerSettings.isRemoteConfigured, llmService.isModelLoaded {
            return "Remote"
        }
        return "Mock"
    }

    /// Re-reads the on-disk download state for every local model.
    private func reloadLocalModelStatuses() {
        guard OnDeviceLanguageModelSupport.shouldOfferLocalMLX(manager: localModelManager) else {
            localModelStatuses = []
            return
        }
        localModelStatuses = localModelManager?.statuses() ?? []
    }

    /// Rebuilds the shared model list used by the AI Models page.
    ///
    /// Called when the page appears and when downloads or remote catalogs change,
    /// not while the form is scrolling.
    private func reloadSettingsModelChoices() {
        let choices = ConfiguredModelRegistry.availableChoices(
            providerSettings: providerSettings,
            downloadedLocalModelIDs: downloadedLocalModelIDs,
            offerLocalMLX: OnDeviceLanguageModelSupport.shouldOfferLocalMLX(manager: localModelManager),
            offerAppleFoundation: OnDeviceLanguageModelSupport.shouldOfferAppleFoundation
        )
        if choices != settingsModelChoices {
            settingsModelChoices = choices
        }
    }

    /// Downloads a model's weights, streaming progress and refreshing state on completion.
    private func startDownload(_ modelID: String, wipeFirst: Bool) {
        downloadTask?.cancel()
        downloadTask = Task {
            await downloadModel(modelID, wipeFirst: wipeFirst)
        }
    }

    private func cancelDownload(_ modelID: String) {
        downloadTask?.cancel()
        downloadTask = nil
        downloadingModelID = nil
        downloadProgress = nil
        rowErrors[modelID] = nil
        do {
            try localModelManager?.discardPartialDownload(modelID)
        } catch {
            rowErrors[modelID] = error.localizedDescription
        }
        reloadLocalModelStatuses()
    }

    private func downloadModel(_ modelID: String, wipeFirst: Bool) async {
        guard let manager = localModelManager else { return }
        downloadingModelID = modelID
        downloadProgress = 0
        rowErrors[modelID] = nil
        defer {
            if downloadingModelID == modelID {
                downloadingModelID = nil
                downloadProgress = nil
            }
            reloadLocalModelStatuses()
            reloadSettingsModelChoices()
        }
        do {
            if wipeFirst {
                try manager.discardPartialDownload(modelID)
            }
            try await manager.download(modelID) { fraction in
                downloadProgress = fraction
            }
        } catch is CancellationError {
            try? manager.discardPartialDownload(modelID)
        } catch {
            rowErrors[modelID] = error.localizedDescription
        }
    }

    private func loadLocalModel(_ modelID: String) async {
        guard let llmService else { return }
        loadingModelID = modelID
        rowErrors[modelID] = nil
        defer { loadingModelID = nil }
        WorkspaceModelSelection.apply(
            selectionKey: ConfiguredModelRegistry.selectionKey(
                modelID: modelID,
                backend: .localMLX
            ),
            to: llmService,
            providerSettings: providerSettings
        )
        do {
            try await llmService.loadSelectedModel()
        } catch {
            rowErrors[modelID] = error.localizedDescription
        }
    }

    /// Deletes a model's downloaded weights after the confirmation alert.
    private func deleteModel(_ status: LocalModelStatus) {
        guard let manager = localModelManager else { return }
        rowErrors[status.id] = nil
        do {
            llmService?.unloadLocalModel(status.id)
            try manager.deleteDownload(status.id)
            reloadLocalModelStatuses()
            reloadSettingsModelChoices()
        } catch {
            rowErrors[status.id] = error.localizedDescription
        }
    }

    /// Runs the test web-search query and shows the top results or an error.
    /// Applies the Settings controller agent as the app-wide default LLM backend/model.
    private func applyAgentDefaultModel() {
        guard let llmService else { return }
        WorkspaceModelSelection.applyDefaultFromAgent(
            llmService: llmService,
            providerSettings: providerSettings,
            agentSettings: agentRegistrySettings
        )
    }

    private func runWebSearch() async {
        guard let webSearchService else {
            webSearchError = "Web search service is not available."
            return
        }
        isSearchingWeb = true
        webSearchError = nil
        webSearchResults = []
        defer { isSearchingWeb = false }
        do {
            webSearchResults = try await webSearchService.search(query: webSearchQuery, limit: 5)
        } catch {
            webSearchError = error.localizedDescription
        }
    }

    /// Builds a workspace zip, then presents the system save panel.
    private func prepareWorkspaceExport() async {
        guard let repositories else {
            exportError = "Repositories are not available."
            return
        }

        isPreparingExport = true
        exportError = nil
        exportResultMessage = nil
        exportStage = "Starting..."
        exportProgress = 0
        defer { isPreparingExport = false }

        let service = WorkspaceArchiveService(context: modelContext, repositories: repositories)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(WorkspaceArchive.suggestedFileName())-\(UUID().uuidString).zip")
        do {
            let summary = try service.exportArchive(to: tempURL) { stage, fraction in
                exportStage = stage
                exportProgress = fraction
            }
            let data = try Data(contentsOf: tempURL)
            try? FileManager.default.removeItem(at: tempURL)
            workspaceExportDocument = WorkspaceArchiveDocument(data: data)
            workspaceExportFileName = WorkspaceArchive.suggestedFileName()
            pendingExportSummary = summary.summary
            showWorkspaceExportPicker = true
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            exportError = error.localizedDescription
        }
    }

    /// Releases security-scoped access held while the replace-import alert is up.
    private func finishPendingImportAccess() {
        if pendingImportDidAccess, let url = pendingImportURL {
            url.stopAccessingSecurityScopedResource()
        }
        pendingImportDidAccess = false
        pendingImportURL = nil
    }

    /// Imports a previously exported workspace zip into the current store.
    private func importWorkspaceArchive(from url: URL, replaceExisting: Bool) async {
        guard let repositories else {
            workspaceImportError = "Repositories are not available."
            return
        }

        isWorkspaceImporting = true
        workspaceImportError = nil
        workspaceImportResultMessage = nil
        workspaceImportStage = "Starting..."
        workspaceImportProgress = 0
        defer { isWorkspaceImporting = false }

        let service = WorkspaceArchiveService(context: modelContext, repositories: repositories)
        do {
            let counts = try service.importArchive(at: url, replaceExisting: replaceExisting) { stage, fraction in
                workspaceImportStage = stage
                workspaceImportProgress = fraction
            }
            if replaceExisting {
                try? memoryService?.vectorStore.clearAllVectors()
                if let searchIndexStore {
                    try? SearchIndexBackfill.rebuildAll(repositories: repositories, store: searchIndexStore)
                }
            }
            if let memoryService {
                _ = await memoryService.reindexPending()
            }
            workspaceImportResultMessage = counts.summary
        } catch {
            workspaceImportError = error.localizedDescription
        }
    }

    /// Imports the chosen Notion export, streaming stage/progress updates.
    private func importNotionExport(from url: URL) async {
        guard let repositories else {
            notionImportError = "Repositories are not available."
            return
        }

        isNotionImporting = true
        notionImportError = nil
        notionImportResultMessage = nil
        notionImportStage = "Starting..."
        notionImportProgress = 0
        defer { isNotionImporting = false }

        let service = NotionImportService(context: modelContext, repositories: repositories)
        do {
            // The trailing closure reports staged progress back to the UI.
            let counts = try await service.importExport(at: url) { stage, fraction in
                notionImportStage = stage
                notionImportProgress = fraction
            }
            notionImportResultMessage = counts.summary
        } catch {
            notionImportError = error.localizedDescription
        }
    }

    /// Runs interactive Gmail OAuth, persists tokens, then downloads mail and
    /// syncs Google Calendar — one function after a successful login.
    @MainActor
    private func completeGoogleSignIn(existing: MailAccount? = nil) async {
        guard !isAddingMailAccount else { return }
        isAddingMailAccount = true
        mailAccountError = nil
        googleCalendarSyncError = nil
        googleCalendarSyncResult = nil
        defer { isAddingMailAccount = false }
        do {
            ConnectionDebug.log(
                "Settings",
                "Google sign-in requested mode=\(existing == nil ? "add" : "reconnect")"
            )
            let result = try await GoogleWorkspaceConnector(
                accountStore: mailAccountStore,
                mailReader: mailReader,
                calendarCache: repositories?.calendarEvents
            ).connect(existing: existing)
            var successes = ["Signed in as \(result.account.label)."]
            if result.downloadedMail {
                successes.append("Mail sync completed.")
            }
            if result.calendarError == nil {
                successes.append("Synced \(result.calendarEventCount) Google Calendar event(s).")
            }
            googleCalendarSyncResult = successes.joined(separator: " ")
            mailAccountError = result.mailError
            if let calendarError = result.calendarError {
                googleCalendarSyncError = calendarError
            }
            ConnectionDebug.log(
                "Settings",
                "Google sign-in result mailOK=\(result.downloadedMail) mailError=\(result.mailError != nil) calendarEvents=\(result.calendarEventCount) calendarError=\(result.calendarError != nil)"
            )
        } catch GoogleOAuthError.cancelled {
            // User dismissed the sheet; nothing to report.
            ConnectionDebug.log("Settings", "Google sign-in cancelled")
        } catch {
            mailAccountError = error.localizedDescription
            ConnectionDebug.log("Settings", "Google sign-in failed error=\(error.localizedDescription)")
        }
    }

    /// Runs interactive Gmail OAuth (cross-platform), adding the account on success.
    @MainActor
    private func addGoogleAccount() async {
        await completeGoogleSignIn()
    }

    /// Re-authenticates an existing Gmail account whose refresh token expired.
    @MainActor
    private func reconnectGoogleAccount(_ account: MailAccount) async {
        await completeGoogleSignIn(existing: account)
    }

    /// Syncs the next 90 days of Google Calendar events into the local cache,
    /// using the first connected Gmail account's credentials.
    private func syncGoogleCalendar() async {
        guard let repositories else {
            googleCalendarSyncError = "Repositories are not available."
            return
        }
        guard let account = mailAccountStore.primaryGoogleAccount else {
            googleCalendarSyncError = "Connect a Gmail account first."
            return
        }
        isSyncingGoogleCalendar = true
        googleCalendarSyncError = nil
        googleCalendarSyncResult = nil
        defer { isSyncingGoogleCalendar = false }

        // Compose the OAuth → API → sync chain and sync today through +90 days.
        let oauth = mailAccountStore.oauthService(for: account)
        let api = GoogleCalendarAPIClient(oauth: oauth)
        let sync = GoogleCalendarSyncService(api: api, cache: repositories.calendarEvents)
        let start = Calendar.current.startOfDay(for: .now)
        let end = Calendar.current.date(byAdding: .day, value: 90, to: start) ?? start
        do {
            let count = try await sync.syncEvents(from: start, to: end)
            googleCalendarSyncResult = "Synced \(count) Google Calendar event(s)."
        } catch {
            googleCalendarSyncError = error.localizedDescription
        }
    }
}

#if os(iOS)
/// Chat prompt editor, pushed so the AI Models form does not host a scrolling text view.
private struct ChatSystemPromptEditor: View {
    @Binding var prompt: String

    var body: some View {
        TextEditor(text: $prompt)
            .padding(.horizontal, 8)
            .navigationTitle("Chat Prompt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Reset") {
                        prompt = ChatPromptSettings.defaultChatSystemPrompt
                    }
                    .disabled(prompt == ChatPromptSettings.defaultChatSystemPrompt)
                    .accessibilityIdentifier("reset-chat-system-prompt-button")
                }
            }
    }
}
#endif
