// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import AnAIOdysseyCore
import SwiftUI

/// The Memory workspace: browse, semantically search, and add long-term memories.
///
/// These are the same memories the chat surface recalls to ground responses. The
/// sidebar lists all saved memories plus live semantic search results; the detail
/// pane hosts the search field and a composer for capturing something new. Saving
/// embeds the text via the `MemoryService`, so writes are asynchronous.
struct MemoryView: View {
    /// Memory store providing list/search/save/delete (and embedding) operations.
    @Environment(\.memoryService) private var memoryService
    /// All saved memories backing the "All Memories" list.
    @State private var memories: [Memory] = []
    /// Current search text.
    @State private var searchQuery = ""
    /// Semantic search hits (with similarity scores) for the current query.
    @State private var searchResults: [MemorySearchResult] = []
    /// Draft text for a new memory.
    @State private var draft = ""
    /// Whether a non-empty search is active (controls which sections show).
    @State private var isSearching = false
    /// True while an async save is in flight (disables the Save button).
    @State private var isSaving = false
    /// Surfaces save/search failures.
    @State private var errorMessage: String?
    /// Memory awaiting delete confirmation.
    @State private var memoryPendingDeletion: Memory?
    /// Currently selected memory id; drives the detail pane (`nil` shows the composer).
    @State private var selectedMemoryID: String?
    /// Ids known to be present in the search index, for the "indexed/pending" badge.
    @State private var indexedIDs: Set<String> = []
    /// In compact width, whether the pushed detail is the new-memory composer.
    @State private var composingMemory = false
    #if os(iOS)
    /// iPhone portrait is compact; a nested split view can't show its detail
    /// column there, so we fall back to push navigation.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var isCompact: Bool { horizontalSizeClass == .compact }
    #else
    private var isCompact: Bool { false }
    #endif

    /// Split layout: searchable memory list on the leading side; the trailing side
    /// shows the selected memory's full detail, or the capture composer when none
    /// is selected. Plus the delete-confirmation alert.
    var body: some View {
        layout
            .onAppear(perform: reload)
            .destructiveDeleteAlert(
                "Delete Memory?",
                item: $memoryPendingDeletion,
                message: { memory in
                    "“\(memory.text)” will be permanently deleted."
                },
                confirmAction: deleteMemory
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
            memorySidebar
        } detail: {
            detailPane
        }
        .removeNestedSidebarToggle()
        .workspaceNavigationSplit()
    }

    #if os(iOS)
    /// iPhone portrait: the memory list is the root; selecting a memory or tapping
    /// "New Memory" pushes the detail/composer.
    ///
    /// No `NavigationStack` of its own: the Library tab's stack (in
    /// `PhoneRootView`) hosts the push, so there is exactly one navigation bar
    /// and one Back path.
    private var compactBody: some View {
        memorySidebar
            .navigationDestination(isPresented: compactDetailPresented) {
                detailPane
            }
    }

    /// Present the pushed detail when a memory is selected or the composer is open;
    /// clearing it on pop returns to the list.
    private var compactDetailPresented: Binding<Bool> {
        Binding(
            get: { selectedMemoryID != nil || composingMemory },
            set: { presented in
                if !presented {
                    selectedMemoryID = nil
                    composingMemory = false
                }
            }
        )
    }
    #endif

