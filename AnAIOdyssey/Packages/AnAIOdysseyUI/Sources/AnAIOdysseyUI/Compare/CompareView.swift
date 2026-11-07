// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import AnAIOdysseyAI
import AnAIOdysseyCore
import SwiftUI

/// The Compare workspace: run the same prompt against two or more models and
/// vote when exactly two text models ran, optionally blind.
///
/// The sidebar lists saved comparisons; the detail pane either composes a new
/// comparison or shows two side-by-side responses with voting. In blind mode the
/// model identities are hidden (and their A/B positions shuffled) until the user
/// votes, so the choice isn't biased by model names.
struct CompareView: View {
    /// Service that runs comparisons, records votes, and persists results.
    @Environment(\.compareService) private var compareService
    /// Provider configuration used to resolve the selected models.
    @EnvironmentObject private var providerSettings: ProviderSettings
    @Environment(\.localModelManager) private var localModelManager
    /// Saved comparisons backing the sidebar.
    @State private var comparisons: [Comparison] = []
    /// Currently selected saved comparison, if any.
    @State private var selectedComparisonID: String?
    /// Draft prompt for a new comparison.
    @State private var prompt = ""
    /// Models chosen in the searchable multi-select. Compare has no default.
    @State private var selectedModelKeys: Set<String> = []
    /// Cached unfiltered catalog; rebuilt on appear / connection change, not in `body`.
    @State private var compareChoices: [ConfiguredModelChoice] = []
    /// Whether the new comparison hides model identities until voting.
    @State private var isBlind = true
    /// The just-run comparison shown before it becomes a normal selection.
    @State private var activeComparison: Comparison?
    /// True while a comparison is being generated.
    @State private var isRunning = false
    /// Surfaces run failures.
    @State private var errorMessage: String?
    /// Comparison awaiting delete confirmation.
    @State private var comparisonPendingDeletion: Comparison?
    /// Text tile opened full-screen so a long answer can be read without clipping.
    @State private var expandedCompareTile: ExpandedCompareTile?
    /// Whether the detail pane is in "new comparison" compose mode.
    @State private var composingNewComparison = false
    #if os(iOS)
    /// iPhone portrait is compact; a nested split view can't show its detail
    /// column there, so we fall back to push navigation.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var isCompact: Bool { horizontalSizeClass == .compact }
    #else
    private var isCompact: Bool { false }
    #endif

    /// Split layout: saved comparisons on the leading side, compose/result detail
    /// on the trailing side, plus the delete-confirmation alert.
    var body: some View {
        layout
            .onAppear {
                reload()
                reloadCompareChoices()
            }
            .onChange(of: providerSettings.remoteConnections) { _, _ in
                reloadCompareChoices()
            }
            .destructiveDeleteAlert(
                "Delete Comparison?",
                item: $comparisonPendingDeletion,
                message: { comparison in
                    "“\(comparison.prompt)” will be permanently deleted."
                },
                confirmAction: deleteComparison
            )
    }

    /// Split view (macOS / iPad / iPhone landscape) or push navigation (iPhone
    /// portrait), where a nested split view can't reveal its detail column.
    @ViewBuilder
    private var layout: some View {
        #if os(iOS)
        if isCompact {
            compactBody
        } else {
            splitBody
        }
        #else
        splitBody
        #endif
    }

    private var splitBody: some View {
        NavigationSplitView {
            comparisonSidebar
        } detail: {
            detailContent
                .workspaceFillDetailPane()
        }
        .removeNestedSidebarToggle()
        .workspaceNavigationSplit()
    }

    #if os(iOS)
    /// iPhone portrait: the saved-comparison list is the root; composing or
    /// selecting pushes the detail.
    ///
    /// No `NavigationStack` of its own: the Library tab's stack (in
    /// `PhoneRootView`) hosts the push, so there is exactly one navigation bar
    /// and one Back path.
    private var compactBody: some View {
        comparisonSidebar
            .navigationDestination(isPresented: compactDetailPresented) {
                detailContent
                    .workspaceFillDetailPane()
            }
    }

    /// Present the pushed detail whenever there is something to show; clearing it
    /// on pop resets the compose/selection state back to the list.
    private var compactDetailPresented: Binding<Bool> {
        Binding(
            get: { activeComparison != nil || composingNewComparison || selectedComparisonID != nil },
            set: { presented in
                if !presented {
                    activeComparison = nil
                    composingNewComparison = false
                    selectedComparisonID = nil
                }
            }
        )
    }
    #endif

