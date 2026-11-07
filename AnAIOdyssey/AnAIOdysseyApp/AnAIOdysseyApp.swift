// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import AnAIOdysseyAI
import AnAIOdysseyCore
import AIModelOptions
import SwiftData
import SwiftUI
import AnAIOdysseyUI
import AnAIOdysseyMLX
import UserNotifications
// Mail accounts (Gmail OAuth) are cross-platform; Apple Mail is macOS-only.
import AnAIOdysseyMail

/// The app's composition root: constructs and owns every long-lived service and
/// hands them to the SwiftUI environment.
///
/// `AppModel` is created once as a `@StateObject` on ``AnAIOdysseyApp`` and performs
/// all bootstrap work in `init()` in a deliberate order:
///   1. Prepare the model cache directory and pull iCloud-synced defaults.
///   2. Construct settings objects that downstream services read from.
///   3. Select AI services based on platform and UI-test flags.
///   4. Create the SwiftData `ModelContainer`, repositories, and the feature
///      services that depend on them.
/// It is `@MainActor` because it builds UI-facing observable state and SwiftData
/// contexts that must live on the main actor.
@MainActor
final class AppModel: ObservableObject {
    /// SwiftData container backing all persistence (local or CloudKit).
    let container: ModelContainer
    /// Repository facade over the container's main context.
    let repositories: RepositoryBundle
    /// Chat/completions backend (MLX, remote, or mock).
    let llmService: any LLMServiceProtocol
    /// Manager for downloading/deleting on-device MLX weights when this device can run them.
    let localModelManager: any LocalModelManaging
    /// Embedding backend for memory vector search.
    let embeddingService: any EmbeddingServiceProtocol
    /// Long-term memory storage + semantic search.
    let memoryService: MemoryService
    /// FTS5 sidecar for unified search.
    let searchIndexStore: SearchIndexStore
    /// Web-grounded research runner.
    let researchService: ResearchService
    /// Documents writing pipeline (feature model + generation + saved Document).
    let documentWritingService: DocumentWritingService
    /// Two-model comparison runner.
    let compareService: CompareService
    /// Tool-using agent loop for agent-mode chats.
    let agentLoopService: AgentLoopService
    /// Calendar event source/cache.
    let calendarService: CalendarService
    /// Background task scheduling.
    let taskSchedulerService: TaskSchedulerService
    /// Delivers scheduled-task notifications to the agent runner.
    let taskNotificationDelegate: ScheduledTaskNotificationDelegate
    /// Multi-agent orchestration (auto-run queue with pause/continue/stop).
    let agentController: AgentController
    /// Bonjour discovery for cross-client agent task sharing (stub).
    let agentTaskSharingService: AgentTaskSharingService
    /// Voice TTS/STT (system, ElevenLabs, OpenAI, xAI).
    let voiceService: CompositeVoiceService
    /// Apple Intelligence capability probe (§16.7).
    let appleIntelligenceService: AppleIntelligenceService
    /// Resolved persistence mode (local vs. CloudKit) reported to the UI.
    let storageMode: StorageMode
    /// Remote provider configuration (base URL/key/model).
    let providerSettings: ProviderSettings
    /// App-wide appearance (accent palette + light/dark), shared across windows.
    let themeSettings: ThemeSettings
    /// Multi-agent registry preferences (controller, home/away, voice, Cursor CLI).
    let agentRegistrySettings: AgentRegistrySettings
    /// Research-specific model preferences derived from provider settings.
    let researchModelSettings: ResearchModelSettings
    /// Per-feature default model selections for AI workspaces.
    let featureModelSettings: FeatureModelSettings
    /// Web search backend used by research and the settings test.
    let webSearchService: any WebSearchServiceProtocol
    /// Multi-account mail store (Gmail OAuth accounts) — cross-platform.
    let mailAccountStore: MailAccountStore
    /// Singleton owner of email/calendar connections (Google Auth adapters).
    let connectionManager: WorkspaceConnectionManager
    /// Unified mail reader fanning out across all configured accounts — cross-platform.
    let mailReader: any MailReaderServiceProtocol
    /// Sends outgoing mail via Gmail OAuth accounts.
    let mailSendService: MailSendService
    /// Google account settings (Gemini + Calendar) — cross-platform.
    let googleSettings: GoogleSettings