    /// The searchable memory list, shared by both layouts.
    private var memorySidebar: some View {
        List(selection: $selectedMemoryID) {
            // Search results section, shown only while a non-empty query is active.
            if isSearching && !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Section("Search Results") {
                    if searchResults.isEmpty {
                        WorkspaceEmptyListLabel(text: "No matching memories")
                    } else {
                        ForEach(searchResults, id: \.memory.id) { result in
                            MemoryRow(memory: result.memory, score: result.score)
                                .tag(result.memory.id)
                                .contextMenu {
                                    Button("Delete", role: .destructive) {
                                        memoryPendingDeletion = result.memory
                                    }
                                }
                        }
                    }
                }
            }

            // Full memory list; relabeled when search results are also showing.
            Section(isSearching ? "All Memories" : "Memories") {
                if memories.isEmpty {
                    WorkspaceEmptyListLabel(text: "No memories saved yet")
                } else {
                    ForEach(memories, id: \.id) { memory in
                        MemoryRow(memory: memory, score: nil)
                            .tag(memory.id)
                            .contextMenu {
                                Button("Delete", role: .destructive) {
                                    memoryPendingDeletion = memory
                                }
                            }
                    }
                    .onDelete(perform: deleteMemories)
                }
            }
        }
        .macWorkspaceSplit()
        .navigationTitle("Memory")
        .searchable(text: $searchQuery, prompt: "Search memories")
        .onSubmit(of: .search, runSearch)
        .onChange(of: searchQuery) { _, newValue in
            isSearching = !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if isSearching {
                runSearch()
            } else {
                searchResults = []
            }
        }
        .toolbar {
            // Switch the detail pane back to the new-memory composer.
            ToolbarItem(placement: .primaryAction) {
                Button {
                    startNewMemory()
                } label: {
                    Label("New Memory", systemImage: "plus")
                }
                .workspaceActionButtonTint()
                .accessibilityIdentifier("new-memory-button")
            }
        }
    }

    /// Opens the new-memory composer (in compact this pushes it onto the stack).
    private func startNewMemory() {
        selectedMemoryID = nil
        composingMemory = true
    }

    /// Detail pane: the selected memory's full content, or the capture composer.
    @ViewBuilder
    private var detailPane: some View {
        if let id = selectedMemoryID, let memory = memory(for: id) {
            MemoryDetailView(
                memory: memory,
                isIndexed: indexedIDs.contains(memory.id),
                onDelete: { memoryPendingDeletion = memory }
            )
        } else {
            composerForm
        }
    }

    /// The new-memory capture form, shown when nothing is selected.
    private var composerForm: some View {
        Form {
            Section("New Memory") {
                TextField("What should \(AppBranding.appName) remember?", text: $draft, axis: .vertical)
                    .lineLimit(3...8)
                    .accessibilityIdentifier("memory-input-field")
                Button("Save", action: saveDraft)
                    .disabled(isSaving || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("save-memory-button")
            }

            if let errorMessage {
                Section {
                    StatusMessage(kind: .error, text: errorMessage)
                }
            }

            // Surface a degraded embedder so saves that succeeded-but-weren't-
            // indexed don't fail silently. They retry automatically.
            if case .unavailable(let reason)? = memoryService?.embedderHealth {
                Section {
                    StatusMessage(
                        kind: .info,
                        text: "Saved, but search indexing is currently unavailable (\(reason)). It will retry automatically."
                    )
                }
            }
        }
        .navigationTitle("Remember")
    }

    /// Resolves a memory id to its record from the list or current search results.
    private func memory(for id: String) -> Memory? {
        if let match = memories.first(where: { $0.id == id }) {
            return match
        }
        return searchResults.first(where: { $0.memory.id == id })?.memory
    }

    /// Reloads the full memory list (and index status) from the store.
    private func reload() {
        guard let memoryService else { return }
        memories = (try? memoryService.listAll()) ?? []
        indexedIDs = (try? memoryService.vectorStore.indexedMemoryIDs()) ?? []
    }

    /// Saves the draft as a new memory (embedding it asynchronously), then clears
    /// the composer and refreshes the list and any active search.
    private func saveDraft() {
        guard let memoryService else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        isSaving = true
        errorMessage = nil
        Task {
            defer { isSaving = false }
            do {
                _ = try await memoryService.save(text: text)
                draft = ""
                // In compact width the composer is pushed; return to the list.
                composingMemory = false
                reload()
                // Keep results consistent if the user is mid-search.
                if isSearching {
                    runSearch()
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Runs a semantic (vector) search for the current query, top 5 matches.
    private func runSearch() {
        guard let memoryService else { return }
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchResults = []
            return
        }

        Task {
            do {
                searchResults = try await memoryService.search(query: query, topK: 5)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Deletes a memory and refreshes the list (and search results if searching).
    private func deleteMemory(_ memory: Memory) {
        guard let memoryService else { return }
        try? memoryService.delete(id: memory.id)
        memoryPendingDeletion = nil
        // Clear the detail pane if the deleted memory was on screen.
        if selectedMemoryID == memory.id {
            selectedMemoryID = nil
        }
        reload()
        if isSearching {
            runSearch()
        }
    }

    /// Swipe-to-delete handler mapping list offsets to memories.
    private func deleteMemories(at offsets: IndexSet) {
        for index in offsets {
            deleteMemory(memories[index])
        }
    }
}

/// Read-only detail for a single memory: its full text plus metadata (creation
/// date, originating session, search-index status, and id).
private struct MemoryDetailView: View {
    let memory: Memory
    /// Whether this memory currently has an embedding in the search index.
    let isIndexed: Bool
    /// Invoked to request deletion (routes through the confirmation alert).
    let onDelete: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(memory.text)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Created") {
                        Text(memory.createdAt.formatted(date: .long, time: .shortened))
                    }
                    if let sessionID = memory.sessionID, !sessionID.isEmpty {
                        LabeledContent("Session") {
                            Text(sessionID).font(.caption.monospaced())
                        }
                    }
                    LabeledContent("Search index") {
                        Label(
                            isIndexed ? "Indexed" : "Pending",
                            systemImage: isIndexed ? "checkmark.circle" : "clock"
                        )
                        .foregroundStyle(isIndexed ? .green : .orange)
                    }
                    LabeledContent("ID") {
                        Text(memory.id).font(.caption.monospaced())
                    }
                }
                .font(.callout)
            }
            .padding()
        }
        .navigationTitle("Memory")
        .toolbar {
            ToolbarItem(placement: .destructiveAction) {
                Button(role: .destructive, action: onDelete) {
                    Label("Delete", systemImage: "trash")
                }
                .workspaceActionButtonTint(destructive: true)
                .accessibilityIdentifier("delete-memory-button")
            }
        }
    }
}

/// A list row for a memory: its text and creation date, plus the similarity score
/// when the row comes from search results.
private struct MemoryRow: View {
    let memory: Memory
    /// Similarity score for search hits; `nil` for plain list rows.
    let score: Float?

    var body: some View {
        SidebarListRow(
            title: memory.text,
            subtitle: memory.createdAt.formatted(date: .abbreviated, time: .shortened),
            secondaryLine: score.map { String(format: "Score %.2f", $0) },
            lineLimit: 3
        )
        .accessibilityIdentifier("memory-row-\(memory.id)")
    }
}
