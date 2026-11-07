// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import AnAIOdysseyCore
import AnAIOdysseyAI
import AIConnect
import AIConnectUI
import AIModelOptions
import SwiftUI

/// The Chats workspace: a master/detail browser over saved chat sessions.
///
/// The leading column lists sessions and owns create/delete actions; the trailing
/// column shows the conversation for the open session via ``ChatDetailView``.
/// iPhone/iPad use an explicit Select mode; Mac uses native List multi-select.
struct ChatsView: View {
    /// Persistence layer for chat sessions/messages, injected by the host app.
    @Environment(\.repositories) private var repositories
    /// Active LLM service; used here only to stamp new sessions with the current model.
    @Environment(\.llmService) private var llmService
    /// Remote/local provider configuration shared across the workspace.
    @EnvironmentObject private var providerSettings: ProviderSettings
    @EnvironmentObject private var featureModelSettings: FeatureModelSettings

    /// Locally cached list of active sessions backing the sidebar.
    @State private var sessions: [ChatSession] = []
    /// Chat shown in the detail pane. Scene-scoped so rotation / background keep it.
    @SceneStorage(WorkspaceNavigationPolicy.openChatSceneKey) private var storedOpenSessionID = ""
    private var openSessionID: String? {
        get { WorkspaceNavigationPolicy.storedOpenChatID(storedOpenSessionID) }
        nonmutating set { storedOpenSessionID = WorkspaceNavigationPolicy.persistOpenChatID(newValue) }
    }
    /// Rows marked for bulk delete (iOS Select mode, or Mac ⌘/Shift-click).
    @State private var selectedSessionIDs = Set<String>()
    /// iPhone/iPad Select mode (checkmark circles). Unused on Mac.
    @State private var isSelecting = false
    /// When true, iPhone stays on the session list even after reload (e.g. user tapped back).
    @SceneStorage(WorkspaceNavigationPolicy.browsingListSceneKey) private var phoneBrowsingSessionList = true
    /// Drives the destructive delete confirmation alert.
    @State private var showDeleteConfirmation = false
    @Environment(\.voiceService) private var chatsVoiceService
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var chatsHorizontalSizeClass
    @Environment(\.verticalSizeClass) private var chatsVerticalSizeClass
    #endif

    var body: some View {
        #if os(iOS)
        if WorkspaceNavigationPolicy.shouldUsePhoneChatLayout(
            idiomIsPhone: WorkspaceIdiom.isPhone,
            horizontalSizeClassIsRegular: chatsHorizontalSizeClass == .regular,
            verticalSizeClassIsRegular: chatsVerticalSizeClass == .regular
        ) {
            phoneBody
        } else {
            splitBody
        }
        #else
        splitBody
        #endif
    }

    private var splitBody: some View {
        NavigationSplitView {
            sessionSidebar
        } detail: {
            sessionDetail
                .workspaceFillDetailPane()
        }
        .removeNestedSidebarToggle()
        .workspaceNavigationSplit()
        .onAppear(perform: reload)
        .deleteConfirmation(title: deleteConfirmationTitle, isPresented: $showDeleteConfirmation, delete: deleteSelectedSessions)
    }

    #if os(iOS)
    /// iPhone: list → detail. Select mode lives on the list, not the open chat.
    ///
    /// No `NavigationStack` here: `PhoneRootView.tabStack` already hosts this view in
    /// one. A nested stack made the inner toolbar lose its leading slot (Select All)
    /// to the tab's StorageSyncBadge and left the bottom-bar Delete under the tab bar,
    /// so on iPhone bulk delete could not be reached.
    private var phoneBody: some View {
        Group {
            if let sessionID = phoneOpenSessionID {
                ChatDetailView(sessionID: sessionID, onUpdated: reload)
                    .id(sessionID)
            } else {
                phoneSessionList
            }
        }
        .navigationTitle(phoneOpenSessionID == nil ? "Chats" : sessionTitle(for: phoneOpenSessionID))
        .navigationBarTitleDisplayMode(phoneOpenSessionID == nil ? .large : .inline)
        .toolbar { phoneToolbar }
        .onAppear(perform: reload)
        .deleteConfirmation(title: deleteConfirmationTitle, isPresented: $showDeleteConfirmation, delete: deleteSelectedSessions)
    }

    private var phoneOpenSessionID: String? {
        phoneBrowsingSessionList ? nil : openSessionID
    }

    private var phoneSessionList: some View {
        chatSessionList(opensOnTap: !isSelecting)
            // Back-tap → list timing (VoiceNav signposts).
            .onAppear { VoiceNavTiming.listAppeared() }
            .environment(\.editMode, .constant(isSelecting ? .active : .inactive))
            .safeAreaInset(edge: .bottom) {
                // Not a `.bottomBar` toolbar item: inside the phone TabView that bar
                // renders behind the tab bar, so Delete was visible-ish but untappable.
                if isSelecting {
                    iosDeleteButton
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(.bar)
                }
            }
            .overlay {
                if sessions.isEmpty {
                    chatEmptyState
                }
            }
    }