    /// Bootstraps the entire dependency graph (see the type doc for ordering).
    /// Any failure to create the persistence container is fatal — the app cannot
    /// run without storage.
    init() {
        // Step 1: ensure the model cache exists, then hydrate UserDefaults from
        // iCloud before any settings object reads it, so Mac and iPad share the
        // same configuration on launch.
        AnAIOdysseyAI.ensureModelCacheDirectoryExists()
        CloudDefaultsSync.shared.start()
        ChatWebSearchEngine.migrateStoredEngine()

        // Step 2: build settings/services that have no persistence dependency.
        self.providerSettings = ProviderSettings()
        self.themeSettings = ThemeSettings()
        self.agentRegistrySettings = AgentRegistrySettings()
        self.researchModelSettings = ResearchModelSettings(providerSettings: providerSettings)
        self.featureModelSettings = FeatureModelSettings()
        self.webSearchService = WebSearchService()
        self.connectionManager = WorkspaceConnectionManager.shared
        self.mailAccountStore = self.connectionManager.accountStore
        self.googleSettings = GoogleSettings()

        // Step 3: choose AI services. UI tests force deterministic mocks; otherwise
        // this device's live Foundation Models / MLX support decides the backends.
        if ProcessInfo.processInfo.arguments.contains("UITEST_MOCK_LLM")
            || ProcessInfo.processInfo.environment["ANAIODYSSEY_MOCK_LLM"] == "1" {
            // Deterministic services for UI tests (no model downloads/Metal).
            self.llmService = MockLLMService()
            self.embeddingService = MockEmbeddingService()
            // No on-device model management under test mocks.
            self.localModelManager = UnavailableLocalModelManager()
        } else {
            // Local backends are chosen per device at runtime: Apple Foundation
            // Models when SystemLanguageModel is available, MLX when Metal plus
            // the ¾-RAM budget can actually run a catalog model.
            let mlx = OnDeviceLanguageModelSupport.mlxIsAvailable
            let apple = OnDeviceLanguageModelSupport.appleFoundationIsReady
            self.llmService = CompositeLLMService(
                settings: providerSettings,
                agentSettings: agentRegistrySettings,
                preferMLX: mlx,
                preferAppleFoundation: apple
            )
            #if os(macOS)
            self.embeddingService = mlx ? MLXEmbeddingService() : NLEmbeddingService()
            #else
            self.embeddingService = NLEmbeddingService()
            #endif
            self.localModelManager = mlx ? MLXModelManager() : UnavailableLocalModelManager()
        }

        // Mail reader: UI tests can seed a preview inbox on the connection
        // manager (same path as Google Auth). Otherwise bundled fixtures on
        // macOS, else the unified multi-account reader.
        if FakeMailTesting.isEnabled {
            connectionManager.seedFakeInboxForTesting()
            self.mailReader = UnifiedMailReaderService(
                accountStore: mailAccountStore,
                includeAppleMail: false,
                extraEmailAdapters: connectionManager.installedEmailAdapters
            )
        } else {
            #if os(macOS)
            if ProcessInfo.processInfo.arguments.contains("UITEST_FIXTURE_MAIL")
                || ProcessInfo.processInfo.arguments.contains("-UITestMailFixtures")
                || ProcessInfo.processInfo.environment["ANAIODYSSEY_UI_TEST_MAIL"] == "fixtures",
               let fixturesURL = MailFixtures.resolveFixturesDirectory() {
                self.mailReader = FixtureMailReaderService(fixturesDirectory: fixturesURL)
            } else {
                self.mailReader = UnifiedMailReaderService(
                    accountStore: mailAccountStore,
                    includeAppleMail: true,
                    extraEmailAdapters: connectionManager.installedEmailAdapters
                )
            }
            #else
            self.mailReader = UnifiedMailReaderService(
                accountStore: mailAccountStore,
                includeAppleMail: false,
                extraEmailAdapters: connectionManager.installedEmailAdapters
            )
            #endif
        }
        self.mailSendService = MailSendService(accountStore: mailAccountStore)
        // Step 4: stand up persistence and every service that depends on it.
        do {
            // Try CloudKit; the factory returns the mode it actually resolved to.
            let (container, mode) = try ModelContainerFactory.make(useCloudKit: true)
            self.container = container
            self.storageMode = mode

            // Surface CloudKit mirroring activity/errors in Settings → Storage.
            CloudKitSyncMonitor.shared.start()
            // The mirroring engine only exports when the store changes, and its
            // internal retry can wedge until relaunch. Saving a transient,
            // never-displayed record reliably kicks off a new sync cycle; used
            // by the Sync Now button and the failure watchdog.
            CloudKitSyncMonitor.shared.installNudge { [container] in
                let context = container.mainContext
                let nudge = Folder(name: "sync-nudge", kind: .documents)
                nudge.kind = "syncNudge"
                context.insert(nudge)
                try? context.save()
                context.delete(nudge)
                try? context.save()
            }

            // Ensure the app's Application Support directory exists for file-backed
            // stores (gallery images, the memory vector database).
            let appSupport = AppBranding.applicationSupportDirectory()
            try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)

            // Repositories wrap the container's main context; gallery bytes live on disk.
            let galleryDirectory = GalleryStorageLocations.galleryDirectory(appSupportDirectory: appSupport)
            self.repositories = RepositoryBundle.live(
                context: container.mainContext,
                galleryDirectory: galleryDirectory
            )

            // Memory: an on-disk vector index combined with the embedding service.
            let vectorURL = MemoryStorageLocations.vectorDatabaseURL(appSupportDirectory: appSupport)
            let vectorStore = try VectorIndexStore(databaseURL: vectorURL)
            self.memoryService = MemoryService(
                memories: self.repositories.memories,
                vectorStore: vectorStore,
                embeddingService: self.embeddingService
            )
            let searchIndexURL = SearchIndexBackfill.databaseURL(appSupportDirectory: appSupport)
            let searchIndex = try SearchIndexStore(databaseURL: searchIndexURL)
            self.searchIndexStore = searchIndex
            // Feature services composed from the LLM, settings, and repositories.
            self.researchService = ResearchService(
                webSearch: self.webSearchService,
                llmService: self.llmService,
                providerSettings: self.providerSettings,
                reports: self.repositories.researchReports
            )
            self.documentWritingService = DocumentWritingService(
                llmService: self.llmService,
                providerSettings: self.providerSettings,
                documents: self.repositories.documents
            )
            self.compareService = CompareService(
                llmService: self.llmService,
                providerSettings: self.providerSettings,
                comparisons: self.repositories.comparisons
            )
            // Give the agent settings-gated email tools (read access to the user's
            // mail). Calendar access is gated inside its built-in tool. Both are
            // off until the user opts in via Settings → AI Data Access.
            self.calendarService = CalendarService(cache: self.repositories.calendarEvents)
            self.connectionManager.attach(
                calendarCache: self.repositories.calendarEvents,
                calendarService: self.calendarService
            )
            self.taskSchedulerService = TaskSchedulerService(tasks: self.repositories.tasks)

            let adapterRegistry = AgentAdapterFactory.makeDefaultRegistry(
                llmService: self.llmService,
                settings: self.agentRegistrySettings
            )
            self.agentController = AgentController(
                registry: adapterRegistry,
                settings: self.agentRegistrySettings,
                repositories: self.repositories,
                appSupportDirectory: appSupport,
                llmService: self.llmService,
                memoryService: self.memoryService,
                featureModelSettings: self.featureModelSettings,
                providerSettings: self.providerSettings,
                researchService: self.researchService,
                documentWritingService: self.documentWritingService
            )
            // Safer than auto-resuming HTTP/tool rounds with a half-rebuilt
            // conversation: in-flight work becomes Paused; the user taps Continue.
            self.agentController.recoverInterruptedRuns()
            self.agentTaskSharingService = AgentTaskSharingService()
            self.voiceService = CompositeVoiceService(
                settings: self.agentRegistrySettings,
                providerSettings: self.providerSettings
            )
            self.appleIntelligenceService = AppleIntelligenceService()

            let emailTools = EmailAgentTools.make(mailReader: self.mailReader)
            // Chat only gets the agent-queue tools where agent tasks are visible.
            let queueTools: (tools: [any AgentTool], descriptions: String) =
                AgentTaskVisibilityPolicy.isAgentQueueVisible
                ? AgentQueueTools.make(agentController: self.agentController)
                : ([], "")
            let calendarAccess = CalendarAgentAccess(
                calendarService: self.calendarService,
                refreshGoogleCalendar: { [mailAccountStore = self.mailAccountStore, repositories = self.repositories] start, end in
                    guard let account = mailAccountStore.primaryGoogleAccount,
                          mailAccountStore.isSignedIn(account) else { return }
                    let oauth = mailAccountStore.oauthService(for: account)
                    let api = GoogleCalendarAPIClient(oauth: oauth)
                    let sync = GoogleCalendarSyncService(api: api, cache: repositories.calendarEvents)
                    _ = try await sync.syncEvents(from: start, to: end)
                }
            )
            self.agentLoopService = AgentLoopService(
                llmService: self.llmService,
                repositories: self.repositories,
                memoryService: self.memoryService,
                calendarAccess: calendarAccess,
                extraTools: emailTools.tools + queueTools.tools,
                extraToolDescriptions: queueTools.descriptions.isEmpty
                    ? emailTools.descriptions
                    : emailTools.descriptions + "\n\n" + queueTools.descriptions
            )

            let scheduler = self.taskSchedulerService
            let loop = self.agentLoopService
            let repos = self.repositories
            let memory = self.memoryService
            self.taskNotificationDelegate = ScheduledTaskNotificationDelegate(scheduler: scheduler) { task in
                guard let prompt = task.prompt?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !prompt.isEmpty else { return }
                let context = AgentContext(
                    sessionID: task.sessionID ?? UUID().uuidString,
                    repositories: repos,
                    memoryService: memory
                )
                var finalText = ""
                for await event in loop.run(prompt: prompt, history: [], context: context) {
                    if case .finished(let content) = event {
                        finalText = content
                    }
                }
                guard !finalText.isEmpty else { return }
                _ = try? repos.notes.createNote(
                    title: "Task: \(task.name)",
                    content: finalText
                )
            }
            TaskSchedulerService.install(delegate: self.taskNotificationDelegate)

            AgentLLMDefaults.applyDefaultFromAgent(
                llmService: self.llmService,
                providerSettings: self.providerSettings,
                agentSettings: self.agentRegistrySettings
            )
        } catch {
            // Without storage the app is non-functional; fail fast and loudly.
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }

    /// Runs non-blocking startup warm-up work for embeddings and local caches.
    /// Remote model lists remain unchanged until the user explicitly refreshes
    /// them in Settings.
    func performStartupWarmUp() async {
        guard !Self.shouldSkipStartupWarmUp else { return }

        async let memoryWarmUp: Void = memoryService.warmUp()
        async let searchIndexWarmUp: Void = warmUpSearchIndex()
        async let notificationsWarmUp: Void = warmUpNotifications()
        async let mailWarmUp: Void = warmUpMailReader()
        // Cache the true CloudKit account status for the next launch's gating
        // (covers devices where iCloud Drive is off but iCloud is signed in).
        async let accountStatusRefresh: Void = ICloudAvailability.refreshAccountStatus()
        async let photosGalleryWarmUp: Void = warmUpPhotosGallery()
        _ = await (memoryWarmUp, searchIndexWarmUp, notificationsWarmUp, mailWarmUp, accountStatusRefresh, photosGalleryWarmUp)
        // Diagnose CloudKit server-side rejections with an unredacted probe.
        if storageMode == .cloudKit {
            await CloudKitSyncMonitor.probeSchema()
        }
    }

    private func warmUpNotifications() async {
        // No permission prompt at launch: it comes with the first scheduled task. Rescheduling
        // asks only when there are reminders to keep (see NotificationPromptPolicy).
        _ = try? await taskSchedulerService.rescheduleAllActiveTasks()
    }

