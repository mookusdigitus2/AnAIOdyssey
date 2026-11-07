// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import AnAIOdysseyAI
import AnAIOdysseyCore
import SwiftUI

/// Unified search tab — the user-facing surface for `UnifiedSearchService`.
struct UnifiedSearchView: View {
    @Environment(\.repositories) private var repositories
    @Environment(\.searchIndexStore) private var searchIndexStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var query = ""
    @State private var scope: SearchScope = .all
    @State private var hits: [SearchHit] = []
    @State private var isSearching = false
    @State private var navigationPath = NavigationPath()

    var body: some View {
        NavigationStack(path: $navigationPath) {
            searchRoot
                .navigationTitle("Search")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                .searchable(
                    text: $query,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Documents, mail, chats…"
                )
                #else
                .searchable(text: $query, prompt: "Documents, mail, chats…")
                #endif
                .navigationDestination(for: SearchResultRoute.self) { route in
                    SearchResultDestinationView(route: route)
                }
        }
        .onChange(of: query) { _, _ in runSearch() }
        .onChange(of: scope) { _, _ in runSearch() }
        .background(AegeanColors.groupedBackground(colorScheme))
    }

    private var searchRoot: some View {
        List {
            Section {
                scopeBar
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            if trimmedQuery.isEmpty {
                Section {
                    ContentUnavailableView(
                        "Search Everything",
                        systemImage: "sparkle.magnifyingglass",
                        description: Text("Find documents, notes, chats, tasks, and more.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 260)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            } else if hits.isEmpty && !isSearching {
                Section {
                    ContentUnavailableView.search(text: query)
                        .frame(maxWidth: .infinity, minHeight: 220)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            } else {
                ForEach(groupedHitSections, id: \.kind) { section in
                    Section(section.kind.displayName) {
                        ForEach(section.hits) { hit in
                            NavigationLink(value: SearchResultRoute(hit: hit)) {
                                SearchHitRow(hit: hit, query: query)
                            }
                        }
                    }
                }
            }
        }
        #if os(iOS)
        .listStyle(.plain)
        #else
        .listStyle(.inset)
        #endif
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var scopeBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SearchScope.allCases) { item in
                    Button {
                        scope = item
                    } label: {
                        Text(item.title)
                            .font(.subheadline.weight(scope == item ? .semibold : .regular))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(scope == item ? AegeanColors.accent(colorScheme).opacity(0.18) : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(scope == item ? AegeanColors.accent(colorScheme) : AegeanColors.secondaryLabel(colorScheme))
                }
            }
            .padding(.horizontal)
        }
    }

    private struct HitSection {
        let kind: SearchHit.Kind
        let hits: [SearchHit]
    }

    private var groupedHitSections: [HitSection] {
        let grouped = Dictionary(grouping: hits, by: \.kind)
        return grouped.keys
            .sorted { $0.displayName < $1.displayName }
            .map { HitSection(kind: $0, hits: grouped[$0] ?? []) }
            .filter { !$0.hits.isEmpty }
    }

    private func runSearch() {
        guard let repositories else { return }
        guard !trimmedQuery.isEmpty else {
            hits = []
            return
        }
        isSearching = true
        let service = UnifiedSearchService(repositories: repositories, searchIndex: searchIndexStore)
        hits = (try? service.search(query: trimmedQuery, kinds: scope.kinds, limit: 30)) ?? []
        isSearching = false
    }
}

private struct SearchResultRoute: Hashable {
    let kind: SearchHit.Kind
    let entityID: String
    let title: String

    init(hit: SearchHit) {
        kind = hit.kind
        entityID = hit.entityID
        title = hit.title
    }
}

private struct SearchResultDestinationView: View {
    let route: SearchResultRoute
    @Environment(\.repositories) private var repositories

    var body: some View {
        Group {
            switch route.kind {
            case .document:
                if let document = fetch(DocumentModel.self) {
                    SearchDocumentHost(document: document)
                } else {
                    missingEntityView
                }
            case .note:
                if let note = fetch(Note.self) {
                    SearchNoteHost(note: note)
                } else {
                    missingEntityView
                }
            case .chat:
                ChatDetailView(sessionID: route.entityID, onUpdated: {})
            case .scheduledTask:
                if let task = fetch(ScheduledTask.self) {
                    SearchScheduledTaskDetail(task: task)
                } else {
                    missingEntityView
                }
            case .agentTask:
                if let task = fetch(AgentTask.self) {
                    SearchAgentTaskDetail(task: task)
                } else {
                    missingEntityView
                }
            case .research:
                if let report = fetch(ResearchReport.self) {
                    SearchResearchDetail(report: report)
                } else {
                    missingEntityView
                }
            case .memory:
                if let memory = fetch(Memory.self) {
                    SearchMemoryDetail(memory: memory)
                } else {
                    missingEntityView
                }
            case .emailDraft:
                if let draft = fetch(EmailDraft.self) {
                    SearchEmailDraftDetail(draft: draft)
                } else {
                    missingEntityView
                }
            case .calendarEvent:
                if let event = fetch(CalendarEventRecord.self) {
                    SearchCalendarEventDetail(event: event)
                } else {
                    missingEntityView
                }
            case .galleryAlbum:
                if let album = fetch(Album.self) {
                    SearchGalleryAlbumDetail(album: album)
                } else {
                    missingEntityView
                }
            case .comparison:
                if let comparison = fetch(Comparison.self) {
                    SearchComparisonDetail(comparison: comparison)
                } else {
                    missingEntityView
                }
            }
        }
        .navigationTitle(route.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    /// The shared "get": every kind resolves through the same repository lookup.
    private func fetch<Entity>(_ type: Entity.Type) -> Entity? {
        repositories?.fetchSearchable(kind: route.kind, id: route.entityID) as? Entity
    }

    private var missingEntityView: some View {
        ContentUnavailableView(
            "Not Found",
            systemImage: "questionmark.folder",
            description: Text("This item may have been deleted.")
        )
    }
}

private struct SearchDocumentHost: View {
    @Environment(\.repositories) private var repositories
    @Environment(\.dismiss) private var dismiss
    @Bindable var document: DocumentModel
    @State private var saveDebouncer = Debouncer()
    @State private var pendingDeletion: DocumentModel?

    var body: some View {
        DocumentEditorView(
            document: document,
            onTitleChange: { title in scheduleSave(title: title, content: nil) },
            onContentChange: { content in scheduleSave(title: nil, content: content) },
            onDelete: { pendingDeletion = document }
        )
        .destructiveDeleteAlert(
            "Delete Document?",
            item: $pendingDeletion,
            message: { document in
                "“\(document.title)” and its version history will be permanently deleted."
            },
            confirmAction: { document in
                try? repositories?.documents.deleteDocument(id: document.id)
                dismiss()
            }
        )
    }

    private func scheduleSave(title: String?, content: String?) {
        saveDebouncer.schedule { [repositories, id = document.id] in
            try? repositories?.documents.updateDocument(id: id, title: title, content: content)
        }
    }
}

private struct SearchNoteHost: View {
    @Environment(\.repositories) private var repositories
    @Environment(\.dismiss) private var dismiss
    @Bindable var note: Note
    @State private var pendingDeletion: Note?

    var body: some View {
        NoteEditorView(note: note, onUpdated: {}, onDelete: { pendingDeletion = note })
            .destructiveDeleteAlert(
                "Delete Note?",
                item: $pendingDeletion,
                message: { note in
                    "“\(note.title.isEmpty ? "Untitled" : note.title)” will be permanently deleted."
                },
                confirmAction: { note in
                    try? repositories?.notes.deleteNote(id: note.id)
                    dismiss()
                }
            )
    }
}

private struct SearchScheduledTaskDetail: View {
    let task: ScheduledTask

    var body: some View {
        Form {
            LabeledContent("Name", value: task.name)
            LabeledContent("Status", value: task.status.capitalized)
            if let prompt = task.prompt, !prompt.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Prompt")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    PlainMessageContentView(content: prompt)
                }
            }
            if let next = task.nextRun {
                LabeledContent("Next Run", value: next.formatted(date: .abbreviated, time: .shortened))
            }
            if let last = task.lastRun {
                LabeledContent("Last Run", value: last.formatted(date: .abbreviated, time: .shortened))
            }
        }
    }
}

private struct SearchAgentTaskDetail: View {
    let task: AgentTask

    var body: some View {
        Form {
            LabeledContent("Status", value: AgentTaskStatus(rawValue: task.status)?.displayName ?? task.status)
            VStack(alignment: .leading, spacing: 6) {
                Text("Assignment")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                PlainMessageContentView(content: task.assignment)
            }
            if let summary = task.resultSummary, !summary.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Result")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ScrollableTextDocumentView(text: summary, maxContentHeight: nil)
                }
            }
        }
    }
}

private struct SearchResearchDetail: View {
    let report: ResearchReport

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(report.query)
                    .font(AnAIOdysseyFont.detailSubtitle)

                PlainMessageContentView(content: report.summary)

                let thread = ResearchService.decodeThread(from: report)
                if !thread.isEmpty {
                    Divider()
                    ForEach(thread) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.role == "user" ? "You" : "Research")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            PlainMessageContentView(content: entry.content)
                        }
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SearchMemoryDetail: View {
    let memory: Memory

    var body: some View {
        ScrollView {
            Text(memory.text)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
    }
}

private struct SearchEmailDraftDetail: View {
    let draft: EmailDraft

    var body: some View {
        Form {
            LabeledContent("To", value: draft.toRecipients)
            LabeledContent("Subject", value: draft.subject)
            VStack(alignment: .leading, spacing: 6) {
                Text("Body")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                PlainMessageContentView(content: draft.body)
            }
        }
    }
}

private struct SearchCalendarEventDetail: View {
    let event: CalendarEventRecord

    var body: some View {
        Form {
            LabeledContent("Starts", value: event.startDate.formatted(date: .abbreviated, time: .shortened))
            LabeledContent("Ends", value: event.endDate.formatted(date: .abbreviated, time: .shortened))
            if let location = event.location, !location.isEmpty {
                LabeledContent("Location", value: location)
            }
            if let notes = event.notes, !notes.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Notes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    PlainMessageContentView(content: notes)
                }
            }
        }
    }
}

private struct SearchGalleryAlbumDetail: View {
    let album: Album
    @Environment(\.repositories) private var repositories
    @State private var images: [GalleryImage] = []