    /// The saved-comparison sidebar list, shared by both layouts.
    private var comparisonSidebar: some View {
        List(selection: $selectedComparisonID) {
            if comparisons.isEmpty {
                WorkspaceEmptyListLabel(text: "No comparisons yet")
            } else {
                ForEach(comparisons, id: \.id) { comparison in
                    SidebarListRow(
                        title: comparison.prompt,
                        subtitle: comparisonSubtitle(comparison)
                    )
                    .tag(comparison.id)
                    .contextMenu {
                        Button("Delete", role: .destructive) {
                            comparisonPendingDeletion = comparison
                        }
                    }
                }
                .onDelete(perform: deleteComparisons)
            }
        }
        .macWorkspaceSplit()
        .navigationTitle("Compare")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    startNewComparison()
                } label: {
                    Label("New Comparison", systemImage: "plus")
                }
                .workspaceActionButtonTint()
                .accessibilityIdentifier("new-compare-button")
            }
            ToolbarItem(placement: .destructiveAction) {
                Button("Delete", role: .destructive) {
                    if let selectedComparisonID,
                       let comparison = comparisons.first(where: { $0.id == selectedComparisonID }) {
                        comparisonPendingDeletion = comparison
                    }
                }
                .workspaceActionButtonTint(destructive: true)
                .disabled(selectedComparisonID == nil)
            }
        }
    }

    /// Chooses which detail screen to render based on selection and compose state.
    @ViewBuilder
    private var detailContent: some View {
        if let activeComparison {
            comparisonDetail(activeComparison, revealModels: false)
        } else if composingNewComparison || selectedComparisonID == nil {
            composeDetail
        } else if let selectedComparisonID,
                  let comparison = comparisons.first(where: { $0.id == selectedComparisonID }) {
            comparisonDetail(comparison, revealModels: comparison.votedAt != nil || !comparison.isBlind)
        } else {
            composeDetail
        }
    }

    /// Sidebar subtitle: the two model names plus the recorded winner, if any.
    private func comparisonSubtitle(_ comparison: Comparison) -> String {
        var line = "\(comparison.modelA) vs \(comparison.modelB)"
        if let winner = comparison.winner {
            line += " · \(winner.uppercased())"
        }
        return line
    }

    /// New-comparison form: prompt, searchable multi-select, optional blind toggle.
    private var composeDetail: some View {
        Form {
            Section("Prompt") {
                TextField("Enter a prompt to compare", text: $prompt, axis: .vertical)
                    .lineLimit(3...8)
                    .accessibilityIdentifier("compare-prompt-field")
            }

            Section("Models") {
                if selectedModelKeys.count < 2 {
                    Text("Pick two or more models to compare.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("compare-empty-state")
                }
                CompareModelMultiSelect(
                    selectedKeys: $selectedModelKeys,
                    choices: compareChoices
                )
                if selectedModelKeys.count == 2 {
                    Toggle("Blind comparison", isOn: $isBlind)
                }
            }

            Section {
                Button(isRunning ? "Running..." : "Start Comparison") {
                    startComparison(choices: compareChoices)
                }
                .disabled(
                    isRunning
                        || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || selectedModelKeys.count < 2
                )
                .accessibilityIdentifier("start-compare-button")

                if let errorMessage {
                    StatusMessage(kind: .error, text: errorMessage)
                }
            }
        }
        .navigationTitle("Compare Models")
        .toolbar { compareDetailToolbar }
    }

    /// Shared toolbar for comparison detail and compose screens.
    @ToolbarContentBuilder
    private var compareDetailToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                startNewComparison()
            } label: {
                Label("New Comparison", systemImage: "plus")
            }
            .accessibilityIdentifier("compare-detail-new-button")
        }
        ToolbarItem(placement: .destructiveAction) {
            Button("Delete", role: .destructive) {
                if let activeComparison {
                    comparisonPendingDeletion = activeComparison
                } else if let selectedComparisonID,
                          let comparison = comparisons.first(where: { $0.id == selectedComparisonID }) {
                    comparisonPendingDeletion = comparison
                }
            }
            .disabled(activeComparison == nil && selectedComparisonID == nil)
            .accessibilityIdentifier("compare-detail-delete-button")
        }
    }

    /// Result view: prompt, side-by-side tiles, and voting when exactly two text models ran.
    private func comparisonDetail(_ comparison: Comparison, revealModels: Bool) -> some View {
        let slots = comparison.slotResults
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(comparison.prompt)
                    .font(AnAIOdysseyFont.detailSubtitle)

                if slots.count >= 2 {
                    compareTiles(slots, revealNames: revealModels || !comparison.isBlind)
                } else {
                    let responses = CompareService.displayResponses(for: comparison)
                    if revealModels {
                        Text("\(comparison.modelA) vs \(comparison.modelB)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if comparison.isBlind {
                        Text("Blind comparison — vote before revealing models.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    responsePanels(responses: responses)
                }

                if comparison.votedAt == nil, slots.count <= 2, slots.allSatisfy({ !$0.isImage }) {
                    HStack {
                        Button("Prefer A") { vote(comparison, winner: mappedWinner(for: "left", comparison: comparison)) }
                        Button("Prefer B") { vote(comparison, winner: mappedWinner(for: "right", comparison: comparison)) }
                        Button("Tie") { vote(comparison, winner: "tie") }
                    }
                    .buttonStyle(.bordered)
                } else if let winner = comparison.winner {
                    Text("Your vote: \(winner.uppercased())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .navigationTitle("Comparison")
        .toolbar { compareDetailToolbar }
        .sheet(item: $expandedCompareTile) { tile in
            expandedCompareSheet(tile)
        }
    }

    private func compareTiles(_ slots: [CompareSlotResult], revealNames: Bool) -> some View {
        let columnCount = isCompact ? 1 : min(max(slots.count, 2), 3)
        let columns = Array(repeating: GridItem(.flexible(), spacing: 16), count: columnCount)
        return LazyVGrid(columns: columns, spacing: 16) {
            ForEach(Array(slots.enumerated()), id: \.element.id) { index, slot in
                let title = revealNames ? slot.displayName : "Model \(index + 1)"
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 8) {
                        Text(title)
                            .font(AnAIOdysseyFont.listTitle)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
                        Button {
                            expandedCompareTile = ExpandedCompareTile(title: title, slot: slot)
                        } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open full response")
                        .accessibilityIdentifier("compare-expand-\(slot.modelID)")
                    }
                    WorkspacePanel {
                        if slot.isImage, let path = slot.imagePath {
                            WorkspaceFileImage(url: URL(fileURLWithPath: path))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .clipped()
                        } else {
                            compareTextBody(slot.text)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 220, maxHeight: 220)
                    .clipped()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        expandedCompareTile = ExpandedCompareTile(title: title, slot: slot)
                    }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("Shows the full response")
                    if slot.isImage, let path = slot.imagePath {
                        WorkspaceImageShareLink(
                            title: slot.displayName,
                            fileURL: URL(fileURLWithPath: path),
                            accessibilityIdentifier: "share-compare-\(slot.modelID)"
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    @ViewBuilder
    private func compareTextBody(_ text: String?) -> some View {
        let body = text?.isEmpty == false ? text! : "No response"
        #if os(iOS)
        CopyableUITextView(plainText: body, isScrollEnabled: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        #else
        ScrollView {
            PlainMessageContentView(content: body)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        #endif
    }

    private func expandedCompareSheet(_ tile: ExpandedCompareTile) -> some View {
        NavigationStack {
            Group {
                if tile.slot.isImage, let path = tile.slot.imagePath {
                    WorkspaceFileImage(url: URL(fileURLWithPath: path))
                        .scaledToFit()
                        .padding()
                } else {
                    ScrollView {
                        PlainMessageContentView(
                            content: tile.slot.text?.isEmpty == false ? tile.slot.text! : "No response"
                        )
                        .padding()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(tile.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { expandedCompareTile = nil }
                }
            }
        }
    }

    /// Lays the A/B responses out side by side in regular widths, or stacked
    /// (A above B) in compact width, where two columns don't fit.
    @ViewBuilder
    private func responsePanels(responses: (left: String, right: String)) -> some View {
        if isCompact {
            VStack(alignment: .leading, spacing: 16) {
                responseColumn(title: "Response A", body: responses.left, scrollsInternally: false)
                responseColumn(title: "Response B", body: responses.right, scrollsInternally: false)
            }
        } else {
            HStack(alignment: .top, spacing: 16) {
                responseColumn(title: "Response A", body: responses.left)
                responseColumn(title: "Response B", body: responses.right)
            }
        }
    }

    /// One titled response panel within the side-by-side or stacked layout.
    ///
    /// In the stacked (compact) layout the panels grow to their natural height and
    /// the outer `ScrollView` scrolls both; nesting a second scroll view there
    /// would trap the drag gesture inside whichever panel it started on.
    private func responseColumn(title: String, body: String, scrollsInternally: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(AnAIOdysseyFont.listTitle)
            WorkspacePanel {
                if scrollsInternally {
                    ScrollView {
                        PlainMessageContentView(content: body.isEmpty ? "No response" : body)
                    }
                    .frame(maxHeight: 480)
                } else {
                    PlainMessageContentView(content: body.isEmpty ? "No response" : body)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// Translates the visible column ("left"/"right") into the real model slot
    /// ("a"/"b"). For blind comparisons the displayed order is shuffled, so the
    /// stored mapping is consulted to record the vote against the correct model.
    private func mappedWinner(for side: String, comparison: Comparison) -> String {
        guard comparison.isBlind, let mapping = CompareService.decodeMapping(from: comparison) else {
            return side == "left" ? "a" : "b"
        }
        let slot = side == "left" ? mapping.left : mapping.right
        return slot
    }

    private func reloadCompareChoices() {
        let offerLocal = OnDeviceLanguageModelSupport.shouldOfferLocalMLX(manager: localModelManager)
        let downloaded: Set<String>
        if offerLocal {
            downloaded = Set((localModelManager?.statuses() ?? []).filter(\.isDownloaded).map(\.option.id))
        } else {
            downloaded = []
        }
        compareChoices = ConfiguredModelRegistry.availableChoices(
            providerSettings: providerSettings,
            downloadedLocalModelIDs: downloaded,
            scope: .unfiltered,
            offerLocalMLX: offerLocal,
            offerAppleFoundation: OnDeviceLanguageModelSupport.shouldOfferAppleFoundation
        )
    }

    /// Reloads saved comparisons and selects the first unless composing.
    ///
    /// In compact width the detail is pushed, so we don't auto-select (that would
    /// immediately push the first comparison over the list).
    private func reload() {
        guard let compareService else { return }
        comparisons = (try? compareService.listComparisons()) ?? []
        if !isCompact, selectedComparisonID == nil, !composingNewComparison, let first = comparisons.first?.id {
            selectedComparisonID = first
        }
    }

    /// Opens the compose form for a fresh comparison.
    private func startNewComparison() {
        composingNewComparison = true
        selectedComparisonID = nil
        activeComparison = nil
        errorMessage = nil
    }

    /// Runs every selected model against the prompt.
    private func startComparison(choices: [ConfiguredModelChoice]) {
        guard let compareService else { return }
        isRunning = true
        errorMessage = nil
        activeComparison = nil
        let selections = choices.filter { selectedModelKeys.contains($0.selectionKey) }.map {
            CompareSelection(
                selectionKey: $0.selectionKey,
                modelID: $0.id,
                displayName: $0.displayName,
                connectionID: $0.connectionID
            )
        }

        Task {
            defer { isRunning = false }
            do {
                let comparison = try await compareService.startComparison(
                    prompt: prompt,
                    selections: selections,
                    isBlind: isBlind && selections.count == 2
                )
                activeComparison = comparison
                composingNewComparison = false
                reload()
                selectedComparisonID = comparison.id
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Records the user's verdict and refreshes the (now revealed) comparison.
    private func vote(_ comparison: Comparison, winner: String) {
        guard let compareService else { return }
        do {
            let updated = try compareService.recordVote(comparisonID: comparison.id, winner: winner)
            activeComparison = updated
            reload()
            selectedComparisonID = updated.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Swipe-to-delete handler mapping list offsets to comparisons.
    private func deleteComparisons(at offsets: IndexSet) {
        for index in offsets {
            deleteComparison(comparisons[index])
        }
    }

    /// Deletes a comparison and clears any selection/active state pointing at it.
    private func deleteComparison(_ comparison: Comparison) {
        guard let compareService else { return }
        try? compareService.deleteComparison(id: comparison.id)
        if selectedComparisonID == comparison.id {
            selectedComparisonID = nil
            composingNewComparison = true
        }
        if activeComparison?.id == comparison.id {
            activeComparison = nil
            composingNewComparison = true
        }
        comparisonPendingDeletion = nil
        reload()
    }
}

/// Full-screen Compare tile: keeps the grid cell's title (blind "Model N" or the real name).
private struct ExpandedCompareTile: Identifiable {
    var id: String { slot.id }
    let title: String
    let slot: CompareSlotResult
}