    @ToolbarContentBuilder
    private var phoneToolbar: some ToolbarContent {
        if phoneOpenSessionID != nil {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    // Navigate first (VoiceLifecyclePolicy.leaveChatOrder). The
                    // voice session controller cuts audio synchronously and runs
                    // the teardown off the main thread; Back never waits on it.
                    VoiceNavTiming.backTapped(
                        context: String(describing: VoiceSessionControllers.controller(for: chatsVoiceService).state)
                    )
                    phoneBrowsingSessionList = true
                    isSelecting = false
                    if VoiceLifecyclePolicy.shouldTeardownConversation(reason: .userLeftChat) {
                        VoiceAudioDebugStore.append(event: "voice.leaveChat", detail: "back")
                        VoiceSessionControllers.controller(for: chatsVoiceService).leave()
                    }
                } label: {
                    Label("Chats", systemImage: "chevron.left")
                }
                .isolatedFormButton()
            }
        } else if isSelecting {
            ToolbarItem(placement: .topBarLeading) {
                selectAllButton
            }
        }

        ToolbarItemGroup(placement: .topBarTrailing) {
            if phoneOpenSessionID == nil {
                if isSelecting {
                    Button("Done") {
                        exitSelecting()
                    }
                    .isolatedFormButton()
                    .accessibilityIdentifier("chat-select-done-button")
                } else {
                    newChatButton
                    Button("Select") {
                        isSelecting = true
                        selectedSessionIDs = []
                    }
                    .isolatedFormButton()
                    .disabled(sessions.isEmpty)
                    .accessibilityIdentifier("chat-select-button")
                }
            } else {
                newChatButton
            }
        }
    }
    #endif

    private func sessionTitle(for sessionID: String?) -> String {
        guard let sessionID,
              let session = sessions.first(where: { $0.id == sessionID }) else {
            return "Chat"
        }
        return session.name
    }

    /// Leading column for Mac and iPad.
    private var sessionSidebar: some View {
        chatSessionList(opensOnTap: false)
            #if os(iOS)
            .environment(\.editMode, .constant(isSelecting ? .active : .inactive))
            #endif
            .macWorkspaceSplit()
            .navigationTitle("Chats")
            .toolbar { sidebarToolbar }
            #if os(macOS)
            .onDeleteCommand(perform: requestDeleteIfNeeded)
            .background {
                Button("Select All") {
                    selectedSessionIDs = Set(sessionIDs)
                }
                .keyboardShortcut("a", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
            }
            #endif
    }

    @ToolbarContentBuilder
    private var sidebarToolbar: some ToolbarContent {
        #if os(iOS)
        if isSelecting {
            ToolbarItem(placement: .topBarLeading) {
                selectAllButton
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") {
                    exitSelecting()
                }
                .isolatedFormButton()
                .accessibilityIdentifier("chat-select-done-button")
            }
            ToolbarItem(placement: .bottomBar) {
                iosDeleteButton
            }
        } else {
            ToolbarItemGroup(placement: .topBarTrailing) {
                newChatButton
                Button("Select") {
                    isSelecting = true
                    selectedSessionIDs = []
                }
                .isolatedFormButton()
                .disabled(sessions.isEmpty)
                .accessibilityIdentifier("chat-select-button")
            }
        }
        #else
        ToolbarItemGroup(placement: .primaryAction) {
            newChatButton
                .keyboardShortcut("n", modifiers: .command)
        }
        #endif
    }

    private var newChatButton: some View {
        Button {
            createSession()
        } label: {
            Label("New Chat", systemImage: "square.and.pencil")
        }
        .workspaceActionButtonTint()
        .isolatedFormButton()
        .accessibilityIdentifier("new-chat-button")
    }

    private var selectAllButton: some View {
        Button(ChatListSelectionPolicy.selectAllTitle(isAllSelected: allSelected)) {
            selectedSessionIDs = ChatListSelectionPolicy.toggleSelectAll(
                current: selectedSessionIDs,
                allIDs: sessionIDs
            )
        }
        .isolatedFormButton()
        .disabled(sessions.isEmpty)
        .accessibilityIdentifier("chat-select-all-button")
    }

    private var iosDeleteButton: some View {
        Button(ChatListSelectionPolicy.deleteButtonTitle(count: selectedSessionIDs.count), role: .destructive) {
            showDeleteConfirmation = true
        }
        .isolatedFormButton()
        .disabled(!ChatListSelectionPolicy.canDelete(selectedSessionIDs.count))
        .accessibilityIdentifier("delete-chat-button")
    }

    @ViewBuilder
    private func chatSessionList(opensOnTap: Bool) -> some View {
        #if os(iOS)
        if isSelecting {
            List(selection: $selectedSessionIDs) {
                ForEach(sessions, id: \.id) { session in
                    sessionRow(session, opensOnTap: false)
                        .tag(session.id)
                }
            }
        } else if opensOnTap {
            List {
                ForEach(sessions, id: \.id) { session in
                    sessionRow(session, opensOnTap: true)
                }
            }
        } else {
            List(selection: iosBrowseSelection) {
                ForEach(sessions, id: \.id) { session in
                    sessionRow(session, opensOnTap: false)
                        .tag(session.id)
                }
            }
        }
        #else
        List(selection: $selectedSessionIDs) {
            ForEach(sessions, id: \.id) { session in
                sessionRow(session, opensOnTap: false)
                    .tag(session.id)
            }
        }
        .onChange(of: selectedSessionIDs) { _, newValue in
            handleSelectionChange(newValue)
        }
        #endif
    }

    #if os(iOS)
    private var iosBrowseSelection: Binding<Set<String>> {
        Binding(
            get: { openSessionID.map { Set([$0]) } ?? [] },
            set: { newValue in
                if let id = newValue.first {
                    openSessionID = id
                }
            }
        )
    }
    #endif

    /// App-level chat generations, for the spinner/Stop on each row.
    @ObservedObject private var chatRuns = ChatGenerationCenter.shared

    @ViewBuilder
    private func sessionRow(_ session: ChatSession, opensOnTap: Bool) -> some View {
        let row = ChatSessionRow(session: session)
            .accessibilityIdentifier("chat-session-row")
        Group {
            if opensOnTap {
                Button {
                    openSessionID = session.id
                    phoneBrowsingSessionList = false
                } label: {
                    row
                }
                .buttonStyle(.plain)
            } else {
                row
            }
        }
        .runRowAccessory(chatRuns.snapshot(for: session.id), center: chatRuns)
        .contextMenu {
            #if os(macOS)
            Button(macContextMenuTitle(for: session), role: .destructive) {
                prepareMacContextDelete(for: session)
            }
            .isolatedFormButton()
            #else
            if !isSelecting {
                Button("Delete Chat", role: .destructive) {
                    selectedSessionIDs = [session.id]
                    showDeleteConfirmation = true
                }
                .isolatedFormButton()
            }
            #endif
        }
    }

    /// Trailing column: the open conversation, or the empty state — never a blank pane.
    @ViewBuilder
    private var sessionDetail: some View {
        if let sessionID = resolvedOpenSessionID {
            ChatDetailView(sessionID: sessionID, onUpdated: reload)
                .id(sessionID)
        } else {
            chatEmptyState
        }
    }

    private var chatEmptyState: some View {
        ContentUnavailableView(
            sessions.isEmpty ? "No Chats Yet" : "No Chat Selected",
            systemImage: "bubble.left.and.bubble.right",
            description: Text(
                sessions.isEmpty
                    ? "Tap New Chat to start a conversation."
                    : "Create or select a chat session."
            )
        )
        .accessibilityIdentifier("chats-empty-state")
    }

    private var deleteConfirmationTitle: String {
        ChatListSelectionPolicy.confirmationTitle(count: selectedSessionIDs.count)
    }

    private var sessionIDs: [String] {
        sessions.map(\.id)
    }

    private var allSelected: Bool {
        ChatListSelectionPolicy.isAllSelected(current: selectedSessionIDs, allIDs: sessionIDs)
    }

    private var resolvedOpenSessionID: String? {
        guard let openSessionID,
              sessions.contains(where: { $0.id == openSessionID })
        else {
            return nil
        }
        return openSessionID
    }

    /// Refreshes the session list. Does not auto-open another chat after a delete.
    private func reload() {
        guard let repositories else { return }
        sessions = (try? repositories.sessions.listActiveSessions()) ?? []
        selectedSessionIDs = selectedSessionIDs.filter { id in
            sessions.contains { $0.id == id }
        }
        if let openSessionID, !sessions.contains(where: { $0.id == openSessionID }) {
            self.openSessionID = nil
        }
    }

    /// Creates a new chat stamped with the current model and opens it.
    private func createSession() {
        guard let repositories else { return }
        let modelName = llmService?.selectedModelID ?? "local"
        let session = try? repositories.sessions.createSession(
            name: "New Chat",
            endpointURL: "local-mlx",
            model: modelName,
            owner: nil
        )
        exitSelecting()
        reload()
        if let session {
            openSessionID = session.id
            selectedSessionIDs = [session.id]
            phoneBrowsingSessionList = false
        }
    }

    /// Permanently deletes every selected session through the single-chat path.
    private func deleteSelectedSessions() {
        guard let repositories else { return }
        let ids = selectedSessionIDs
        openSessionID = ChatListSelectionPolicy.openSessionAfterDelete(
            openID: openSessionID,
            deletedIDs: ids
        )
        for id in ids {
            try? repositories.sessions.deleteSession(id: id)
        }
        selectedSessionIDs.removeAll()
        isSelecting = false
        if openSessionID == nil {
            phoneBrowsingSessionList = true
        }
        reload()
    }

    private func exitSelecting() {
        isSelecting = false
        selectedSessionIDs = openSessionID.map { [$0] } ?? []
    }

    private func handleSelectionChange(_ newValue: Set<String>) {
        #if os(macOS)
        if newValue.count == 1 {
            openSessionID = newValue.first
        }
        #else
        if isSelecting { return }
        if newValue.count == 1 {
            openSessionID = newValue.first
        }
        #endif
    }

    #if os(macOS)
    private func macContextMenuTitle(for session: ChatSession) -> String {
        if selectedSessionIDs.count > 1, selectedSessionIDs.contains(session.id) {
            return ChatListSelectionPolicy.contextMenuTitle(count: selectedSessionIDs.count)
        }
        return ChatListSelectionPolicy.contextMenuTitle(count: 1)
    }

    private func prepareMacContextDelete(for session: ChatSession) {
        if !(selectedSessionIDs.count > 1 && selectedSessionIDs.contains(session.id)) {
            selectedSessionIDs = [session.id]
        }
        showDeleteConfirmation = true
    }

    private func requestDeleteIfNeeded() {
        guard ChatListSelectionPolicy.canDelete(selectedSessionIDs.count) else { return }
        showDeleteConfirmation = true
    }
    #endif
}

private extension View {
    func deleteConfirmation(title: String, isPresented: Binding<Bool>, delete: @escaping () -> Void) -> some View {
        destructiveDeleteAlert(
            title,
            isPresented: isPresented,
            message: ChatListSelectionPolicy.confirmationMessage,
            confirmAction: delete
        )
    }
}

/// A single sidebar row summarizing a chat session by name.
private struct ChatSessionRow: View {
    let session: ChatSession

    var body: some View {
        Text(session.name)
            .font(.body.weight(.medium))
            .lineLimit(1)
            .padding(.vertical, 2)
    }
}

/// Immutable snapshot of a persisted chat message for safe SwiftUI rendering.
private struct ChatMessageSnapshot: Identifiable, Equatable {
    let id: String
    let role: String
    let content: String
    let timestamp: Date
    let galleryImageID: String?
    let citations: [ChatWebSearchCitation]
    let usedWebSearch: Bool
    let showWebSearchOffHint: Bool
    let webSearchFailed: Bool
    let webSearchFallbackNotice: String?
    let webSearchEngine: ChatWebSearchEngine?
    let reasoning: String?
    let thoughtDurationSeconds: TimeInterval?

    init(_ message: ChatMessage) {
        id = message.id
        role = message.role
        content = message.content
        timestamp = message.timestamp
        galleryImageID = ChatMessageGalleryMetadata.galleryImageID(from: message.metadata)
        citations = ChatWebSearchPolicy.citations(from: message.metadata)
        usedWebSearch = ChatWebSearchPolicy.usedWebSearch(from: message.metadata)
        showWebSearchOffHint = ChatWebSearchPolicy.showOffHint(from: message.metadata)
        webSearchFailed = ChatWebSearchPolicy.searchFailed(from: message.metadata)
        webSearchFallbackNotice = ChatWebSearchPolicy.fallbackNotice(from: message.metadata)
        webSearchEngine = ChatWebSearchPolicy.persistedEngine(from: message.metadata)
        reasoning = ThinkingSectionPolicy.reasoning(from: message.metadata)
        thoughtDurationSeconds = ThinkingSectionPolicy.thoughtDurationSeconds(from: message.metadata)
    }
}

/// The conversation surface for a single chat session.
///
/// Renders the scrolling transcript, a bottom composer, and a toolbar for picking
/// the model and opening the shared Options view. Sends always run the tool-using
/// agent loop (or image generation when an image model is selected).
struct ChatDetailView: View {
    /// Chat persistence (messages and session metadata).
    @Environment(\.repositories) private var repositories
    /// The model that produces streamed responses.
    @Environment(\.llmService) private var llmService
    /// Long-term memory store used to recall context for non-agent replies.
    @Environment(\.memoryService) private var memoryService
    /// Optional shared agent loop; a per-view instance is built on demand if absent.
    @Environment(\.agentLoopService) private var agentLoopService
    /// Text-to-speech for voice chat; speech input is Apple Speech.
    @Environment(\.voiceService) private var voiceService
    /// Provider configuration that maps picker selections to concrete backends.
    @EnvironmentObject private var providerSettings: ProviderSettings
    @ObservedObject private var chatPromptSettings = ChatPromptSettings.shared
    @EnvironmentObject private var featureModelSettings: FeatureModelSettings
    @EnvironmentObject private var agentRegistrySettings: AgentRegistrySettings
    @Environment(\.webSearchService) private var webSearchService
    @AppStorage(AIDataAccess.chatWebSearchKey) private var allowChatWebSearch = false
    @AppStorage(AIDataAccess.chatWebSearchEngineKey) private var chatWebSearchEngine = ChatWebSearchEngine.brave

