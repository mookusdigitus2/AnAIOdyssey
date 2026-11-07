// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import AnAIOdysseyAI
import AnAIOdysseyCore
import AIModelOptions
import SwiftUI

/// The Research workspace: run web-grounded research queries and continue them as
/// threaded follow-up conversations.
///
/// The sidebar lists saved reports; the detail pane swaps between three modes —
/// composing a brand-new query, watching a query stream live, or browsing a saved
/// report and asking follow-ups. Results stream incrementally from the
/// `ResearchService`, with a status line surfacing which model is in use.
///
/// On iPhone, a nested `NavigationSplitView` never shows the detail column, so
/// iOS uses a `NavigationStack` that pushes compose/session screens instead.
struct ResearchView: View {
    /// Service that runs/continues research and persists reports.
    @Environment(\.researchService) private var researchService
    /// Provider configuration used to resolve the chosen model into a run config.
    @EnvironmentObject private var providerSettings: ProviderSettings
    @EnvironmentObject private var agentRegistrySettings: AgentRegistrySettings
    @EnvironmentObject private var featureModelSettings: FeatureModelSettings

    /// Saved reports backing the sidebar list.
    @State private var reports: [ResearchReport] = []
    /// Currently selected saved report, if any.
    @State private var selectedReportID: String?
    /// Whether the detail pane is in "new query" compose mode.
    @State private var composingNewResearch = false

    /// Draft text for a new research topic.
    @State private var query = ""
    /// Draft text for a follow-up question on the selected report.
    @State private var followUp = ""
    /// Encoded model+backend choice from the toolbar picker.
    @State private var modelSelectionKey = ""
    /// Whether report text is rendered as formatted markdown or shown as source.
    @AppStorage("anaiodyssey.research.markdownPreview") private var markdownPreview = true

    /// App-level owner of running research, so a run survives leaving the tab,
    /// popping the session or closing a sheet.
    @ObservedObject private var runCenter = ResearchRunCenter.shared
    /// Surfaces a run failure in the detail pane.
    @State private var errorMessage: String?
    /// Report awaiting delete confirmation.
    @State private var reportPendingDeletion: ResearchReport?
    /// Focus state for the follow-up composer.
    @FocusState private var followUpFocused: Bool
    #if os(iOS)
    /// iPhone navigation stack path (compose + saved sessions).
    @State private var iosNavigationPath = NavigationPath()
    #endif

    /// Run-center id for a brand-new query (no report exists until it finishes).
    static let newRunID = ResearchRunIDs.newQuery

    /// True while any research/follow-up run is streaming.
    private var isRunning: Bool { runCenter.activeRunCount > 0 }
    /// Report a follow-up is streaming into (`nil` for a new query).
    private var runningReportID: String? {
        runCenter.activeRuns.first { $0.id != Self.newRunID }?.id
    }
    /// The new-query run, while running or after it stopped/failed partway.
    private var newQueryRun: RunSnapshot? { runCenter.snapshot(for: Self.newRunID) }
    /// Run shown in the session view for a saved report.
    private func followUpRun(for reportID: String) -> RunSnapshot? {
        guard let run = runCenter.snapshot(for: reportID), run.phase != .finished else { return nil }
        return run
    }
    /// Whether the new-query live view should be shown instead of compose.
    private var showsNewQueryRun: Bool {
        guard let run = newQueryRun else { return false }
        return run.phase != .finished
    }

    var body: some View {
        #if os(macOS)
        macResearchBody
        #else
        iosResearchBody
        #endif
    }

    // MARK: - macOS split view

    private var macResearchBody: some View {
        NavigationSplitView {
            reportSidebar
        } detail: {
            macDetailContent
                .workspaceFillDetailPane()
        }
        .removeNestedSidebarToggle()
        .workspaceNavigationSplit()
        .researchLifecycleModifiers(
            reload: reload,
            applyResearchModelDefault: applyResearchModelDefault,
            featureModelSettings: featureModelSettings,
            agentRegistrySettings: agentRegistrySettings,
            selectedReportID: $selectedReportID,
            isRunning: isRunning,
            runningReportID: runningReportID,
            errorMessage: $errorMessage,
            composingNewResearch: $composingNewResearch
        )
        .onAppear(perform: applyPendingResearchOpen)
        .onAppear(perform: absorbEndedRuns)
        .onChange(of: runCenter.runs) { _, _ in absorbEndedRuns() }
        .onReceive(NotificationCenter.default.publisher(for: WorkspaceOpenRequest.notification)) { _ in
            applyPendingResearchOpen()
        }
        .destructiveDeleteAlert(
            "Delete Report?",
            item: $reportPendingDeletion,
            message: { report in
                "“\(report.query)” will be permanently deleted."
            },
            confirmAction: deleteReport
        )
    }

