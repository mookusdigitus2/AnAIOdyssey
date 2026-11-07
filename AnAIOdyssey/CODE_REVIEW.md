# An AI Odyssey Code Review

Review of the Library tab, the search/object model, and a general code-quality
sweep. Findings are grouped by status: what has been fixed (PR #15), what remains open, and what
was checked and found healthy.

> Note: the fixes on PR #15 were written in an environment without a Swift
> toolchain, verified by careful reading rather than compilation. Build and run
> the test suite in Xcode before merging.

---

## 1. Search & object model

### Problem

Tasks, emails, notes, documents, research (and six more kinds) were independent
SwiftData models with **no common searchable shape**. Every searchable kind was
hand-wired in three parallel places, each extracting (title, body, date) its
own way:

1. `UnifiedSearchService` — eleven near-identical `searchX()` methods.
2. `SearchIndexBackfill.rebuildAll` — eleven indexing loops.
3. `SearchResultDestinationView` — an eleven-case fetch-and-route switch.

The copies had drifted: the FTS index stored an email draft's body as
`toRecipients + body` while live search scored only `subject`/`body`; agent-task
matching checked fields the snippet ignored; `Memory` had no fetch-by-id at all
(the search destination listed every memory and filtered).

Worse, the FTS sidecar was only built at launch **when empty**, and nothing
ever updated or deleted rows afterwards. Deleted items kept appearing in
results ("ghosts"), and FTS hits carried a flat score of 6.0 that outranked any
fresh live hit in dedup.

### Fixed (PR #15)

- **`Searchable` protocol** (`AnAIOdysseyCore/Services/Searchable.swift`):
  `searchID` / `searchTitle` / `searchText` / `searchDate`, conformed by all 11
  models. `searchText` is the single "to string" projection used everywhere.
- **Shared enumerate/get on `RepositoryBundle`**: `searchableItems(of:)` and
  `fetchSearchable(kind:id:)` — the uniform list and get behind live search,
  indexing, and opening a search result.
- The three parallel structures collapsed to one generic matcher, one generic
  indexing loop, and one shared fetch. Adding a searchable type is now one
  conformance + one `SearchHit.Kind` case.
- **Ghost results fixed**: FTS hits are verified against the live store at
  query time (rows for deleted entities are dropped), verified hits are
  rescored from live data, the index is fully rebuilt (and cleared first) on
  each launch, and `SearchIndexStore.delete` uses bound SQL parameters.
- Search text now consistently covers checklist items, cc recipients, chat
  transcripts, and album descriptions in both live search and the index.
- Tests: stale-FTS filtering, rebuild clearing orphaned rows, `Searchable`
  projections.

---

## 2. Library tab (iPhone)

### Problem

`PhoneRootView` drove the Library tab with three interacting pieces of state
(`showLibraryGrid`, `activeLibrarySection`, persisted promoted section).
Instead of pushing onto the `NavigationStack`, it swapped the stack root, so
back buttons, the tab title, and the tab icon were each hand-derived from the
same three-way precedence rules in separate places. This produced the "Library
tab bounces back to grid" bug (#13) and an inconsistent back experience.
`LibrarySection` also duplicated `AppSection` case-for-case.

### Fixed (PR #15)

- Single `LibraryDisplay` enum (`grid` / `section`) resolved in one
  `resolvedLibraryDisplay` property; title, icon, and back actions all derive
  from it. Back from any section now uniformly returns to the grid.
- `LibrarySection` deleted; the grid and tab-bar promotion use `AppSection`
  directly (`AppSection.librarySections(galleryEnabled:)`). Stored preference
  raw values are unchanged, so existing promotions carry over.

---

## 3. Library subviews

### Fixed (PR #15)

- **Documents/Notes were line-for-line twins.** Both now sit on a shared
  `FolderWorkspaceView` scaffold (`Design/FolderWorkspaceView.swift`) that owns
  tree selection, folder create/rename/move/delete with confirmations, item
  delete confirmation, and the "New" toolbar menu. Each host supplies only its
  item CRUD closures and detail editor. Net effect: ~200 duplicated lines
  deleted; Documents gains the ⌘N shortcut Notes already had.
- **Checklist row identity** (`NotesView`): rows were keyed by array offset
  (`ForEach(..., id: \.offset)`), the classic SwiftUI identity trap — row state
  misattaches on insert/remove/reorder, and index-based bindings can crash on
  stale indices. `ChecklistItem` now has a stable `id: UUID` (legacy records
  decode with a fresh id), rows key on it, and the bindings bounds-check.
- **No-op Delete buttons**: opening a document or note from search results
  produced an editor whose Delete button did nothing. Both now confirm, delete,
  and dismiss.
- **Debounced-autosave duplication**: the cancel/sleep `Task` pattern was
  copy-pasted in three places (and one copy had drifted). Consolidated into
  `Shared/Debouncer.swift` (400 ms quiet window).
- **`EmailView.swift` split** (1,045 → 698 lines): `MailboxTreeNode`,
  `MailPermissionView`, and `MailMessageDetailView` moved to their own files.
- **Dead code**: unused `NoteRow` view removed from `NotesView.swift`.

### Still worth doing

- `ChatsView` (1,093), `TasksView` (888), `SettingsView` (877), `ResearchView`
  (670) are several views/panels per file. Mechanical splits, best done in
  Xcode where each move compiles.

---

## 4. Open findings (general sweep)

Ranked by how much they matter.

1. **Search runs on every keystroke, synchronously.**
   `UnifiedSearchView.runSearch()` fires from `.onChange(of: query)` and does
   the full federated scan (every repository, chat transcripts, FTS) on the
   main thread per character typed. Because it is synchronous, the
   `isSearching` spinner state can never render — it is dead code. Fix: debounce
   the query (~200 ms, `Debouncer` already exists) and/or move the scan into
   `.task(id:)`.

2. **Sixty-plus `try?`s in the UI silently swallow persistence failures.**
   Every create/save/delete in the views ignores errors, so a failed save is
   silent data loss discovered later. Background autosaves failing quietly is
   defensible; explicit user actions (delete, create, import) should surface an
   alert. A small shared error-banner helper would allow incremental adoption.

3. **`fatalError` when the ModelContainer fails to open**
   (`AnAIOdysseyApp.swift`). Deliberate fail-fast, but in production a bad
   CloudKit/store migration becomes a crash loop at launch. Prefer a fallback
   local/in-memory container with a recovery screen.

4. **String-typed model fields** (`status`, `noteType`, `taskType`, `mode`, …)
   with enums on the side force `TaskStatus(rawValue:)` dances at call sites.
   The storage mirrors the legacy Python schema and keeps CloudKit happy — keep
   it — but typed computed accessors on the models (e.g. `var statusValue:
   TaskStatus?`) would stop stringly-typed comparisons from spreading.

5. **`HTMLEmailView` uses `DispatchQueue.main.asyncAfter(0.35)`** as a magic
   delay for WebView sizing. Fragile on slow devices; observe content size
   instead.

6. **`TaskSchedulerService.install(delegate:)`** parks the notification
   delegate in hidden static global state. Something must strongly hold a
   `UNUserNotificationCenter` delegate, but a global invites test-order bugs.

7. **`UnifiedMailReaderService` is `@unchecked Sendable`** with manual queue
   hopping. It carries a justification comment and no smoking gun was found,
   but hand-verified thread safety is one refactor from wrong — candidate for
   an actor when mail is next touched.

---

## 5. Checked and healthy

- **Secrets**: API keys/tokens go to the Keychain (`kSecClassGenericPassword`,
  `AfterFirstUnlock`); only non-secret connection metadata sits in
  `UserDefaults`.
- **SQL**: all statements in `SearchIndexStore` / `VectorIndexStore` use bound
  parameters (the one interpolated DELETE was fixed in PR #15).
- **OAuth presentation anchor**: the `DispatchQueue.main.sync` in
  `GoogleAuthSession` is guarded by `Thread.isMainThread` — no self-deadlock.
- **Hygiene**: no TODO/FIXME/HACK markers, no debug `print` calls in production
  code, `try!` only on static regex literals, and models correctly use
  string foreign keys + defaulted properties for CloudKit-mirror compatibility.