    /// Identifies which session's transcript this view edits.
    let sessionID: String
    /// Notifies the parent list (e.g. to refresh titles/ordering) after writes.
    let onUpdated: () -> Void

    /// Persisted transcript loaded from storage.
    @State private var messages: [ChatMessageSnapshot] = []
    /// The in-progress composer text. Mirrored into `ChatDraftStore` so a fold or unfold
    /// (which rebuilds this view) keeps it.
    @State private var draft = ""
    /// Live assistant text while a response streams in; `nil` when idle.
    @State private var streamingTextLocal: String?
    /// App-level owner of this chat's generation, so leaving the chat or
    /// switching tabs doesn't drop the reply.
    @ObservedObject private var chatRuns = ChatGenerationCenter.shared
    /// The center's run for this chat (running, or stopped partway).
    private var centerRun: RunSnapshot? {
        guard let run = chatRuns.snapshot(for: sessionID), run.phase != .finished else { return nil }
        return run
    }
    /// Local stream text, or the center's when this view was rebuilt mid-run.
    private var streamingText: String? {
        get {
            if let streamingTextLocal { return streamingTextLocal }
            if let run = centerRun, run.isRunning { return run.text }
            return nil
        }
        nonmutating set { streamingTextLocal = newValue }
    }
    /// Live chain-of-thought from `reasoning_content` / `reasoning`.
    @State private var streamingReasoning: String?
    @State private var thinkingExpanded = true
    @State private var userExpandedThinking = false
    @State private var thinkingDurationSeconds: TimeInterval?
    /// Human-readable agent progress (e.g. "Running search…").
    @State private var agentStatusLocal: String?
    private var agentStatus: String? {
        get { agentStatusLocal ?? (centerRun?.isRunning == true ? centerRun?.status : nil) }
        nonmutating set { agentStatusLocal = newValue }
    }
    /// Mirrors live output into the run center for rebuilt views and rows.
    private var runHandle: RunHandle? { chatRuns.currentHandle(id: sessionID) }
    /// Encoded model+backend choice from the toolbar picker.
    @State private var modelSelectionKey = ""
    /// Guards against overlapping sends while a response is generating.
    @State private var isGeneratingLocal = false
    private var isGenerating: Bool {
        get { isGeneratingLocal || centerRun?.isRunning == true }
        nonmutating set { isGeneratingLocal = newValue }
    }
    /// Surfaces a generation failure in the transcript.
    @State private var generationError: String?
    /// The model answered in text where a tool call was expected.
    @State private var showToolFormatHint = false
    @State private var toolFormatHintModel = ""
    @State private var toolFormatHintConnectionID: String?
    /// Short non-blocking audio recovery line (car Bluetooth / route change).
    @State private var audioIssue: String?
    @State private var audioIssueClearTask: Task<Void, Never>?
    /// Mirrors `voiceSession.state.isActive` (starting, listening or speaking).
    /// The controller is app-wide, so a view rebuild restores it.
    @State private var isVoiceControlMode = false
    @State private var voiceSessionState: VoiceSessionState = .idle
    /// The latest submitted turn; only its run may speak, clean up, or tell
    /// the voice session the reply ended (B2, B3).
    @State private var replySpeech = VoiceReplySpeechOwner()
    /// Mirrors `voiceSession.interruptionNotice`.
    @State private var voiceInterruptionNotice: String?
    @State private var showVoiceSettings = false
    /// True while the assistant reply is being read aloud.
    @State private var isSpeaking = false
    @State private var voiceReplay = VoiceReplayStore()
    /// True after the user turn is sent and before the first TTS buffer plays.
    @State private var isAwaitingSpokenAudio = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var generationTask: Task<Void, Never>?
    @State private var toolEvents: [AgentToolChip] = []
    @FocusState private var composerFocused: Bool
    /// Gallery photo attached to the next image-model send (edited instead of generated).
    @State private var attachedGalleryImage: GalleryImage?
    @State private var showGalleryImagePicker = false