    @ViewBuilder
    private var macDetailContent: some View {
        if showsNewQueryRun && composingNewResearch {
            streamingDetail
        } else if composingNewResearch || selectedReportID == nil {
            composeDetail
        } else if let selectedReportID,
                  let report = reports.first(where: { $0.id == selectedReportID }) {
            sessionDetail(report)
        } else {
            composeDetail
        }
    }

    // MARK: - iOS stack navigation

    #if os(iOS)
    private var iosResearchBody: some View {
        NavigationStack(path: $iosNavigationPath) {
            reportSidebar
                .navigationDestination(for: ResearchRoute.self) { route in
                    iosDestination(for: route)
                        .workspaceFillDetailPane()
                }
        }
        .researchLifecycleModifiers(
            reload: reload,
            applyResearchModelDefault: applyResearchModelDefault,
            featureModelSettings: featureModelSettings,
            agentRegistrySettings: agentRegistrySettings,
            selectedReportID: $selectedReportID,
            isRunning: isRunning,
            runningReportID: runningReportID,
            errorMessage: $errorMessage,
            composingNewResearch: $composingNewResearch
        )
        .onChange(of: iosNavigationPath.count) { _, count in
            if count == 0 {
                composingNewResearch = false
            }
        }
        .onAppear(perform: applyPendingResearchOpen)
        .onAppear(perform: absorbEndedRuns)
        .onChange(of: runCenter.runs) { _, _ in absorbEndedRuns() }
        .onReceive(NotificationCenter.default.publisher(for: WorkspaceOpenRequest.notification)) { _ in
            applyPendingResearchOpen()
        }
        .destructiveDeleteAlert(
            "Delete Report?",
            item: $reportPendingDeletion,
            message: { report in
                "“\(report.query)” will be permanently deleted."
            },
            confirmAction: deleteReport
        )
    }

    @ViewBuilder
    private func iosDestination(for route: ResearchRoute) -> some View {
        switch route {
        case .compose:
            if showsNewQueryRun {
                streamingDetail
            } else {
                composeDetail
            }
        case .report(let id):
            if let report = reports.first(where: { $0.id == id }) {
                sessionDetail(report)
            } else {
                composeDetail
            }
        }
    }
    #endif