    private func warmUpSearchIndex() async {
        // Full rebuild each launch: the sidecar is cheap derived data, and this
        // picks up entities edited or deleted since the index was last built.
        _ = try? SearchIndexBackfill.rebuildAll(
            repositories: repositories,
            store: searchIndexStore
        )
    }

    private static var shouldSkipStartupWarmUp: Bool {
        let env = ProcessInfo.processInfo.environment
        let args = ProcessInfo.processInfo.arguments
        if env["ANAIODYSSEY_MOCK_LLM"] == "1" { return true }
        if args.contains("UITEST_MOCK_LLM") { return true }
        if args.contains("UITEST_FIXTURE_MAIL") { return true }
        if args.contains("-UITestMailFixtures") { return true }
        if env["ANAIODYSSEY_UI_TEST_MAIL"] == "fixtures" { return true }
        if FakeMailTesting.isEnabled { return true }
        return false
    }

    private func warmUpMailReader() async {
        guard let unified = mailReader as? UnifiedMailReaderService else { return }
        await unified.warmUp()
    }

    /// Copies images that already synced via iCloud Photos into the in-app gallery.
    private func warmUpPhotosGallery() async {
        _ = await PhotosGallerySync.run(gallery: repositories.gallery)
    }
}

/// The SwiftUI app entry point.
///
/// Owns the single ``AppModel`` (built once via `@StateObject`) and injects its
/// services into the environment so feature views can resolve them. The main
/// `WindowGroup` hosts ``RootView``; on macOS an additional `Settings` scene
/// provides the menu-bar Settings window, which is given the same dependencies it
/// needs (model container, provider/Google settings, and the relevant services).
@main
struct AnAIOdysseyApp: App {
    /// The composition root; created once and kept alive for the app's lifetime.
    @StateObject private var appModel = AppModel()
    /// Drives the Chat / Research run centers (background time, local-model stop).
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        // Primary window: the workspace shell with the full dependency graph
        // injected and the active theme applied.
        WindowGroup {
            ThemeContainer(theme: appModel.themeSettings) {
                RootView(storageMode: appModel.storageMode)
                    .injectingAppEnvironment(appModel)
                    .voiceLibraryBanner()
                    .runCompletionBanner()
                    .task {
                        BackgroundRuns.configure()
                        await appModel.performStartupWarmUp()
                    }
                    .onChange(of: scenePhase) { _, phase in
                        BackgroundRuns.scenePhaseChanged(phase)
                    }
            }
        }
        #if os(iOS)
        // Open at a landscape iPad-friendly size instead of a phone-sized window.
        .defaultSize(width: 1194, height: 834)
        .windowResizability(.automatic)
        #else
        .defaultSize(width: 1200, height: 800)
        #endif