    /// Transcript + composer stack, wired to load messages on appear and to keep
    /// the LLM backend in sync with the toolbar model picker.
    var body: some View {
        VStack(spacing: 0) {
            messageList
            Divider()
            composerBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(sessionTitle)
        #if os(macOS)
        .navigationSubtitle(modelStatusLine)
        #endif
        .toolbar { chatToolbar }
        .sheet(isPresented: $showGalleryImagePicker) {
            GalleryImagePickerSheet(selectedImage: $attachedGalleryImage)
        }
        .sheet(isPresented: $showVoiceSettings) {
            NavigationStack {
                Form {
                    WorkspaceVoicePicker(
                        agentRegistrySettings: agentRegistrySettings,
                        providerSettings: providerSettings
                    ).formRows
                }
                .navigationTitle("Voice")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showVoiceSettings = false }
                            .accessibilityIdentifier("voice-settings-done-button")
                    }
                }
            }
        }
        .onAppear {
            ChatWebSearchEngine.migrateStoredEngine()
            chatWebSearchEngine = ChatWebSearchEngine.resolvedSelectable(chatWebSearchEngine.rawValue)
            reload()
            applyChatModelDefault()
            voiceSessionState = voiceSession.state
            isVoiceControlMode = voiceSession.state.isActive
            voiceInterruptionNotice = voiceSession.interruptionNotice
            voiceSession.onReplyDiscarded = { stopSpokenReplyAndResumeListening() }
            voiceService.setAudioIssueHandler { message in
                audioIssue = message
                audioIssueClearTask?.cancel()
                guard message != nil else { return }
                audioIssueClearTask = Task {
                    try? await Task.sleep(for: .seconds(5))
                    if !Task.isCancelled {
                        audioIssue = nil
                    }
                }
            }
            if isVoiceControlMode {
                Task { await voiceService.prepareSpokenConversation() }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            handleVoiceScenePhase(phase)
        }
        .onReceive(voiceSession.$interruptionNotice) { notice in
            voiceInterruptionNotice = notice
        }
        .onReceive(voiceSession.$state) { state in
            voiceSessionState = state
            isVoiceControlMode = state.isActive
            if case .error(let message) = state, voiceSession.isAttached {
                generationError = message
            }
        }
        .onChange(of: isSpeaking) { _, speaking in
            if speaking { voiceSession.replyStarted() }
        }
        .onAppear {
            chatRuns.watchedIDs.insert(sessionID)
            absorbEndedRun()
            // Rebuilt by a fold or unfold (root view swap): bring the half-typed message back.
            if draft.isEmpty { draft = ChatDraftStore.shared.draft(for: sessionID) }
        }
        .onChange(of: draft) { _, text in ChatDraftStore.shared.setDraft(text, for: sessionID) }
        .onDisappear { chatRuns.watchedIDs.remove(sessionID) }
        .onChange(of: chatRuns.snapshot(for: sessionID)?.phase) { _, _ in absorbEndedRun() }
        .onChange(of: featureModelSettings.settingsRevision) { _, _ in
            applyChatModelDefault()
        }
        .onChange(of: agentRegistrySettings.resolvedControllerID) { _, _ in
            guard !featureModelSettings.hasFeatureOverride(for: .chat),
                  !featureModelSettings.hasGlobalOverride else { return }
            applyChatModelDefault()
        }
        // Push picker changes down into the LLM service (model + backend).
        .onChange(of: modelSelectionKey) { _, newValue in
            guard let llmService else { return }
            WorkspaceModelSelection.apply(
                selectionKey: newValue,
                to: llmService,
                providerSettings: providerSettings
            )
        }
        .onDisappear {
            voiceService.setAudioIssueHandler(nil)
            audioIssueClearTask?.cancel()
            audioIssue = nil
        }
    }

    /// Scrolling transcript that auto-pins to the bottom as messages arrive.
    ///
    /// Renders persisted bubbles, then transient affordances layered on top: the
    /// streaming assistant bubble (with a blinking caret while generating), the
    /// agent's current tool status, and any generation error.
    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    // Persisted conversation history.
                    ForEach(messages, id: \.id) { message in
                        ChatBubble(message: message)
                            .id(message.id)
                            .overlay(alignment: .bottomTrailing) {
                                if message.id == latestAssistantMessageID, voiceService.isAvailable {
                                    Button {
                                        if voiceReplay.canReplay {
                                            replayLastSpokenReply()
                                        } else {
                                            playAloud(message.content)
                                        }
                                    } label: {
                                        Label("Replay last reply", systemImage: "speaker.wave.2")
                                    }
                                    .labelStyle(.iconOnly)
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel("Replay last reply")
                                    .accessibilityIdentifier("chat-message-replay-button")
                                    .offset(x: -4, y: 14)
                                }
                            }
                            .contextMenu {
                                if message.role == "assistant", voiceService.isAvailable {
                                    Button {
                                        playAloud(message.content)
                                    } label: {
                                        Label("Play Aloud", systemImage: "speaker.wave.2")
                                    }
                                }
                                WorkspaceTextShareLink(
                                    title: WorkspaceShareContent.messageShareTitle(
                                        role: message.role,
                                        content: message.content
                                    ),
                                    text: message.content,
                                    accessibilityIdentifier: "share-chat-message-\(message.id)"
                                )
                            }
                    }
                    // Live response being streamed; caret blinks while generating.
                    if let streamingReasoning, !streamingReasoning.isEmpty {
                        let hasContent = !(streamingText ?? "")
                            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        let presentation = ThinkingSectionPolicy.presentation(
                            hasReasoning: true,
                            hasContent: hasContent,
                            isStreaming: isGenerating,
                            userExpanded: userExpandedThinking,
                            durationSeconds: thinkingDurationSeconds
                        )
                        ThinkingDisclosure(
                            title: thinkingTitle(for: presentation),
                            text: streamingReasoning,
                            isExpanded: thinkingExpansionBinding
                        )
                        .id("streaming-thinking")
                    }
                    if let streamingText {
                        let visible = streamingText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if visible.isEmpty && isGenerating && (streamingReasoning ?? "").isEmpty {
                            Label("Waiting for the model…", systemImage: "hourglass")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .id("streaming")
                        } else if !visible.isEmpty {
                            StreamingBubble(text: streamingText + (isGenerating ? " ▍" : ""))
                                .id("streaming")
                        }
                    }
                    if !toolEvents.isEmpty {
                        AgentToolTraceView(chips: toolEvents)
                            .id("tool-trace")
                    }
                    // Agent progress line (current tool / partial output).
                    if let run = centerRun, !run.isRunning {
                        if !run.text.isEmpty {
                            StreamingBubble(text: run.text)
                                .id("stopped-partial")
                        }
                        HStack(spacing: 12) {
                            Label(run.statusMessage ?? "Stopped", systemImage: "pause.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("chat-run-stopped-message")
                            if run.canResume {
                                Button("Resume") { resumeStoppedReply() }
                                    .accessibilityIdentifier("chat-run-resume-button")
                            }
                        }
                    }
                    if let agentStatus, toolEvents.isEmpty {
                        let isWebSearch = agentStatus == ChatWebSearchPolicy.searchingStatus
                        Label(agentStatus, systemImage: isWebSearch ? "globe" : "gearshape.2")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    // Inline error if generation failed.
                    if let generationError {
                        StatusMessage(kind: .error, text: generationError)
                    }
                    if showToolFormatHint {
                        VStack(alignment: .leading, spacing: 8) {
                            StatusMessage(
                                kind: .info,
                                text: ToolFormatFallbackCopy.message(model: toolFormatHintModel)
                            )
                            Button(ToolFormatFallbackCopy.changeButtonTitle) {
                                SettingsOpenRequest.post(
                                    page: .aiModels,
                                    connectionID: toolFormatHintConnectionID
                                )
                            }
                            .accessibilityIdentifier("change-tool-format")
                        }
                        .accessibilityIdentifier("tool-format-hint")
                    }
                    if let audioIssue {
                        StatusMessage(kind: .info, text: audioIssue)
                    }
                    if isVoiceControlMode {
                        voiceControlStatusLabel
                        // No echo cancellation (or the engine's echo check
                        // failed): barge-in is off; the user taps to interrupt.
                        if let hint = VoiceRouteMonitor.interruptHint {
                            Text(hint)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("chat-voice-interrupt-off")
                        }
                    }
                    if showsVoiceContinuePrompt {
                        VoiceContinuePromptView(
                            onYes: { voiceSession.answerContinue(true) },
                            onNo: { voiceSession.answerContinue(false) }
                        )
                    }
                    // Driven by the controller: set when an interruption
                    // (incoming call) stopped voice, cleared by the next mic
                    // tap or by leaving the chat.
                    if let voiceInterruptionNotice {
                        Text(voiceInterruptionNotice)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("chat-voice-interruption-notice")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    // While the continue prompt is up only its buttons answer.
                    if (isSpeaking || isAwaitingSpokenAudio), !showsVoiceContinuePrompt {
                        bargeInSpokenReply()
                    }
                }
            }
            .workspaceEdgeToEdgeScrollContent()
            // Keep the latest content visible as the transcript grows or streams.
            .onChange(of: messages.count) { _, _ in scrollToBottom(proxy: proxy) }
            .onChange(of: streamingText) { _, _ in scrollToBottom(proxy: proxy) }
            .onChange(of: toolEvents.count) { _, _ in scrollToBottom(proxy: proxy) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("chat-message-list")
    }

    /// Toolbar: choose the model and open the shared Options view.
    @ToolbarContentBuilder
    private var chatToolbar: some ToolbarContent {
        if ChatWebSearchPolicy.shouldShowToolbarGlobe(isAllowed: allowChatWebSearch) {
            ToolbarItem(placement: .automatic) {
                Image(systemName: "globe")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(ChatWebSearchPolicy.toolbarGlobeAccessibilityLabel)
                    .accessibilityIdentifier("chat-web-search-active")
            }
        }

        ToolbarItem(placement: .automatic) {
            WorkspaceModelPicker(
                label: "Model",
                selectionKey: $modelSelectionKey,
                providerSettings: providerSettings,
                accessibilityIdentifier: "chat-model-picker",
                pickerScope: .chatRecent
            )
        }

        ToolbarItem(placement: .automatic) {
            WorkspaceModelOptionsButton(
                selectionKey: modelSelectionKey,
                accessibilityIdentifier: "chat-model-options"
            )
        }

        ToolbarItem(placement: .primaryAction) {
            WorkspaceTextShareLink(
                title: sessionTitle,
                text: chatShareText,
                accessibilityIdentifier: "share-chat-button"
            )
        }
    }

    /// Whole-conversation payload for the system share sheet.
    private var chatShareText: String {
        WorkspaceShareContent.chatPlainText(
            title: sessionTitle,
            messages: messages.map { (role: $0.role, content: $0.content) }
        )
    }

    /// True when the chosen chat model is billed to a signed-in ChatGPT plan.
    private var selectedModelUsesChatGPTPlan: Bool {
        guard let connectionID = ConfiguredModelRegistry.parseSelectionKey(modelSelectionKey)?.connectionID,
              let connection = providerSettings.connection(id: connectionID) else {
            return false
        }
        return connection.usesChatGPTAccount && connection.chatgptPlanEligible == true
    }

    /// Bottom composer pinned beneath the transcript: voice, optional photo
    /// attachment for image models, text field, and send.
    private var composerBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if selectedModelUsesChatGPTPlan {
                ChatGPTPlanInUseLabel()
                    .padding(.horizontal, 4)
            }

            if let attachedGalleryImage, let repositories {
                HStack(spacing: 8) {
                    WorkspaceFileImage(url: repositories.gallery.imageFileURL(for: attachedGalleryImage))
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    Text(attachedGalleryImage.caption?.isEmpty == false
                         ? attachedGalleryImage.caption!
                         : "Photo attached — describe the change")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Remove") {
                        self.attachedGalleryImage = nil
                    }
                    .font(.caption)
                }
                .padding(.horizontal, 4)
            }

            if isVoiceControlMode {
                // A sheet with its own stack: pushing the voice list inside the
                // chat (from a composer row that disappears with voice mode)
                // left Back popping into a torn-down source view.
                Button {
                    showVoiceSettings = true
                } label: {
                    Label("Voice settings", systemImage: "person.wave.2")
                        .font(.caption)
                }
                .accessibilityIdentifier("chat-voice-settings-button")
            }

            HStack(alignment: .bottom, spacing: 10) {
                voiceControlButton

                if voiceReplay.canReplay, !isAwaitingSpokenAudio {
                    Button {
                        replayLastSpokenReply()
                    } label: {
                        Label("Replay last reply", systemImage: "arrow.counterclockwise")
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityLabel("Replay last reply")
                    .accessibilityIdentifier("chat-voice-replay-button")
                }

                if selectedImageGenerationModelID != nil {
                    Button {
                        showGalleryImagePicker = true
                    } label: {
                        Label(
                            attachedGalleryImage == nil ? "Choose photo" : "Change photo",
                            systemImage: attachedGalleryImage == nil ? "photo" : "photo.fill"
                        )
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityIdentifier("chat-attach-image-button")
                    .help("Select a gallery photo to send to the image model and change.")
                }

                ChatComposerField(text: $draft, onSend: { sendMessage() }, isFocused: $composerFocused)

                Button {
                    if isGenerating {
                        stopGeneration()
                    } else {
                        sendMessage()
                    }
                } label: {
                    Label(isGenerating ? "Stop" : "Send", systemImage: isGenerating ? "stop.fill" : "paperplane.fill")
                }
                .labelStyle(.iconOnly)
                .accessibilityIdentifier(isGenerating ? "chat-stop-button" : "chat-send-button")
                // Return is handled by the composer, which sends. Binding it here
                // makes the same key hit Stop once generation starts, which closes
                // the LM Studio socket during prefill.
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!isGenerating && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .workspaceComposerBar()
    }

    /// The session's display name, used as the navigation title.
    private var sessionTitle: String {
        guard let repositories else { return "Chat" }
        return (try? repositories.sessions.fetchSession(id: sessionID)?.name) ?? "Chat"
    }

    /// macOS navigation subtitle combining the chosen model and its load status.
    private var modelStatusLine: String {
        guard let llmService else { return "No model" }
        if let choice = ConfiguredModelRegistry.choice(
            forSelectionKey: modelSelectionKey,
            providerSettings: providerSettings
        ) {
            return "\(choice.pickerLabel) · \(llmService.loadStatus)"
        }
        return llmService.loadStatus
    }

    private func applyChatModelDefault() {
        WorkspaceModelSelection.applyFeatureDefault(
            for: .chat,
            selectionKey: &modelSelectionKey,
            featureModelSettings: featureModelSettings,
            providerSettings: providerSettings,
            agentSettings: agentRegistrySettings,
            llmService: llmService
        )
    }

    /// Reloads the persisted transcript for this session from storage.
    private func reload() {
        guard let repositories else { return }
        let fetched = (try? repositories.sessions.messages(for: sessionID)) ?? []
        messages = fetched.map(ChatMessageSnapshot.init)
    }

    /// Combines prior agent-round prose with the active round's streaming text.
    private static func composeAgentStream(completed: [String], current: String) -> String {
        let parts = completed + (current.isEmpty ? [] : [current])
        return parts.joined(separator: "\n\n")
    }

    /// Scrolls to the streaming bubble while generating, otherwise to the last message.
    private func scrollToBottom(proxy: ScrollViewProxy) {
        if streamingText != nil {
            proxy.scrollTo("streaming", anchor: .bottom)
        } else if let last = messages.last {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }

    private func sendMessage(text overrideText: String? = nil, speakResponse: Bool = false) {
        submitTurn(text: overrideText, speakResponse: speakResponse)
    }

    /// The one submit point for typed and spoken turns. Persists the user
    /// message and clears the composer immediately, then runs the agent loop
    /// (always on) or image generation through the chat's run center, which
    /// cancels any running reply first. A spoken utterance is submitted at
    /// most once.
    @discardableResult
    private func submitTurn(text overrideText: String? = nil, speakResponse: Bool = false, utteranceID: Int? = nil) -> Bool {
        guard let repositories else { return false }
        let text = (overrideText ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        // A typed Return while generating is ignored (the button is Stop); a
        // spoken turn interrupts the running reply.
        guard utteranceID != nil || !isGenerating else { return false }
        let sourceImage = overrideText == nil ? attachedGalleryImage : nil
        let isImage = selectedImageGenerationModelID != nil
        let speak = speakResponse || isVoiceControlMode
        // The voice session this reply belongs to: once it ends (Stop, Back,
        // background, interruption) the reply may not speak or re-arm audio.
        let turn = replySpeech.nextTurn(voiceSession: voiceSession.sessionToken)
        return ChatTurnSubmitter.chat.submit(
            chatID: sessionID,
            text: text,
            utteranceID: utteranceID,
            execution: isImage ? .cloud : RunExecution(selectionKey: modelSelectionKey),
            record: {
                if isGenerating { stopGeneration() }
                // Block a second Return before the generation task body runs.
                isGenerating = true
                replySpeech.adopt(turn)
                if isVoiceControlMode { voiceSession.turnStarted() }
                // Name new conversations by the prompt they begin with.
                renameSessionFromFirstUserRequestIfNeeded(text)
                if overrideText == nil {
                    draft = ""
                    attachedGalleryImage = nil
                }
                generationError = nil
                showToolFormatHint = false
                agentStatus = nil
                toolEvents = []
                _ = try? repositories.sessions.addMessage(sessionID: sessionID, role: "user", content: text)
                if let sourceImage,
                   let message = try? repositories.sessions.messages(for: sessionID).last {
                    message.metadata = ChatMessageGalleryMetadata.encode(galleryImageID: sourceImage.id)
                    try? repositories.sessions.save()
                }
                reload()
                onUpdated()
                generationTask?.cancel()
                generationTask = nil
            }
        ) { _ in
            defer { replySpeech.cleanUp(turn) { voiceSession.replyFinished() } }
            if isImage {
                await generateImageResponse(for: text, sourceImage: sourceImage)
            } else {
                await generateAgentResponse(
                    for: text,
                    speakResponse: speak,
                    turn: turn
                )
            }
            try Task.checkCancellation()
        }
    }

    /// Reloads when this chat's run finished while the view was away or rebuilt.
    private func absorbEndedRun() {
        guard let run = chatRuns.snapshot(for: sessionID) else { return }
        if run.phase == .finished {
            chatRuns.dismiss(id: sessionID)
            reload()
            onUpdated()
        }
    }

    /// Resumes a reply that stopped when the app left the foreground.
    private func resumeStoppedReply() {
        generationError = nil
        chatRuns.resume(id: sessionID)
    }

    /// The picked model's id when it is a remote image-generation model
    /// (e.g. `dall-e-3`, `gpt-image-1`); `nil` for conversational models.
    private var selectedImageGenerationModelID: String? {
        guard let parsed = ConfiguredModelRegistry.parseSelectionKey(modelSelectionKey),
              parsed.backend == .remote,
              OpenAICompatibleAPI.isImageGenerationModel(parsed.modelID) else {
            return nil
        }
        return parsed.modelID
    }

    /// The remote service that can reach the images endpoint, unwrapped from a
    /// composite backend when needed.
    private var resolvedRemoteLLMService: RemoteLLMService? {
        if let remote = llmService as? RemoteLLMService { return remote }
        if let composite = llmService as? AgentRemoteLLMProviding { return composite.remoteServiceForAgent }
        return nil
    }

    /// Generates a new image, or edits an attached gallery photo, then stores
    /// the result in the photos gallery database and records a confirmation.
    private func generateImageResponse(for prompt: String, sourceImage: GalleryImage?) async {
        guard let repositories else { return }
        guard let remote = resolvedRemoteLLMService, let modelID = selectedImageGenerationModelID else {
            generationError = "Image generation requires a remote connection."
            return
        }

        isGenerating = true
        streamingText = sourceImage == nil
            ? "Generating image with \(modelID)…"
            : "Changing the selected photo with \(modelID)…"
        defer {
            isGenerating = false
            streamingText = nil
            generationTask = nil
        }

        do {
            try await prepareLLMForChat()
            let imageData: Data
            if let sourceImage {
                let fileURL = repositories.gallery.imageFileURL(for: sourceImage)
                let sourceData = try Data(contentsOf: fileURL)
                imageData = try await remote.editImage(
                    prompt: prompt,
                    imageData: sourceData,
                    filename: sourceImage.filename,
                    modelID: modelID
                )
            } else {
                imageData = try await remote.generateImage(prompt: prompt, modelID: modelID)
            }
            if Task.isCancelled { return }
            FeatureSettings.enableGallery()
            let album = try GeneratedImagesAlbum.findOrCreate(in: repositories.gallery)
            let saved = try repositories.gallery.importImage(
                albumID: album.id,
                data: imageData,
                suggestedFilename: ImageGenerationCatalog.filename(for: prompt),
                caption: prompt
            )
            FeatureSettings.noteGalleryContentChanged()
            let savedToPhotos = await SystemPhotoLibrary.saveImageIfAllowed(
                imageData,
                albumName: album.name
            )
            let confirmation = sourceImage == nil
                ? (savedToPhotos
                    ? "Generated an image with \(modelID) and saved it to the “\(album.name)” album in Photos."
                    : "Generated an image with \(modelID) and saved it to the in-app Photos gallery (“\(album.name)”).")
                : (savedToPhotos
                    ? "Changed the selected photo with \(modelID) and saved the result to the “\(album.name)” album in Photos."
                    : "Changed the selected photo with \(modelID) and saved the result to the in-app Photos gallery (“\(album.name)”).")
            if let message = try? repositories.sessions.addMessage(
                sessionID: sessionID,
                role: "assistant",
                content: confirmation
            ) {
                message.metadata = ChatMessageGalleryMetadata.encode(galleryImageID: saved.id)
                try? repositories.sessions.save()
            }
            reload()
            onUpdated()
        } catch is CancellationError {
            return
        } catch {
            generationError = error.localizedDescription
        }
    }


    /// Whether a reply's turn still owns speech: it is the newest turn and
    /// its voice session (if any) has not ended. Cleanup and speech of an
    /// older run never touch the newer reply (B2, B3).
    private func ownsSpeech(_ turn: VoiceReplyTurn) -> Bool {
        replySpeech.owns(turn, isSessionLive: { voiceSession.isLive(sessionToken: $0) })
    }

    private func stopGeneration() {
        generationTask?.cancel()
        generationTask = nil
        chatRuns.stop(id: sessionID)
        chatRuns.dismiss(id: sessionID)
        isGenerating = false
        streamingText = nil
        agentStatus = nil
        voiceService.cancelSpeech()
        isSpeaking = false
        isAwaitingSpokenAudio = false
    }

    private var isSpokenReplyInterruptible: Bool {
        isVoiceControlMode && (isSpeaking || isAwaitingSpokenAudio)
    }

    /// App-wide session controller for this voice service.
    private var voiceSession: VoiceSessionController {
        VoiceSessionControllers.controller(for: voiceService)
    }

    private var voiceControlButton: some View {
        VoiceMicButton(
            session: voiceSession,
            isSpokenReplyInterruptible: isSpokenReplyInterruptible,
            showsInterruptHint: VoiceEchoPolicy.shouldShowInterruptHint(
                speechBargeInEnabled: voiceService.isSpeechBargeInEnabled
            ),
            isEnabled: voiceService.supportsLiveInput
        ) {
            if isSpokenReplyInterruptible || (isVoiceControlMode && isGenerating) {
                bargeInSpokenReply()
            } else {
                toggleVoiceControl()
            }
        }
    }

    /// "Would you like me to continue?" is up: speech barged in on a reply.
    private var showsVoiceContinuePrompt: Bool {
        voiceSessionState == .pausedAwaitingContinue || VoiceContinuePromptView.forcedForUITest
    }

    /// Tap or a new mic trigger stops the current spoken reply mid-stream.
    /// While the continue prompt is up, Stop means No.
    @MainActor
    private func bargeInSpokenReply() {
        if voiceSessionState == .pausedAwaitingContinue {
            voiceSession.answerContinue(false) // → onReplyDiscarded
            return
        }
        stopSpokenReplyAndResumeListening()
    }

    /// Stops the reply (text and audio) and returns voice control to listening.
    @MainActor
    private func stopSpokenReplyAndResumeListening() {
        guard isSpeaking || isAwaitingSpokenAudio || isGenerating else { return }
        stopGeneration()
        voiceSession.replyFinished()
    }

    private var voiceControlStatusLabel: some View {
        Group {
            if voiceSessionState == .starting {
                Label("Starting voice control…", systemImage: "mic")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("chat-voice-status-starting")
            } else if voiceSessionState == .pausedAwaitingContinue {
                Label("Paused", systemImage: "pause.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("chat-voice-status-paused")
            } else if isSpeaking {
                Label("Speaking", systemImage: "speaker.wave.2.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHint("Tap to interrupt")
                    .onTapGesture { bargeInSpokenReply() }
            } else if isAwaitingSpokenAudio || isGenerating {
                Label("Thinking…", systemImage: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if voiceService.isListening {
                Label("Voice control — listening… pause when done, then ask another.", systemImage: "mic.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                Label("Voice control active — tap mic to exit.", systemImage: "mic.badge.plus")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func handleVoiceScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            if VoiceLifecyclePolicy.shouldResumeListening(
                reason: .sceneForeground,
                voiceControlArmed: isVoiceControlMode
            ) {
                Task {
                    if VoiceConnectionPolicy.shouldWarm(voiceOutputEnabled: true, trigger: .foregroundWithVoiceOn) {
                        await voiceService.prepareSpokenConversation()
                    }
                    voiceSession.setSceneActive(true)
                }
            }
        case .inactive:
            if VoiceLifecyclePolicy.shouldPauseListening(reason: .sceneInactive) {
                voiceSession.setSceneActive(false)
            }
        case .background:
            if VoiceLifecyclePolicy.shouldPauseListening(reason: .sceneBackground) {
                voiceSession.setSceneActive(false)
            }
            if VoiceLifecyclePolicy.shouldTeardownConversation(reason: .sceneBackground) {
                // Never tear down inline in the scene-phase callback.
                voiceSession.enterBackground()
            }
        default:
            break
        }
    }

    /// Tap to enter voice-control mode; tap again to exit (or to cancel while
    /// starting). The session controller owns the pipeline: this only sends
    /// commands, so no tap ever waits on audio setup or teardown.
    @MainActor
    private func toggleVoiceControl() {
        guard voiceService.supportsLiveInput else {
            generationError = "Voice input is not available on this device."
            return
        }
        let session = voiceSession
        if !session.state.isActive {
            VoiceAudioDebugStore.append(
                event: "voice.toggle.on",
                detail: "provider=\(voiceService.providerName) available=\(voiceService.isAvailable) liveInput=\(voiceService.supportsLiveInput)"
            )
            generationError = nil
            session.onTurn = { utterance in
                submitTurn(text: utterance.text, speakResponse: true, utteranceID: utterance.id)
            }
            session.onReplyDiscarded = { stopSpokenReplyAndResumeListening() }
        }
        session.toggleMic()
    }

    /// Renames a placeholder chat to the first user request, leaving existing
    /// conversations and manually renamed chats untouched.
    private func renameSessionFromFirstUserRequestIfNeeded(_ request: String) {
        guard let repositories,
              let session = try? repositories.sessions.fetchSession(id: sessionID),
              session.name == "New Chat" else { return }

        let existingMessages = (try? repositories.sessions.messages(for: sessionID)) ?? []
        let hasUserMessage = existingMessages.contains { $0.role == "user" }
        guard !hasUserMessage else { return }

        let title = Self.chatTitle(from: request)
        guard !title.isEmpty else { return }
        try? repositories.sessions.renameSession(id: sessionID, name: title)
    }

    private static func chatTitle(from request: String) -> String {
        let singleLine = request
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init) ?? request
        let trimmed = singleLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 60 else { return trimmed }
        let end = trimmed.index(trimmed.startIndex, offsetBy: 60)
        return String(trimmed[..<end]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    /// Arms progressive TTS so assistant tokens can be spoken as they stream in.
    /// Ownership is rechecked after `prepareSpokenConversation`: a Stop,
    /// Back or interruption during that await must not re-arm the session
    /// or engine (B2).
    private func beginStreamingSpeechIfNeeded(speakResponse: Bool, turn: VoiceReplyTurn) async -> Bool {
        guard speakResponse, voiceService.isAvailable else { return false }
        return await replySpeech.beginSpeech(
            for: turn,
            isSessionLive: { voiceSession.isLive(sessionToken: $0) },
            prepare: {
                VoicePreviewService.shared.stop()
                await voiceService.prepareSpokenConversation()
            },
            arm: {
                voiceService.setPlaybackStartedHandler {
                    Task { @MainActor in
                        isAwaitingSpokenAudio = false
                        isSpeaking = true
                    }
                }
                voiceService.beginSpokenTurn()
                voiceService.beginStreamingSpeech()
                isAwaitingSpokenAudio = true
                isSpeaking = false
            },
            release: {
                // The session ended during the await: undo what prepare set
                // up, unless a new voice session is already live.
                if !voiceSession.state.isActive { voiceService.endSpokenConversation() }
            }
        )
    }

    /// Waits for streamed TTS to finish speaking the cumulative assistant text.
    private func finishStreamingSpeechIfNeeded(cumulative: String, enabled: Bool) async {
        guard enabled, isSpeaking || isAwaitingSpokenAudio else { return }
        defer {
            isSpeaking = false
            isAwaitingSpokenAudio = false
            _ = voiceService.endSpokenTurn()
        }
        voiceReplay.record(cumulative)
        do {
            try await voiceService.finishStreamingSpeech(cumulative)
        } catch {
            generationError = error.localizedDescription
        }
    }

    /// Replays the last spoken reply: cached audio first (instant, no new
    /// synthesis), text re-synthesis as a fallback. Stops anything playing.
    @MainActor
    private func replayLastSpokenReply() {
        guard let text = voiceReplay.lastReply else { return }
        voiceService.cancelSpeech()
        Task { @MainActor in
            if await voiceService.replayLastReply() { return }
            await speakAloud(text)
        }
    }

    /// Speaks arbitrary message text (Play Aloud), stopping current playback.
    @MainActor
    private func playAloud(_ text: String) {
        voiceService.cancelSpeech()
        Task { @MainActor in await speakAloud(text) }
    }

    @MainActor
    private func speakAloud(_ text: String) async {
        isSpeaking = true
        defer { isSpeaking = false }
        do {
            try await voiceService.speak(text: text)
        } catch {
            generationError = error.localizedDescription
        }
    }

    private var latestAssistantMessageID: ChatMessageSnapshot.ID? {
        messages.last(where: { $0.role == "assistant" })?.id
    }

    /// Returns the injected agent loop, or lazily builds one from available
    /// services so chats still run tools when no shared instance was provided.
    private var resolvedAgentLoopService: AgentLoopService? {
        if let agentLoopService { return agentLoopService }
        guard let repositories, let memoryService, let llmService else { return nil }
        return AgentLoopService(
            llmService: llmService,
            repositories: repositories,
            memoryService: memoryService
        )
    }

    private func chatWebSearchBackend() -> ChatWebSearchBackend {
        let parsed = ConfiguredModelRegistry.parseSelectionKey(modelSelectionKey)
        let connectionID = parsed?.connectionID
        let baseURL = connectionID.flatMap { providerSettings.connection(id: $0)?.trimmedBaseURL }
            ?? providerSettings.resolvedConnection()?.trimmedBaseURL
        return ChatWebSearchPolicy.backend(
            isAllowed: allowChatWebSearch,
            engine: chatWebSearchEngine,
            baseURL: baseURL
        )
    }

    /// Applies the picker's model/backend choice and loads the model before a send.
    private func prepareLLMForChat() async throws {
        guard let llmService else {
            throw LLMServiceError.generationFailed("LLM service not configured.")
        }

        WorkspaceModelSelection.apply(
            selectionKey: modelSelectionKey,
            to: llmService,
            providerSettings: providerSettings
        )
        try await llmService.loadSelectedModel()
    }

    /// Retrieves long-term memories relevant to the prompt and formats them as a system message.
    private func recallMemoryContext(for prompt: String) async -> String? {
        guard let memoryService else { return nil }
        let results = (try? await memoryService.search(query: prompt, topK: 5)) ?? []
        guard !results.isEmpty else { return nil }

        let lines = results.map { "- \($0.memory.text)" }
        return """
        Relevant long-term memories about the user (use them when helpful, ignore if unrelated):
        \(lines.joined(separator: "\n"))
        """
    }

    /// Runs the tool-using agent loop and persists its final answer.
    ///
    /// Consumes the loop's event stream — streaming tokens update the live bubble,
    /// tool start/result events drive the status line — and only the `finished`
    /// content is written back as the assistant turn. The `defer` block guarantees
    /// transient generation state is cleared on every exit path.
    private func generateAgentResponse(for prompt: String, speakResponse: Bool = false, turn: VoiceReplyTurn) async {
        guard let repositories, let memoryService else {
            generationError = "Agent dependencies not configured."
            return
        }
        guard let agentLoop = resolvedAgentLoopService else {
            generationError = "Agent loop service not configured."
            return
        }

        isGenerating = true
        streamingText = ""
        streamingReasoning = nil
        thinkingExpanded = true
        userExpandedThinking = false
        thinkingDurationSeconds = nil
        var thinkingStartedAt: Date?
        defer {
            // A cancelled older run must not clear the newer reply's state.
            if replySpeech.isCurrent(turn) {
                isGenerating = false
                streamingText = nil
                streamingReasoning = nil
                agentStatus = nil
                generationTask = nil
            }
        }

        do {
            try await prepareLLMForChat()
        } catch {
            generationError = error.localizedDescription
            return
        }

        if Task.isCancelled { return }

        let history = messages
            .filter { $0.role == "user" || $0.role == "assistant" }
            .map { LLMChatTurn(role: $0.role, content: $0.content) }

        var persona = chatPromptSettings.effectiveChatSystemPrompt ?? ""
        if let memoryContext = await recallMemoryContext(for: prompt) {
            if persona.isEmpty {
                persona = memoryContext
            } else {
                persona += "\n\n" + memoryContext
            }
        }

        let context = AgentContext(
            sessionID: sessionID,
            repositories: repositories,
            memoryService: memoryService
        )

        var finalResponse = ""
        var completedStreamSegments: [String] = []
        var currentRoundStream = ""
        // Batches live-bubble updates at sentence/newline boundaries so the
        // screen is not re-rendered for every streamed token (battery).
        var displayBatcher = StreamingTextBatcher()
        var speechEnabled = await beginStreamingSpeechIfNeeded(speakResponse: speakResponse, turn: turn)
        /// The voice session ended (or a newer turn took over) mid-reply:
        /// stop speaking for good; the text keeps streaming.
        func speechStillOwned() -> Bool {
            guard speechEnabled else { return false }
            guard ownsSpeech(turn) else {
                speechEnabled = false
                if replySpeech.isCurrent(turn) {
                    voiceService.cancelSpeech()
                    isSpeaking = false
                    isAwaitingSpokenAudio = false
                    _ = voiceService.endSpokenTurn()
                }
                return false
            }
            return true
        }
        var markedFirstToken = false
        var collectedCitations: [ChatWebSearchCitation] = []
        var webSearchFailed = false
        var usedWebSearch = false
        var webSearchFallbackNotice: String?
        var persistedSearchEngine: ChatWebSearchEngine?
        toolEvents = []
        let searchBackend = chatWebSearchBackend()
        let parsed = ConfiguredModelRegistry.parseSelectionKey(modelSelectionKey)
        let connectionID = parsed?.connectionID
        let baseURL = connectionID.flatMap { providerSettings.connection(id: $0)?.trimmedBaseURL }
            ?? providerSettings.resolvedConnection()?.trimmedBaseURL
        let effectiveEngine = ChatWebSearchPolicy.effectiveEngine(
            isAllowed: allowChatWebSearch,
            selected: chatWebSearchEngine,
            baseURL: baseURL
        )
        var extraRuntimeTools: [any AgentTool] = []
        if searchBackend == .appSearch, let webSearchService {
            extraRuntimeTools = [
                ChatWebSearchTool(
                    search: webSearchService,
                    engine: effectiveEngine,
                    braveAPIKey: RemoteAPIKeyStore().apiKey(for: AIDataAccess.braveSearchKeyAccount),
                    searxBaseURL: AIDataAccess.searxBaseURL
                ),
            ]
        }
        for await event in agentLoop.run(
            prompt: prompt,
            history: history,
            context: context,
            personaPrompt: persona.nilIfEmpty,
            extraStructuredTools: ChatWebSearchPolicy.extraStructuredTools(backend: searchBackend),
            extraRuntimeTools: extraRuntimeTools,
            extraSystemNote: ChatWebSearchPolicy.systemNote(backend: searchBackend, engine: effectiveEngine)
        ) {
            if Task.isCancelled { break }
            // The reply keeps generating after Back, but stops feeding TTS
            // once the chat is off screen (#176 tore voice down already).
            speechEnabled = VoiceLifecyclePolicy.shouldKeepSpeakingReply(
                speechEnabled: speechEnabled,
                chatOnScreen: chatRuns.watchedIDs.contains(sessionID)
            )
            switch event {
            case .reasoning(let thought):
                if thinkingStartedAt == nil { thinkingStartedAt = Date() }
                streamingReasoning = (streamingReasoning ?? "") + thought
            case .token(let text):
                currentRoundStream += text
                if thinkingStartedAt != nil, thinkingDurationSeconds == nil, !text.isEmpty {
                    let ended = Date()
                    thinkingDurationSeconds = ended.timeIntervalSince(thinkingStartedAt ?? ended)
                    if ThinkingSectionPolicy.shouldForceCollapse(
                        hasContent: true,
                        userExpanded: userExpandedThinking
                    ) {
                        thinkingExpanded = false
                    }
                }
                if speechEnabled, !markedFirstToken, !text.isEmpty {
                    markedFirstToken = true
                    voiceService.markSpokenTurn(.firstLLMToken)
                }
                let composed = Self.composeAgentStream(
                    completed: completedStreamSegments,
                    current: currentRoundStream
                )
                if let snapshot = displayBatcher.displayText(for: composed) {
                    streamingText = snapshot
                    runHandle?.update(text: snapshot)
                }
                if speechStillOwned() {
                    // Cumulative visible text (StreamTextCodec increments already
                    // concatenated) so the chunker never sees snapshot prefixes.
                    voiceService.appendStreamingSpeech(currentRoundStream)
                }
            case .toolStart(let name, let input):
                if speechStillOwned() {
                    voiceService.checkpointStreamingSpeech(currentRoundStream)
                }
                let trimmedRound = currentRoundStream.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedRound.isEmpty {
                    completedStreamSegments.append(currentRoundStream)
                    currentRoundStream = ""
                }
                // Tool boundaries always refresh the screen immediately.
                let composed = Self.composeAgentStream(
                    completed: completedStreamSegments,
                    current: currentRoundStream
                )
                streamingText = composed
                runHandle?.update(text: composed)
                displayBatcher.markDisplayed(composed)
                toolEvents.append(AgentToolChip(name: name, input: input, output: nil, isRunning: true))
                if name == ChatWebSearchPolicy.fallbackToolName {
                    agentStatus = ChatWebSearchPolicy.searchingStatus
                } else {
                    agentStatus = "Running \(name)…"
                }
                runHandle?.update(status: agentStatus)
            case .toolResult(let name, let output):
                if let index = toolEvents.lastIndex(where: { $0.name == name && $0.isRunning }) {
                    toolEvents[index].output = output
                    toolEvents[index].isRunning = false
                }
                if name == ChatWebSearchPolicy.fallbackToolName,
                   let engine = ChatWebSearchPolicy.parseActualEngine(from: output) {
                    persistedSearchEngine = engine
                }
            case .searchingWeb:
                usedWebSearch = true
                agentStatus = ChatWebSearchPolicy.searchingStatus
            case .webSearchCitations(let citations):
                collectedCitations = citations
                usedWebSearch = usedWebSearch || !citations.isEmpty
            case .webSearchFailed:
                webSearchFailed = true
                usedWebSearch = false
            case .webSearchNotice(let notice):
                webSearchFallbackNotice = notice
                usedWebSearch = true
            case .finished(let content):
                finalResponse = content
            case .paused(_, let partial):
                if !partial.isEmpty {
                    finalResponse = partial
                }
            case .error(let message):
                generationError = message
            case .toolFormatHint(let model, let connectionID):
                showToolFormatHint = true
                toolFormatHintModel = model
                toolFormatHintConnectionID = connectionID
            }
        }

        if Task.isCancelled {
            // Only this run's own speech: a newer turn may already be speaking.
            if replySpeech.isCurrent(turn) {
                voiceService.cancelSpeech()
                isSpeaking = false
                isAwaitingSpokenAudio = false
                _ = voiceService.endSpokenTurn()
            }
            return
        }

        // Flush any trailing text below the last display boundary.
        streamingText = displayBatcher.finish(
            Self.composeAgentStream(completed: completedStreamSegments, current: currentRoundStream)
        )

        let persisted = finalResponse.nilIfEmpty
            ?? completedStreamSegments.joined(separator: "\n\n").nilIfEmpty
            ?? currentRoundStream.nilIfEmpty
        if let persisted, !persisted.isEmpty {
            let textCitations = ChatWebSearchPolicy.parseCitations(from: persisted)
            var seen = Set(collectedCitations.map(\.url))
            for citation in textCitations where seen.insert(citation.url).inserted {
                collectedCitations.append(citation)
            }
            if !collectedCitations.isEmpty {
                usedWebSearch = true
            }
            let alreadyShowedQuickFacts = messages.contains {
                ChatWebSearchPolicy.isQuickFactsHint($0.webSearchFallbackNotice)
            }
            if ChatWebSearchPolicy.isQuickFactsHint(webSearchFallbackNotice), alreadyShowedQuickFacts {
                webSearchFallbackNotice = nil
            }
            let showOffHint = ChatWebSearchPolicy.shouldShowOffHint(
                isAllowed: allowChatWebSearch,
                userPrompt: prompt,
                assistantReply: persisted
            )
            var metadata = ChatWebSearchPolicy.mergeMetadata(
                existing: nil,
                citations: collectedCitations,
                usedWebSearch: usedWebSearch && !webSearchFailed,
                showOffHint: showOffHint,
                searchFailed: webSearchFailed,
                fallbackNotice: webSearchFallbackNotice,
                actualEngine: persistedSearchEngine
            )
            if let reasoning = streamingReasoning?.trimmingCharacters(in: .whitespacesAndNewlines),
               !reasoning.isEmpty,
               reasoning != persisted {
                let seconds = thinkingDurationSeconds
                    ?? thinkingStartedAt.map { Date().timeIntervalSince($0) }
                metadata = ThinkingSectionPolicy.mergeReasoning(
                    existing: metadata,
                    reasoning: reasoning,
                    durationSeconds: seconds
                )
            }
            if let message = try? repositories.sessions.addMessage(
                sessionID: sessionID,
                role: "assistant",
                content: persisted
            ) {
                if let metadata {
                    message.metadata = metadata
                    try? repositories.sessions.save()
                }
            }
            reload()
            onUpdated()
        }

        // Finish TTS with the exact text that was streamed to it. The `finished`
        // content can be reformatted (tool fences stripped, whitespace trimmed),
        // and handing the speech pipeline a diverged transcript made it re-speak
        // the whole reply. Fall back to the final content only when nothing was
        // streamed at all; after a checkpoint (tool round) the earlier rounds
        // have already been spoken in full.
        let spokenSource = currentRoundStream.nilIfEmpty
            ?? (completedStreamSegments.isEmpty ? finalResponse : "")
            await finishStreamingSpeechIfNeeded(
                cumulative: spokenSource,
                enabled: VoiceLifecyclePolicy.shouldKeepSpeakingReply(
                    speechEnabled: speechStillOwned(),
                    chatOnScreen: chatRuns.watchedIDs.contains(sessionID)
                )
            )
    }

    private var thinkingExpansionBinding: Binding<Bool> {
        Binding(
            get: { thinkingExpanded },
            set: { newValue in
                thinkingExpanded = newValue
                if newValue { userExpandedThinking = true }
            }
        )
    }

    private func thinkingTitle(for presentation: ThinkingSectionPolicy.Presentation) -> String {
        switch presentation {
        case .hidden, .streaming:
            return ThinkingSectionPolicy.streamingTitle
        case .collapsed(let label), .expanded(let label):
            return label
        }
    }
}

/// A single persisted message bubble, aligned right for the user and left for the
/// assistant, with a role caption and selectable body text.
private struct ChatBubble: View {
    let message: ChatMessageSnapshot
    @Environment(\.repositories) private var repositories
    @AppStorage(AIDataAccess.chatWebSearchKey) private var allowChatWebSearch = false
    @State private var thinkingExpanded = false
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == "user" { Spacer(minLength: 48) }
            VStack(alignment: message.role == "user" ? .trailing : .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(message.role == "user" ? "You" : "Assistant")
                        .font(AnAIOdysseyFont.metadata.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if message.usedWebSearch {
                        Image(systemName: "globe")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(ChatWebSearchPolicy.usedWebSearchAccessibilityLabel)
                    }
                }
                if message.webSearchFailed {
                    Text(ChatWebSearchPolicy.searchUnreachableLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("chat-web-search-failed")
                } else if let notice = message.webSearchFallbackNotice {
                    if ChatWebSearchPolicy.isQuickFactsHint(notice) {
                        Button {
                            #if os(macOS)
                            openSettings()
                            #endif
                            SettingsOpenRequest.post(page: .privacy, focus: .braveSearchKey)
                        } label: {
                            Text(notice)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("chat-web-search-quick-facts")
                    } else {
                        Text(notice)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("chat-web-search-fallback")
                    }
                }
                if message.role == "assistant",
                   let reasoning = message.reasoning,
                   !reasoning.isEmpty {
                    ThinkingDisclosure(
                        title: ThinkingSectionPolicy.persistedTitle(
                            durationSeconds: message.thoughtDurationSeconds
                        ),
                        text: reasoning,
                        isExpanded: $thinkingExpanded
                    )
                }
                VStack(alignment: .leading, spacing: 8) {
                    if let galleryImageID = message.galleryImageID,
                       let repositories,
                       let image = try? repositories.gallery.fetchImage(id: galleryImageID) {
                        WorkspaceFileImage(url: repositories.gallery.imageFileURL(for: image))
                            .frame(maxWidth: 280, maxHeight: 280)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    PlainMessageContentView(content: message.content)
                    if message.webSearchEngine == .brave, message.usedWebSearch {
                        Text(ChatWebSearchPolicy.braveAttributionLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("chat-web-search-brave-attribution")
                    }
                    if !message.citations.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(message.citations) { citation in
                                if let url = URL(string: citation.url) {
                                    Link(destination: url) {
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(citation.title)
                                                .font(.caption.weight(.semibold))
                                            Text(citation.domain)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .accessibilityIdentifier("chat-web-search-citation")
                                }
                            }
                        }
                    }
                    if !allowChatWebSearch && message.showWebSearchOffHint {
                        HStack(spacing: 8) {
                            Text(ChatWebSearchPolicy.offHintText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button(ChatWebSearchPolicy.turnOnButtonTitle) {
                                #if os(macOS)
                                openSettings()
                                #endif
                                SettingsOpenRequest.post(page: .privacy)
                            }
                            .font(.caption.weight(.semibold))
                            .accessibilityIdentifier("chat-web-search-turn-on")
                        }
                        .accessibilityIdentifier("chat-web-search-off-hint")
                    }
                }
                .padding(10)
                .workspaceChatBubbleBackground(role: message.role)
            }
            if message.role == "assistant" { Spacer(minLength: 48) }
        }
    }
}

/// Transient bubble that displays the assistant's response as it streams in,
/// always styled and aligned like a completed assistant message.
private struct StreamingBubble: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Assistant")
                    .font(AnAIOdysseyFont.metadata.weight(.semibold))
                    .foregroundStyle(.secondary)
                PlainMessageContentView(content: text)
                    .padding(10)
                    .workspaceChatBubbleBackground(role: "assistant")
            }
            Spacer(minLength: 48)
        }
    }
}

private struct AgentToolChip: Identifiable {
    let id = UUID()
    let name: String
    let input: String
    var output: String?
    var isRunning: Bool
}

private struct AgentToolTraceView: View {
    let chips: [AgentToolChip]
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(chips) { chip in
                DisclosureGroup {
                    if !chip.input.isEmpty {
                        Text(chip.input)
                            .font(.caption)
                            .foregroundStyle(AegeanColors.secondaryLabel(colorScheme))
                    }
                    if let output = chip.output, !output.isEmpty {
                        Text(output)
                            .font(.caption)
                            .foregroundStyle(AegeanColors.label(colorScheme))
                            .padding(.top, chip.input.isEmpty ? 0 : 4)
                    } else if chip.isRunning {
                        Text("Running…")
                            .font(.caption)
                            .foregroundStyle(AegeanColors.secondaryLabel(colorScheme))
                    }
                } label: {
                    HStack(spacing: 6) {
                        if chip.isRunning {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(AegeanColors.aiViolet(colorScheme))
                        }
                        Text(chip.name)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AegeanColors.aiViolet(colorScheme))
                    }
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(AegeanColors.aiViolet(colorScheme).opacity(0.08))
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Picks a photo from the in-app gallery database to send to an image model.
private struct GalleryImagePickerSheet: View {
    @Binding var selectedImage: GalleryImage?
    @Environment(\.repositories) private var repositories
    @Environment(\.dismiss) private var dismiss
    @State private var albums: [Album] = []
    @State private var selectedAlbumID: String?
    @State private var images: [GalleryImage] = []

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if albums.isEmpty {
                    ContentUnavailableView(
                        "No Photos",
                        systemImage: "photo.on.rectangle.angled",
                        description: Text("Import or generate photos in Gallery first.")
                    )
                } else {
                    Picker("Album", selection: $selectedAlbumID) {
                        ForEach(albums, id: \.id) { album in
                            Text(album.name).tag(Optional(album.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .padding()

                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 10)], spacing: 10) {
                            ForEach(images, id: \.id) { image in
                                Button {
                                    selectedImage = image
                                    dismiss()
                                } label: {
                                    if let repositories {
                                        WorkspaceFileImage(url: repositories.gallery.imageFileURL(for: image))
                                            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 100, maxHeight: 100)
                                            .clipped()
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                    }
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("chat-pick-gallery-image-\(image.id)")
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Choose Photo")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear(perform: reload)
            .onChange(of: selectedAlbumID) { _, _ in
                reloadImages()
            }
        }
        .frame(minWidth: 420, minHeight: 420)
    }

    private func reload() {
        guard let repositories else { return }
        albums = (try? repositories.gallery.listAlbums()) ?? []
        if selectedAlbumID == nil {
            selectedAlbumID = albums.first?.id
        }
        reloadImages()
    }

    private func reloadImages() {
        guard let repositories, let selectedAlbumID else {
            images = []
            return
        }
        images = (try? repositories.gallery.listImages(albumID: selectedAlbumID)) ?? []
    }
}

/// Collapsible model-reasoning block. Live turns start open; persisted turns
/// start collapsed on the timed "Thought for N seconds" label.
private struct ThinkingDisclosure: View {
    let title: String
    let text: String
    @Binding var isExpanded: Bool

    var body: some View {
        DisclosureGroup(title, isExpanded: $isExpanded) {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("chat-thinking-disclosure")
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Which turn a reply belongs to: its submit token and the voice session
/// (if any) that was live when it was submitted.
typealias VoiceReplyTurn = VoiceReplySpeechOwner.Turn