    /// Saved-report list shared by macOS sidebar and iOS root stack.
    private var reportSidebar: some View {
        Group {
            #if os(macOS)
            List(selection: $selectedReportID) {
                reportRows
            }
            #else
            List {
                reportRows
            }
            #endif
        }
        .macWorkspaceSplit()
        .navigationTitle("Research")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    startNewResearch()
                } label: {
                    Label("New Research", systemImage: "plus")
                }
                .workspaceActionButtonTint()
                .accessibilityIdentifier("new-research-button")
            }
            #if os(macOS)
            ToolbarItem(placement: .destructiveAction) {
                Button("Delete", role: .destructive) {
                    if let selectedReportID,
                       let report = reports.first(where: { $0.id == selectedReportID }) {
                        reportPendingDeletion = report
                    }
                }
                .workspaceActionButtonTint(destructive: true)
                .disabled(selectedReportID == nil)
            }
            #endif
        }
    }

    @ViewBuilder
    private var reportRows: some View {
        if let run = newQueryRun, run.phase != .finished {
            Group {
                #if os(macOS)
                Button { composingNewResearch = true; selectedReportID = nil } label: {
                    SidebarListRow(title: run.title, subtitle: run.statusMessage ?? "Researching…", secondaryLine: nil)
                }
                .buttonStyle(.plain)
                #else
                NavigationLink(value: ResearchRoute.compose) {
                    SidebarListRow(title: run.title, subtitle: run.statusMessage ?? "Researching…", secondaryLine: nil)
                }
                .simultaneousGesture(TapGesture().onEnded { composingNewResearch = true })
                #endif
            }
            .runRowAccessory(run, center: runCenter)
            .accessibilityIdentifier("research-running-row")
        }
        if reports.isEmpty && newQueryRun == nil {
            WorkspaceEmptyListLabel(text: "No research sessions yet")
        } else {
            ForEach(reports, id: \.id) { report in
                Group {
                    #if os(macOS)
                    SidebarListRow(
                        title: report.query,
                        subtitle: report.createdAt.formatted(date: .abbreviated, time: .shortened),
                        secondaryLine: threadPreview(for: report)
                    )
                    .tag(report.id)
                    #else
                    NavigationLink(value: ResearchRoute.report(report.id)) {
                        SidebarListRow(
                            title: report.query,
                            subtitle: report.createdAt.formatted(date: .abbreviated, time: .shortened),
                            secondaryLine: threadPreview(for: report)
                        )
                    }
                    #endif
                }
                .runRowAccessory(followUpRun(for: report.id), center: runCenter)
                .contextMenu {
                    Button("Delete", role: .destructive) {
                        reportPendingDeletion = report
                    }
                }
            }
            #if os(macOS)
            .onDelete(perform: deleteReports)
            #endif
        }
    }

    /// Accessibility ID for the model picker, distinct for the new-query vs.
    /// follow-up contexts so UI tests can target the right one.
    private var researchModelPickerID: String {
        if composingNewResearch || selectedReportID == nil {
            "research-model-picker"
        } else {
            "research-followup-model-picker"
        }
    }

    /// New-query form: a topic field, a run button, and model/error status.
    private var composeDetail: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Research Topic")
                        .font(AnAIOdysseyFont.listTitle)
                    TextField("What would you like to research?", text: $query, axis: .vertical)
                        .lineLimit(2...6)
                        .workspaceFormField()
                        .accessibilityIdentifier("research-query-field")

                    Button(isRunning ? "Researching..." : "Run Research") {
                        runNewResearch()
                    }
                    .disabled(isRunning || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("run-research-button")

                    if let errorMessage {
                        StatusMessage(kind: .error, text: errorMessage)
                    }
                    Text(PrivacyDisclosures.researchRunsWhileOpen)
                        .font(AnAIOdysseyFont.metadata)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("research-runs-while-open-footer")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .workspaceEdgeToEdgeScrollContent()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("New Research")
        .toolbar { researchDetailToolbar }
    }

    /// Shared toolbar across all detail modes: the research model picker, the
    /// shared Options view, and the markdown preview toggle.
    @ToolbarContentBuilder
    private var researchDetailToolbar: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            WorkspaceModelPicker(
                label: "Model",
                selectionKey: $modelSelectionKey,
                providerSettings: providerSettings,
                accessibilityIdentifier: researchModelPickerID,
                pickerScope: .chatRecent
            )
        }

        ToolbarItem(placement: .automatic) {
            WorkspaceModelOptionsButton(
                selectionKey: modelSelectionKey,
                accessibilityIdentifier: "research-model-options"
            )
        }

        // Markdown preview toggle: render reports as formatted text or source.
        ToolbarItem(placement: .automatic) {
            Toggle(isOn: $markdownPreview) {
                Label("Markdown Preview", systemImage: "richtext.page")
            }
            .toggleStyle(.button)
            .help(markdownPreview ? "Show markdown source" : "Render markdown preview")
            .accessibilityIdentifier("research-markdown-preview-toggle")
        }
    }

    /// Live view shown while a brand-new query streams: the topic plus the growing
    /// summary (with a loading placeholder until the first tokens arrive).
    private var streamingDetail: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(newQueryRun?.title ?? query)
                        .font(AnAIOdysseyFont.detailSubtitle)
                    let run = newQueryRun
                    let text = run?.text ?? ""
                    if text.isEmpty, run?.isRunning == true {
                        Text("Loading AI model and gathering sources...")
                            .foregroundStyle(.secondary)
                    } else {
                        PlainMessageContentView(content: text + (run?.isRunning == true ? " ▍" : ""))
                    }
                    if let status = run?.status {
                        Text(status)
                            .font(AnAIOdysseyFont.metadata)
                            .foregroundStyle(.secondary)
                    }
                    if let run {
                        RunStateControls(run: run, center: runCenter)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .workspaceEdgeToEdgeScrollContent()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(newQueryRun?.isRunning == true ? "Researching" : "Research")
        .onAppear { runCenter.watchedIDs.insert(Self.newRunID) }
        .onDisappear { runCenter.watchedIDs.remove(Self.newRunID) }
        .toolbar { researchDetailToolbar }
    }

    /// Browsing view for a saved report: the original query, the threaded Q&A, a
    /// live follow-up bubble while streaming, the cited sources, and a follow-up
    /// composer pinned to the bottom.
    private func sessionDetail(_ report: ResearchReport) -> some View {
        // Decode persisted sources/thread and detect whether a follow-up is
        // currently streaming into this specific report.
        let sources = ResearchService.decodeSources(from: report)
        let thread = ResearchService.decodeThread(from: report)
        let liveRun = followUpRun(for: report.id)
        let isStreamingFollowUp = liveRun != nil

        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(report.query)
                        .font(AnAIOdysseyFont.detailSubtitle)

                    // Persisted conversation thread.
                    ForEach(thread) { entry in
                        ResearchThreadBubble(entry: entry, renderMarkdown: markdownPreview)
                    }

                    // Live follow-up answer streaming in (caret while in progress).
                    // Streaming text stays plain: re-parsing markdown per token
                    // is wasted work and the layout would jump around.
                    if isStreamingFollowUp {
                        ResearchThreadBubble(
                            entry: ResearchThreadEntry(
                                role: "assistant",
                                content: (liveRun?.text ?? "").isEmpty
                                    ? (liveRun?.isRunning == true ? "Loading AI model and gathering sources..." : "")
                                    : (liveRun?.text ?? "") + (liveRun?.isRunning == true ? " ▍" : "")
                            ),
                            renderMarkdown: false
                        )
                    }

                    if let status = liveRun?.status {
                        Text(status)
                            .font(AnAIOdysseyFont.metadata)
                            .foregroundStyle(.secondary)
                    }
                    if let liveRun {
                        RunStateControls(run: liveRun, center: runCenter)
                    }

                    // Cited sources, hidden while a follow-up is still streaming.
                    if !sources.isEmpty, !isStreamingFollowUp {
                        Divider()
                        Text("Sources")
                            .font(AnAIOdysseyFont.listTitle)
                        if sources.contains(where: { $0.engine == ChatWebSearchEngine.brave.rawValue }) {
                            Text(ChatWebSearchPolicy.braveAttributionLine)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("research-brave-attribution")
                        }
                        ForEach(sources) { source in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(source.title)
                                    .font(.subheadline.bold())
                                Text(source.url)
                                    .font(AnAIOdysseyFont.metadata)
                                    .foregroundStyle(.secondary)
                                if !source.snippet.isEmpty {
                                    Text(source.snippet)
                                        .font(AnAIOdysseyFont.metadata)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }

                    if let errorMessage {
                        StatusMessage(kind: .error, text: errorMessage)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .workspaceEdgeToEdgeScrollContent()
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Follow-up composer pinned to the bottom of the session view.
            HStack(alignment: .bottom, spacing: 10) {
                ChatComposerField(
                    text: $followUp,
                    placeholder: "Ask a follow-up question...",
                    onSend: { runFollowUp(on: report) },
                    isFocused: $followUpFocused
                )
                .accessibilityIdentifier("research-followup-field")

                Button {
                    runFollowUp(on: report)
                } label: {
                    Label("Ask", systemImage: "paperplane.fill")
                }
                .labelStyle(.iconOnly)
                .disabled(isRunning || followUp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("research-followup-button")
            }
            .workspaceComposerBar()
        }
        .navigationTitle("Research Session")
        .onAppear { runCenter.watchedIDs.insert(report.id) }
        .onDisappear { runCenter.watchedIDs.remove(report.id) }
        .toolbar { researchDetailToolbar }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                WorkspaceTextShareLink(
                    title: report.query.isEmpty ? "Research" : report.query,
                    text: researchShareText(for: report, sources: sources, thread: thread),
                    accessibilityIdentifier: "share-research-button"
                )
            }
        }
    }

    /// Plain-text research result for the system share sheet.
    private func researchShareText(
        for report: ResearchReport,
        sources: [ResearchSource],
        thread: [ResearchThreadEntry]
    ) -> String {
        WorkspaceShareContent.researchPlainText(
            query: report.query,
            summary: report.summary,
            thread: thread.map { (role: $0.role, content: $0.content) },
            sources: sources.map { (title: $0.title, url: $0.url, snippet: $0.snippet) }
        )
    }

    /// Sidebar third line showing message count once a report has follow-ups.
    private func threadPreview(for report: ResearchReport) -> String? {
        let count = ResearchService.decodeThread(from: report).count
        guard count > 2 else { return nil }
        return "\(count) messages"
    }

    private func applyPendingResearchOpen() {
        guard let request = WorkspaceOpenRequest.takePending(kind: .research) else { return }
        composingNewResearch = false
        selectedReportID = request.itemID
        #if os(iOS)
        iosNavigationPath = NavigationPath([ResearchRoute.report(request.itemID)])
        #endif
    }

    /// Switches the detail pane into compose mode and clears any drafts/state.
    private func startNewResearch() {
        composingNewResearch = true
        selectedReportID = nil
        query = ""
        followUp = ""
        errorMessage = nil
        if newQueryRun?.isRunning == false {
            runCenter.dismiss(id: Self.newRunID)
        }
        #if os(iOS)
        iosNavigationPath = NavigationPath([ResearchRoute.compose])
        #endif
    }

    /// Reloads saved reports and auto-selects the newest unless composing.
    private func reload() {
        guard let researchService else { return }
        reports = (try? researchService.listReports()) ?? []
        if selectedReportID == nil, !composingNewResearch, let first = reports.first?.id {
            selectedReportID = first
        }
    }

    private func applyResearchModelDefault() {
        WorkspaceModelSelection.applyFeatureDefault(
            for: .research,
            selectionKey: &modelSelectionKey,
            featureModelSettings: featureModelSettings,
            providerSettings: providerSettings,
            agentSettings: agentRegistrySettings
        )
    }

    /// Starts a new research run in the app-level ``BackgroundRunCenter`` and
    /// streams the summary into the live view. The run belongs to the app, so
    /// leaving the tab or popping this screen doesn't lose it; on finish the
    /// view (whichever instance is alive) reloads and selects the new report.
    private func runNewResearch() {
        guard let researchService else { return }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isRunning else { return }

        let configuration = WorkspaceModelSelection.configuration(
            from: modelSelectionKey,
            providerSettings: providerSettings
        )

        composingNewResearch = true
        errorMessage = nil
        selectedReportID = nil

        runCenter.start(
            id: Self.newRunID,
            title: trimmed,
            execution: RunExecution(selectionKey: modelSelectionKey)
        ) { handle in
            try await Self.consume(researchService.runResearch(query: trimmed, configuration: configuration), into: handle)
        }
    }

    /// Streams a follow-up answer into an existing report's thread via the
    /// run center (keyed by report id).
    private func runFollowUp(on report: ResearchReport) {
        guard let researchService else { return }
        let trimmed = followUp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isRunning else { return }

        let configuration = WorkspaceModelSelection.configuration(
            from: modelSelectionKey,
            providerSettings: providerSettings
        )

        errorMessage = nil
        followUp = ""
        let reportID = report.id
        runCenter.start(
            id: reportID,
            title: trimmed,
            execution: RunExecution(selectionKey: modelSelectionKey)
        ) { handle in
            try await Self.consume(
                researchService.continueResearch(reportID: reportID, followUp: trimmed, configuration: configuration),
                into: handle
            )
        }
    }

    /// Feeds a research chunk stream into a run handle: "Using …" chunks update
    /// the status line, the rest accrue (batched at sentence boundaries).
    @MainActor
    static func consume(_ stream: AsyncThrowingStream<String, Error>, into handle: RunHandle) async throws {
        var rawSummary = ""
        var displayBatcher = StreamingTextBatcher()
        for try await chunk in stream {
            try Task.checkCancellation()
            if chunk.hasPrefix("Using ") {
                handle.update(status: chunk.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            rawSummary += chunk
            if let snapshot = displayBatcher.displayText(for: rawSummary) {
                handle.update(text: snapshot)
            }
        }
        handle.update(text: displayBatcher.finish(rawSummary))
    }

    /// Picks up runs that finished while this view was away (or just now):
    /// reloads, selects the new report, and forgets the finished run.
    private func absorbEndedRuns() {
        var reloaded = false
        for run in runCenter.runs.values where run.phase == .finished {
            if !reloaded { reload(); reloaded = true }
            if run.id == Self.newRunID {
                let wasWatching = composingNewResearch
                runCenter.dismiss(id: run.id)
                if wasWatching, let newest = reports.first {
                    composingNewResearch = false
                    query = ""
                    selectedReportID = newest.id
                    #if os(iOS)
                    iosNavigationPath = NavigationPath([ResearchRoute.report(newest.id)])
                    #endif
                }
            } else {
                runCenter.dismiss(id: run.id)
            }
        }
    }

    /// Swipe-to-delete handler mapping list offsets to reports.
    private func deleteReports(at offsets: IndexSet) {
        for index in offsets {
            deleteReport(reports[index])
        }
    }

    /// Deletes a report and tidies any selection/streaming state pointing at it.
    private func deleteReport(_ report: ResearchReport) {
        guard let researchService else { return }
        try? researchService.deleteReport(id: report.id)
        if selectedReportID == report.id {
            selectedReportID = nil
            composingNewResearch = true
            #if os(iOS)
            iosNavigationPath = NavigationPath()
            #endif
        }
        if runCenter.snapshot(for: report.id) != nil {
            runCenter.stop(id: report.id)
            runCenter.dismiss(id: report.id)
        }
        reportPendingDeletion = nil
        reload()
    }
}

private enum ResearchRoute: Hashable {
    case compose
    case report(String)
}

private extension View {
    func researchLifecycleModifiers(
        reload: @escaping () -> Void,
        applyResearchModelDefault: @escaping () -> Void,
        featureModelSettings: FeatureModelSettings,
        agentRegistrySettings: AgentRegistrySettings,
        selectedReportID: Binding<String?>,
        isRunning: Bool,
        runningReportID: String?,
        errorMessage: Binding<String?>,
        composingNewResearch: Binding<Bool>
    ) -> some View {
        onAppear {
            reload()
            applyResearchModelDefault()
        }
        .onChange(of: featureModelSettings.settingsRevision) { _, _ in
            applyResearchModelDefault()
        }
        .onChange(of: agentRegistrySettings.resolvedControllerID) { _, _ in
            guard !featureModelSettings.hasFeatureOverride(for: .research),
                  !featureModelSettings.hasGlobalOverride else { return }
            applyResearchModelDefault()
        }
        .onChange(of: selectedReportID.wrappedValue) { _, newValue in
            if newValue != nil {
                composingNewResearch.wrappedValue = false
            }
            if !isRunning || runningReportID != newValue {
                errorMessage.wrappedValue = nil
            }
        }
    }
}

/// A single message bubble in a research thread, aligned right for the user and
/// left for the research assistant, mirroring the chat bubble styling.
private struct ResearchThreadBubble: View {
    let entry: ResearchThreadEntry
    /// When true, assistant reports render as formatted markdown; user
    /// questions always stay plain.
    var renderMarkdown = false

    var body: some View {
        HStack(alignment: .top) {
            if entry.role == "assistant" { Spacer(minLength: 32) }
            VStack(alignment: entry.role == "user" ? .trailing : .leading, spacing: 4) {
                Text(entry.role == "user" ? "You" : "Research")
                    .font(AnAIOdysseyFont.metadata.weight(.semibold))
                    .foregroundStyle(.secondary)
                Group {
                    if renderMarkdown && entry.role == "assistant" {
                        MarkdownContentView(content: entry.content)
                    } else {
                        PlainMessageContentView(content: entry.content)
                    }
                }
                .padding(10)
                .workspaceChatBubbleBackground(role: entry.role)
            }
            if entry.role == "user" { Spacer(minLength: 32) }
        }
    }
}