        // Pop-out windows: Email, Tasks, and Calendar can each open in their own
        // window via `openWindow(id:)`. Each is a separate scene, so it must be
        // re-injected with the same dependencies and theme.
        WindowGroup(id: AppWindowID.email) {
            ThemeContainer(theme: appModel.themeSettings) {
                EmailWindowScene().injectingAppEnvironment(appModel)
            }
        }
        #if os(iOS)
        .defaultSize(width: 1000, height: 720)
        .windowResizability(.automatic)
        #else
        .defaultSize(width: 1000, height: 720)
        #endif

        WindowGroup(id: AppWindowID.tasks) {
            ThemeContainer(theme: appModel.themeSettings) {
                TasksWindowScene().injectingAppEnvironment(appModel)
            }
        }
        #if os(iOS)
        .defaultSize(width: 900, height: 680)
        .windowResizability(.automatic)
        #else
        .defaultSize(width: 900, height: 680)
        #endif

        WindowGroup(id: AppWindowID.calendar) {
            ThemeContainer(theme: appModel.themeSettings) {
                CalendarWindowScene().injectingAppEnvironment(appModel)
            }
        }
        #if os(iOS)
        .defaultSize(width: 900, height: 720)
        .windowResizability(.automatic)
        #else
        .defaultSize(width: 900, height: 720)
        #endif