    var body: some View {
        List {
            if images.isEmpty {
                Text("No images in this album")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(images, id: \.id) { image in
                    Text(image.caption?.nilIfEmpty ?? image.filename)
                }
            }
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        images = (try? repositories?.gallery.listImages(albumID: album.id)) ?? []
    }
}

private struct SearchComparisonDetail: View {
    let comparison: Comparison

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(comparison.prompt)
                    .font(AnAIOdysseyFont.detailSubtitle)
                if let responseA = comparison.responseA {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(comparison.modelA)
                            .font(.caption.weight(.semibold))
                        PlainMessageContentView(content: responseA)
                    }
                }
                if let responseB = comparison.responseB {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(comparison.modelB)
                            .font(.caption.weight(.semibold))
                        PlainMessageContentView(content: responseB)
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private enum SearchScope: String, CaseIterable, Identifiable {
    case all
    case documents
    case notes
    case chats
    case tasks
    case more

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .documents: "Docs"
        case .notes: "Notes"
        case .chats: "Chats"
        case .tasks: "Tasks"
        case .more: "More"
        }
    }

    var kinds: Set<SearchHit.Kind>? {
        switch self {
        case .all: nil
        case .documents: [.document]
        case .notes: [.note]
        case .chats: [.chat]
        case .tasks: [.scheduledTask, .agentTask]
        case .more: [.research, .memory, .emailDraft, .calendarEvent, .galleryAlbum, .comparison]
        }
    }
}

private struct SearchHitRow: View {
    let hit: SearchHit
    let query: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: hit.kind.systemImage)
                .foregroundStyle(kindColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(hit.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(AegeanColors.label(colorScheme))
                Text(hit.snippet)
                    .font(.subheadline)
                    .foregroundStyle(AegeanColors.secondaryLabel(colorScheme))
                    .lineLimit(2)
                if let date = hit.date {
                    Text(date, style: .date)
                        .font(.caption)
                        .foregroundStyle(AegeanColors.secondaryLabel(colorScheme))
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var kindColor: Color {
        switch hit.kind {
        case .document, .note, .chat: AegeanColors.accent(colorScheme)
        case .scheduledTask, .agentTask: AegeanColors.warning(colorScheme)
        case .memory, .research: AegeanColors.aiViolet(colorScheme)
        default: AegeanColors.secondaryLabel(colorScheme)
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