        // macOS-only menu-bar Settings window (⌘,). It is a separate scene, so it
        // must be re-injected with the dependencies SettingsView reads.
        #if os(macOS)
        Settings {
            ThemeContainer(theme: appModel.themeSettings) {
                SettingsView(storageMode: appModel.storageMode)
                    .injectingAppEnvironment(appModel)
                    .voiceLibraryBanner()
            }
        }
        #endif
    }
}

private extension View {
    /// Injects the full app dependency graph (persistence, settings objects, and
    /// service environment values) into a scene's root view. Applied to every
    /// window so the main shell, pop-out windows, and Settings all resolve the
    /// same services.
    @MainActor
    func injectingAppEnvironment(_ appModel: AppModel) -> some View {
        self
            .modelContainer(appModel.container)
            // ObservableObject settings shared via @EnvironmentObject.
            .environmentObject(appModel.providerSettings)
            .environmentObject(appModel.researchModelSettings)
            .environmentObject(appModel.featureModelSettings)
            .environmentObject(appModel.mailAccountStore)
            .environmentObject(appModel.connectionManager)
            .environmentObject(appModel.themeSettings)
            .environmentObject(appModel.agentRegistrySettings)
            .environmentObject(appModel.googleSettings)
            .environmentObject(ChatGPTAccountService.shared)
            #if DEBUG
            .task {
                if ProcessInfo.processInfo.arguments.contains("UITEST_CHATGPT_PLAN") {
                    ChatGPTAccountService.shared.seedUITestPlanAccount(into: appModel.providerSettings)
                }
            }
            #endif
            // Services exposed through custom environment keys.
            .environment(\.repositories, appModel.repositories)
            .environment(\.llmService, appModel.llmService)
            .environment(\.localModelManager, appModel.localModelManager)
            .environment(\.webSearchService, appModel.webSearchService)
            .environment(\.memoryService, appModel.memoryService)
            .environment(\.searchIndexStore, appModel.searchIndexStore)
            .environment(\.researchService, appModel.researchService)
            .environment(\.compareService, appModel.compareService)
            .environment(\.agentLoopService, appModel.agentLoopService)
            .environment(\.calendarService, appModel.calendarService)
            .environment(\.taskSchedulerService, appModel.taskSchedulerService)
            .environment(\.agentController, appModel.agentController)
            .environment(\.voiceService, appModel.voiceService)
            // Mail reader + account store + Google settings are cross-platform.
            .environment(\.mailReader, appModel.mailReader)
            .environment(\.mailSendService, appModel.mailSendService)
            .environment(\.mailAccountStore, appModel.mailAccountStore)
            .environment(\.workspaceConnectionManager, appModel.connectionManager)
            .environment(\.googleSettings, appModel.googleSettings)
    }
}
