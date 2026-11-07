# An AI Odyssey — Working Spec & Request Log

This is a living specification. It records **every feature/bug request** from the
product owner (in order) plus the agreed design/understanding for each, so there
is a single place to refer back to. Append new requests as they arrive; do not
rewrite history.

---

## 1. Request Log (chronological)

> Each entry is a literal-ish restatement of a request plus its status.

1. **Distinct chat vs. research prompts** — the chat persona must differ from the
   research persona. *(done)*
2. **Make the chat prompt configurable in Settings.** *(done)*
3. **Mail platform work:**
   - OAuth-based Gmail / Google Calendar access. *(done)*
   - Multi-service mail (Apple Mail, Gmail, etc.); Gmail configured via OAuth. *(done — multi-account foundation + unified inbox)*
   - IMAP mail access (Yahoo/iCloud/generic). *(deferred)*
   - Email on iPadOS. *(done)*
   - Confirm LLM design patterns (adapter, strategy, composite). *(answered)*
   - OpenAI Codex Console + Claude Console support. *(deferred)*
4. **Bug batch (address in order):**
   1. Calendar item not selectable / no detail. *(done)*
   2. Task not selectable in task list. *(done)*
   3. New chat doesn't clear the window until after pressing Enter. *(done)*
   4. **Directory structure** — documents (and notes) need real folders;
      navigate the tree rather than flat lists; "open N tabs" doesn't work.
      Tasks must support nesting (subtasks). *(partial — see §3, §21)*
   5. Email tab crashes. *(done — see §2.5)*
   6. Chat model list shows models that aren't installed/available. *(done)*
5. **AI must have access to all knowledge via tools** — every workspace's data
   (folders, documents, notes, tasks/subtasks, etc.) must be reachable by the
   agent through tools. *(done — see §4, §21)*
6. **Notion import must honor structure** — importing a Notion export should
   recreate its directory hierarchy as folders and assign directory names, rather
   than flattening into breadcrumb-prefixed titles. Example export reviewed:
   `~/Downloads/Export-1731a35f-...` (Studio Hub with `Projects/`, `Specs/`,
   `Milestones/`, nested pages, and `.csv` databases). *(done — see §5, §21)*
7. **Deploy to the a physical iPad** (e.g. iPad Pro 11" M4) for testing, not the
   simulator. *(done — install/launch flow established; launch requires the device
   unlocked)*
8. **Multi-agent platform roadmap** — agent controller, adapter pattern for all
   AIs, task/history/notes/data objects, human–AI handoff, external tool invocation
   (Cursor/Slack/CLI), AI settings & controller selection, Apple AI, voice
   (ElevenLabs + Apple Intelligence). *(foundation implemented — see §16)*
9. **Voice input/output in chat** — mic button: speech-to-text → send → AI reply
   → text-to-speech, with transcript in the chat log. *(done — see §18)*
10. **Send email from the app** — reply, reply-all, and forward with AI-drafted
    or user-edited bodies via Gmail. *(done — see §19; supersedes the compose-only
    constraint in §13)*
11. **iPad layout & signing** — app should fill the window; Settings accessible;
    Gallery hidden unless enabled; device builds sign correctly. *(done — see §20)*
12. **Export then import saved workspace data** — chats, research, docs, and the
    rest of the local workspace, except email and calendar. *(done — see §23)*
13. **iOS/iPadOS connection manager** — singleton that owns a set of connections;
    Google Auth is one adapter covering both email and calendar providers.
    *(done — `WorkspaceConnectionManager` + `GoogleAuthAdapter`)*
14. **Email refresh after Google auth + macOS pull-to-refresh** — after Google
    sign-in, rebuild readers and fetch/display mail without a manual refresh;
    macOS Email list supports pull-to-refresh and a Refresh toolbar button.
    *(done)*
15. **First-run / Compare / ChatGPT branding UX** — hide Continue with ChatGPT
    on iOS first-run (Mac-only until OpenAI allows mobile); Apple On-Device then
    API key then MLX on supported phones; Compare tiles scroll or open full-screen;
    no hand-drawn ChatGPT mark; blind tiles “Model 1”; one Not now; play.fill
    voice preview; hide “0 selected”. *(done — see §26)*
16. **Agent tasks hand research to the Research feature** — when a task is (or
    includes) a research request, call `run_research` so the Research tab pipeline
    (its model/feature settings, sources, saved Research item) does the work.
    Pause/Continue/Stop apply to that run. *(done — see §16.1)*
17. **Agent tasks hand document writing to the Documents feature** — when a task
    needs a document written, call `write_document` so the Documents writing
    pipeline (its model/feature settings, generation, saved Document) does the
    work instead of the task agent composing the body. A task may research, then
    write a document from it. Keep read/update tools. *(done — see §16.1)*
18. **Streamed assistant text must not pile prefixes** — each provider event is
    either a delta (append), a snapshot (replace), or done (finalize, no
    duplicate). Agent task / chat / research / document streams show and save
    the sentence once. *(done — `StreamTextCodec`)*
19. **LM Studio streaming looks frozen** — when LM Studio’s developer reasoning
    setting is on, thoughts arrive as `delta.reasoning_content` / `delta.reasoning`
    and `delta.content` is empty until thinking ends. Reading only `content`
    made Chat sit on “Waiting for the model…” then dump the reply. Yield
    reasoning live to a Thinking disclosure; keep content in the bubble.
    *(done — see §28)*
20. **Chat Privacy footer follows the selected search engine** — Settings (and
    any other surface) must show the disclosure for Brave, My Search Server,
    AI provider search, or DuckDuckGo Instant Answers/Wikipedia on fallback,
    and update live when the picker changes. Brave is the default. Never
    hard-code DuckDuckGo HTML results. *(done — §27)*
21. **ElevenLabs voice missing from the picker** — Voice Library IDs such as
    `VoiceIdPlaceholder01` did not appear because `/v1/voices` is “My Voices”
    only, fetch errors were swallowed, and `selectedVoice` fell back to
    `voices.first`. Use paginated `/v2/voices`, add-by-ID with live lookup,
    persist Added Voices, and keep the saved ID in the list. *(done — see §29)*
22. **Collapsing Thinking section** — while the model is thinking, keep the
    Thinking disclosure open and streaming; when the first content token
    arrives, auto-collapse to “Thought for N seconds” unless the user expanded
    it. Persisted chats with saved reasoning start collapsed. *(done — see §28)*

---

## 2. Completed bug-fix details

### 2.1 Calendar selection (`CalendarView.swift`)
Event list is a `List(selection:)`; selecting an event shows a read-only
`CalendarEventDetailView` (title, start/end, all-day, location, notes) with a
Delete action. A "New Event" toolbar button clears the selection to reveal the
create form.

### 2.2 Task selection (`TasksView.swift`)
Task list is a `List(selection:)`; selecting a task shows `TaskDetailView`
(status, schedule, next/last run, run count, prompt) with Pause/Resume/Delete.
"New Task" clears the selection to reveal the create form.

### 2.3 New-chat clears immediately (`ChatsView.swift`)
`ChatDetailView` is given `.id(sessionID)` so creating/switching a session
rebuilds the view (resetting transcript/composer) instead of showing the prior
session's `@State` until the next send.

### 2.4 Model picker shows only installed models
`ConfiguredModelRegistry.availableChoices(providerSettings:downloadedLocalModelIDs:)`
filters local MLX choices to those whose weights are on disk.
`WorkspaceModelPicker` reads `\.localModelManager` and passes the downloaded set
(so a device that cannot run MLX or Apple's Foundation Model only shows the
chosen remote provider — never a grayed-out Llama row).

### 2.5 Email iPad crash + no viewing window
- **Crash:** `GmailAPIClient.parseMessageSummary` used
  `Dictionary(uniqueKeysWithValues:)`, which traps on duplicate header names
  (Gmail repeats `Received:` etc., colliding after lowercasing). Now merges
  duplicates keeping the first (`uniquingKeysWith:`).
- **Layout:** the email browser was a 3-column `NavigationSplitView` nested inside
  the root split view (crashes/collapses on iPad). Reworked: macOS uses a
  2-column split (mailbox sidebar + `HSplitView` of list/reading pane); iOS/iPadOS
  uses a single `NavigationStack` (message list pushes the reading pane) with a
  toolbar **mailbox menu** to switch mailboxes — no nested split views.

---

## 3. Feature: Directory structure (Documents, Notes, Tasks)

### Goal
Treat Documents and Notes like a **real file system**: nestable folders that the
user navigates as a tree. Tasks get **parent/child nesting** (a task may contain
child tasks; usually none).

### Data model (SwiftData; additive, lightweight migration)
- **New `Folder` model** (`Models/Folder.swift`):
  - `id: String` (UUID)
  - `name: String`
  - `parentID: String?` (nil = root)
  - `kind: String` — `FolderKind` raw value: `documents` or `notes` (keeps the two
    trees separate)
  - `owner: String?`, `sortOrder: Int`, `createdAt`, `updatedAt`
- **`Document`**: add `parentID: String?` (folder id; nil = root of the documents tree).
- **`Note`**: add `parentID: String?` (folder id; nil = root of the notes tree).
- **`ScheduledTask`**: add `parentTaskID: String?` (nil = top-level task).
- Register `Folder.self` in `AnAIOdysseySchema.models`.

> All new fields are optional/defaulted ⇒ SwiftData performs an automatic
> lightweight migration; existing rows become root-level items.

### Repositories — **implemented**
- **New `FolderRepositoryProtocol`** + `SwiftDataFolderRepository`:
  - `createFolder(name:kind:parentID:)`, `fetchFolder(id:)`,
    `listFolders(kind:parent:)` (parent: `nil?` distinguishes "root" vs "any" via
    an explicit API), `listAllFolders(kind:)`, `renameFolder(id:name:)`,
    `moveFolder(id:newParentID:)` (guards against cycles), `deleteFolder(id:)`
    (recursively reparents/removes contained items — see deletion policy), `save()`.
- **Document/Note repos**: add `listChildren(parentID:)`, `move(id:toFolderID:)`,
  and accept an optional `parentID` on create.
- **Task repo**: add `listSubtasks(parentTaskID:)`, `listTopLevelTasks(...)`, and
  `parentTaskID` on create; expose subtask helpers via `TaskSchedulerService`.

**Deletion policy:** deleting a folder deletes the folder and **moves its direct
children (subfolders + items) up to the folder's parent** (no data loss). Deleting
a task with subtasks reparents the subtasks to the deleted task's parent.

**Cycle safety:** `moveFolder`/`move` reject moves where the new parent is the
node itself or one of its descendants.

### UI — **partial (2026-06-28)**
- **Documents** (`DocumentsWorkspaceView`): **done** — `FolderTreeView` sidebar +
  single-document editor; New Folder / New Document / rename / delete / drag-move.
- **Notes** (`NotesView`): **done** — same folder-tree pattern as Documents.
- **Tasks** (`TasksView`): **not done** — scheduled tasks remain a flat list;
  no outline/subtask nesting UI or "Add Subtask" affordance (data model + agent
  tools exist; see §21).
- **Multi-document tabs**: **not done** — Documents still use single selection,
  not a tab bar of concurrently open documents (`Document.isActive` exists in the
  model but the workspace does not expose multi-tab editing).

---

## 4. Feature: AI access to all knowledge (agent tools)

All structured knowledge must be reachable by the agent. Tools follow existing
conventions (`AgentTool`, fenced-block input, text output, `AgentToolSupport`),
are registered in `AgentStandardTools.all`, and described in
`AgentToolRegistry.toolDescriptions`.

**New/extended tools:**
- `list_folders` — list folders (optionally by kind/parent) as a tree.
- `list_folder` / `browse_folder` — list the contents (subfolders + items) of a
  folder by id or path.
- `create_folder`, `move_item` (move a document/note/folder into a folder).
- Extend `list_documents` / `list_notes` to show folder/path and accept an
  optional folder filter; `create_document` / `create_note` accept a target folder.
- `list_subtasks` — list a task's children; `create_task` accepts a `parent:` id.
- Keep output compact (ids + paths) so the model can navigate deterministically.

Path syntax for tools: `/Folder/Subfolder/Item`, resolved case-insensitively
within the relevant tree (`documents` or `notes`).

**Status (2026-06-28): implemented.** Folder tools live in `AgentFolderTools.swift`
(`list_folders`, `browse_folder`, `create_folder`, `move_item`, `list_subtasks`).
Document/note/task tools accept folder filters and `parent:` ids. Parser recognizes
all registered tool names (§6). Email tools gated by Settings (§12). Calendar list
tool refreshes EventKit + optional Google sync via `CalendarAgentAccess` before
reading the cache.

---

## 5. Feature: Structured Notion import

Honor the Notion export hierarchy instead of flattening.

**Notion export conventions (verified against the sample):**
- A page = `Name <32-hex>.md`.
- A page with children also has a sibling directory `Name <32-hex>/` holding its
  child `.md` files / subdirectories.
- Databases = `Name <32-hex>.csv` (+ `Name <32-hex>_all.csv`); the matching
  directory holds the row pages.

**Import mapping:**
- Each **directory** → a `Folder` (kind `documents`), named with the Notion id
  stripped, parented to its containing directory's folder. Folder ids are
  deterministic (`notion-folder-<id>` when the dir has an id suffix) for
  idempotent re-import.
- Each **`.md` page** → a `Document` with `parentID` = the folder for its
  containing directory (root if top-level). Title = stripped name. Internal links
  still rewritten to in-app anchors.
- A page that has **both** `Name <id>.md` and `Name <id>/` → mapped **literally**
  (as on disk): the directory becomes a folder and the `.md` becomes a document
  that is a **sibling** of that folder (both in the parent folder). This preserves
  the page's content and its children exactly as the export laid them out.
- **`.csv` databases** → a Document (Markdown table) in the containing folder.
- Breadcrumb-in-title behavior is dropped in favor of real folders.

Counts/reporting (`NotionImportCounts`) gains a `foldersCreated` tally.

**Status (2026-06-28): implemented.** `NotionImportService` creates real `Folder`
rows with deterministic ids (`notion-folder-<path>`), parents documents to folders,
imports `.csv` databases as Markdown tables, and reports `foldersCreated` in
`NotionImportCounts`. Covered by `NotionImportTests`.

---

## 6. Agent tool calling (AI data access) fix

**Symptom:** Asking the assistant (Agent mode) to e.g. "list my tasks" printed a raw
` ```list_tasks ``` ` block in the chat and returned no data.

**Root cause:** The text-based tool parser (`AgentToolParser`) only recognized a
hard-coded set of 5 tags (`read_document`, `edit_document`, `create_document`,
`search_memory`, `save_memory`). Every other registered tool (`list_*`,
`create_note`, `create_task`, folder/subtask tools, …) was never detected, so the
fenced block was treated as plain prose. A second defect dropped tool blocks with
an **empty body**, which is exactly what no-argument tools (`list_tasks`, etc.) emit.

**Remediation:**
- Parser now recognizes **every** registered tool name (`AgentToolRegistry.toolNames`,
  threaded into `parseToolBlocks`/`stripToolBlocks`).
- No longer skips empty-bodied blocks (tag is already constrained to a real tool).
- Agent mode now defaults **on** and persists (`@AppStorage`) so AI has data access
  out of the box. *(superseded — see §24: the toggle was removed; chats always
  run the tool-calling agent.)*

---

## 7. Memory / embeddings reliability

**Symptom:** "Embedding model is not loaded." when saving a memory (macOS, where the
on-device `MLXEmbeddingService` is used).

**Root cause:** `MemoryService` called `embeddingService.embed(...)` directly, but
`loadModel()` was never invoked at startup, and `MLXEmbeddingService.embed` threw
`.modelNotLoaded` instead of lazy-loading (the mock auto-loads, which is why iOS
didn't hit it).

**Remediation:**
- `MLXEmbeddingService.embed` lazily loads the model with a single-flight guard.
- `MemoryService` gained `ensureEmbedderReady()` (single-flight) + `warmUp()`, called
  from the app's `WindowGroup.task` at launch.
- **Health surfacing:** `EmbedderHealth` (`unknown`/`ready`/`unavailable(reason)`) is
  tracked and shown in the Memory view so failures aren't silent.
- **Graceful fallback / retry:** if embeddings are unavailable, the memory record is
  still saved and queued; `reindexPending()` re-embeds any un-indexed records once the
  embedder recovers (driven by `VectorIndexStore.indexedMemoryIDs()`), and runs on warm-up.
- **Dedupe:** `save()` reuses an existing memory with identical normalized text
  (session-scoped when a `sessionID` is given) so repeated chat summaries / preferences
  don't pile up duplicates.
- Tests: lazy-load regression, dedupe (global + session-scoped), graceful-fallback +
  reindex (`MemoryServiceTests`).

**View memories:** the Memory view now supports selecting a memory to see a read-only
detail pane (full text, created date, originating session, search-index status, id);
search moved to the standard `.searchable` bar and a "New Memory" toolbar action opens
the composer.

---

## 8. Navigation restructure (top tabs + in-feature sidebars)

**Request:** The left-hand sidebar for top-level areas (Email, Tasks, …) didn't work
well. Make the top-level switch a **tab panel across the top**, and use the
left-navigation (sidebar) approach *within* each function (e.g. Email's folder list).

**Root cause of the old breakage:** `RootView` wrapped everything in an outer
`NavigationSplitView` (sidebar = top-level sections), while each feature view has its
*own* `NavigationSplitView`. The nested split views fought each other, breaking
top-level selection / detail rendering.

**Change:**
- `RootView` now renders a custom **top tab bar** (`TopTabButton`s in a horizontal
  scroll, brand label at the leading edge) over the selected feature view — no outer
  split view, so no nesting.
- Each feature view keeps its own `NavigationSplitView`, which now *is* the primary
  split view, giving the in-feature left navigation.
- `AppSection.sidebarSections` → `AppSection.topLevelSections`.
- iOS Settings (a plain `Form`) is wrapped in its own `NavigationStack` since it no
  longer inherits navigation chrome from an enclosing split view.
- Tab buttons keep `sidebar-<section>` accessibility ids for UI-test continuity.

---

## 9. Email caching + Gmail folder structure

**Requests:** (1) Cache email so reopening the Email tab is instant — show cached
data immediately with an "updating" indicator (initially an empty inbox is fine).
(2) The Gmail "directory structure" interpretation was wrong.

**Caching / async (no more pause):**
- The Email tab previously called the synchronous reader (`listMailboxes`/
  `listMessages`/`loadMessageDetail`) from the main actor, so each visit blocked on
  the network. `EmailView` is also recreated per tab switch, losing its `@State`.
- `UnifiedMailReaderService` (long-lived) now caches the last successful mailboxes
  and per-mailbox message lists (lock-guarded), and exposes `cachedMailboxes()` /
  `cachedMessages(forMailboxID:)` for instant reads plus `async` `refreshMailboxes()`
  / `refreshMessages(...)` / `loadMessageDetailAsync(...)` that run the blocking work
  off the main thread (`@unchecked Sendable`, serialized via `lock`).
- `EmailView` renders cached data immediately, then refreshes in the background,
  showing an "Updating…" strip; empty mailboxes show a clean empty state.

**Gmail folder structure fix:**
- Old mapping used the opaque label *id* for the display name (so user labels showed
  as `Label_57…`) and listed every label including non-folders (UNREAD, IMPORTANT,
  CHAT, CATEGORY_*).
- New `GmailFolderMapping`: hides non-folder system labels; gives system folders
  friendly names (Inbox, Starred, Sent, Drafts, Spam, Trash); derives nested user-label
  hierarchy from the label *name* (`Work/Projects/Alpha` → `["Work","Projects","Alpha"]`)
  via the new `MailMailbox.displayPath`; orders system folders before user labels.
- `EmailView` renders the per-account mailbox hierarchy as a real tree
  (`OutlineGroup`/`MailboxTreeNode`); the iOS mailbox menu shows full paths.
- Tests: `AnAIOdysseyMailTests` covers hiding non-folders, friendly system names, nested
  user paths, and system-before-user ordering.

---

## 10. Tasks UI polish + HTML email viewer

**Requests:** (1) The Tasks tab formatting "doesn't look like an Apple UI" — make it
native. (2) Render the email body in a WebKit/HTML viewer ("is there a usual type?").

**Tasks tab (native styling):**
- Sidebar rows (`TaskRow`) now show a tinted status dot (green=active, orange=paused,
  gray=completed), the task name, a one-line **schedule summary** ("Daily at 9:00 AM",
  "Once · Jun 25, 3:00 PM"), and a trailing relative next-run time — Reminders-style.
- Shared `TaskPresentation` helper centralizes status color/symbol + schedule text;
  `TaskStatusBadge` is a tinted capsule reused in the detail header.
- `TaskDetailView` gained a header (icon + name + status badge + schedule summary),
  grouped sections (Schedule / Prompt / Subtasks / actions), `Label`-style buttons
  (Pause/Resume/Delete/Add Subtask), and subtask rows with status dots + chevrons.
- Both the detail and the new-task form use `.workspaceSettingsForm()` (grouped form
  style on macOS) for the standard inset-grouped Apple look.

**HTML email viewer (WebKit):**
- The "usual type" is **`WKWebView`** (WebKit); SwiftUI has no native HTML renderer.
- New `HTMLEmailView` wraps `WKWebView` cross-platform (`NSViewRepresentable` on macOS,
  `UIViewRepresentable` on iOS). It is **self-sizing**: after load it measures
  `document.body.scrollHeight` via JS and reports it so the body fits inside the
  message's outer `ScrollView` (no nested scrolling). Links open in the system browser.
- HTML is wrapped with a responsive `<meta viewport>` + system-font CSS and
  `color-scheme: light dark`. `MailMessageDetailView` now renders `bodyHTML` through
  `HTMLEmailView` instead of dumping the raw markup as plain `Text`.
- **Privacy — remote content blocked by default (follows Apple Mail):** remote
  (http/https) subresources — images, stylesheets, fonts, media, scripts — are blocked
  via a compiled `WKContentRuleList` so tracking pixels can't leak that the message was
  opened. Inline `data:`/`cid:` content still renders. When a message references remote
  resources, a banner ("Remote images aren't loaded… / Load Images") lets the user opt
  in per-message; approving removes the rule list and reloads. Fallback: if rule-list
  compilation fails, remote refs are stripped from the markup so nothing remote loads
  without approval.

---

## 11. Shared iCloud datastore (Mac ↔ iPad)

**Request:** "Why do my iPad and macbook have different datastores? I think they
should share one in iCloud." Then: "fix the entitlements and ios true."

**Root cause:** The app asks for CloudKit (`ModelContainerFactory.make(useCloudKit:
true)`) but gates on `ICloudAvailability.isAvailable`, which requires (a) a signed-in
iCloud account and (b) a non-empty iCloud-container entitlement. The entitlements file
was **empty** (`<dict/>`), and on **iOS** `hasICloudContainerEntitlement` was
**hardcoded `false`**. So both devices silently fell back to separate *local* SwiftData
stores — never syncing.

**Fix:**
- `AnAIOdyssey.entitlements` now declares `com.apple.developer.icloud-container-identifiers`
  (`iCloud.com.example.anaiodyssey.app`), `com.apple.developer.icloud-services` (`CloudKit`), and
  `com.apple.developer.ubiquity-kvstore-identifier` (for `CloudDefaultsSync`'s KVS).
- `ICloudAvailability.hasICloudContainerEntitlement` returns `true` on iOS (which can't
  introspect its own entitlements) so the iPad enables CloudKit when signed into iCloud;
  macOS still introspects via `SecTask` so teamless/unsigned builds stay local.
- SwiftData models are CloudKit-compatible (all properties defaulted, relationships
  optional, no `.unique`).

**Still required to actually sync (provisioning, not code):** sign with the team
(set `DEVELOPMENT_TEAM` in `Config/Local.xcconfig`) and enable the **iCloud → CloudKit** capability + the
`iCloud.com.example.anaiodyssey.app` container on the App ID (Xcode "Automatic" signing, or
`xcodebuild -allowProvisioningUpdates`). Unsigned/`CODE_SIGNING_ALLOWED=NO` builds ignore
the entitlement and remain local.

**Launch crash regression (fixed):** `AnAIOdyssey.entitlements` had reverted to an empty
`<dict/>`, so signed builds embedded *no* iCloud entitlements while iOS still assumed
CloudKit was available (`hasICloudContainerEntitlement = true`). On a signed-in iPad that
attempted CloudKit without entitlements and crashed at launch. Fix: restore the iCloud
entitlements plist, gate CloudKit on **both** platforms via `SecTask` entitlement
introspection (never assume on iOS), and fall back to local storage when the signed binary
lacks the container entitlement. Set `ANAIODYSSEY_FORCE_LOCAL_STORAGE=1` to force local
storage during debugging.

---

## 12. Settings-gated AI access to Email & Calendar

**Request:** "the AI should have access to the email gated by a settings checkbox.
Same with calendar access through gmail. It should have access if allowed in settings."

**Permissions (privacy-first, default off):** new `AIDataAccess` (AnAIOdysseyCore) exposes
`anaiodyssey.ai.allowEmailAccess` / `anaiodyssey.ai.allowCalendarAccess` keys (the `anaiodyssey.`
prefix means `CloudDefaultsSync` mirrors them across devices). Settings → **Privacy**
groups those toggles under the Email and Calendar tab sections (see §27). Bound via
`@AppStorage`; stored keys are unchanged.

**Email tools (new):** `EmailAgentTools` (AnAIOdysseyUI — the only module depending on both
AnAIOdysseyAI and AnAIOdysseyMail) defines `list_emails` and `read_email` over the
`MailReaderServiceProtocol` (preferring `UnifiedMailReaderService`'s async/off-main fetch,
HTML→text fallback). The app's composition root injects them into `AgentLoopService` via
new `extraTools` / `extraToolDescriptions` parameters (threaded through
`AgentToolRegistry.standard`). Each tool checks `AIDataAccess.isEmailAllowed` and refuses
with a "enable it in Settings" message when off.

**Calendar tool (gated):** `list_calendar_events` checks
`AIDataAccess.isCalendarAllowed` and refuses when off. **Refresh fix (2026-06):**
`CalendarAgentAccess` refreshes EventKit and optional Google Calendar sync before
reading the cache so the agent sees live events, not stale SwiftData rows only.
See also §20.

---

## 13. AI email drafting + user-initiated send

### 13.1 AI drafting (original request)

**Request:** "The ai should not have the ability to send mail, but it should be
able to draft emails in forward or reply, or new message mode."

**Design:** the assistant composes drafts that are persisted and surfaced for the
user to review and send. The AI has **no direct send tool** — sending is a
user-initiated action in the Email UI.

- **Model/persistence:** `EmailDraft` SwiftData model with `mode`
  (`new` / `reply` / `reply_all` / `forward` via `EmailDraftMode`), to/cc, subject,
  body, original message id/subject, account, source (ai/user), session, timestamps.
  `EmailDraftRepositoryProtocol` / `SwiftDataEmailDraftRepository` in
  `RepositoryBundle.emailDrafts`.
- **Agent tool:** `draft_email` parses header lines + body and saves a draft.
  Modes include `reply_all`. Agent prompt instructs: draft only; user sends from
  Email tab.
- **UI surfacing:** Email toolbar **Drafts** → `EmailDraftsView` list + editor.

### 13.2 Gmail send — reply / reply-all / forward *(added 2026-06-28)*

**Request:** Send replies (including AI-drafted text) from the app; support reply,
reply-all, and forward.

**Implemented (Gmail OAuth accounts only):**
- **`MailSendService`** + **`GmailAPIClient.sendMessage`**: builds RFC 822 MIME,
  base64url-encodes for Gmail API, threads replies via `threadId` +
  `In-Reply-To`/`References`.
- **`GmailMIMEComposer`**: recipient resolution for reply vs reply-all; `Re:` /
  `Fwd:` subjects; forwarded-message body formatting.
- **`EmailComposeView`**: shared compose sheet with Send/Cancel.
- **`EmailView` / `MailMessageDetailView`**: **Reply**, **Reply All**, **Forward**
  buttons; AI "Draft Reply" inline editor includes Send; opens compose pre-filled
  via `MailSendService.prepareCompose`.
- **`EmailDraftsView`**: **Review & Send** on saved drafts; draft deleted after
  successful send.
- **`UnifiedMailReaderService.gmailSendContext`**: maps UI message row ids back to
  Gmail account + API message id for threading.

**Not supported:** Apple Mail local store (read-only on macOS; no send API).
IMAP send deferred (§15).

**Agent rule unchanged:** no `send_email` tool — the user must confirm and tap Send.

---

## 14. Pop-out windows, month-grid Calendar, and a changeable theme

**Request:** "One should be able to pop out email/tasks/and calendar events as
separate windows. The calendar needs to look like a proper calendar with days of
the week. Then do another Apple HIG review of the app, combined with picking a
nice color scheme for the app that is changeable. Lastly, update the specs."

### Pop-out windows
- New auxiliary `WindowGroup`s in `AnAIOdysseyApp` for **Email**, **Tasks**, and
  **Calendar**, keyed by stable ids in `AppWindowID` (AnAIOdysseyUI). Public scene
  wrappers (`EmailWindowScene` / `TasksWindowScene` / `CalendarWindowScene`) host
  the existing feature views and tag them with `\.isPoppedOutWindow = true`.
- Each feature view's toolbar gains a `PopOutWindowButton` (`macwindow.on.rectangle`)
  that calls `openWindow(id:)`. The button hides itself inside the pop-out window
  (via the `isPoppedOutWindow` environment flag) so it doesn't recurse.
- All scenes (main, pop-outs, macOS Settings) share one dependency-injection
  modifier, `injectingAppEnvironment(_:)`, so every window resolves the same
  repositories, services, and settings objects.

### Month-grid Calendar
- `AppCalendarView` was rebuilt from a flat event list into a **proper month grid**:
  a header (wide month + year, ‹ ›, Today), a localized weekday header row
  (rotated to the locale's `firstWeekday`), and a 7-column `LazyVGrid` of day cells.
- Day cells show the day number (today filled with the accent), event indicator
  dots (up to 3 + "+N" overflow), and a selection ring. Tapping a day shows that
  day's events below; tapping an event opens a detail sheet; "New Event" opens a
  composer sheet pre-seeded to the selected day (9–10am). Events for the visible
  month window are loaded with the live service and fall back to cache offline.

### Changeable theme + HIG pass
- New `ThemeSettings` (AnAIOdysseyUI) `ObservableObject` persists an **accent palette**
  (`AppAccent`: Ocean/Indigo/Violet/Rose/Sunset/Forest/Graphite) and an **appearance
  mode** (`AppAppearance`: System/Light/Dark) under the `anaiodyssey.appearance.*` keys
  (iCloud-synced via `CloudDefaultsSync`). Default accent is **Ocean**.
- A single shared instance is created at the composition root and wrapped around
  every window via `ThemeContainer`, which applies `.tint(...)` +
  `.preferredColorScheme(...)`. Changing the theme updates the whole app — including
  open pop-out windows — live.
- Settings → **Appearance** adds a segmented Light/Dark/System picker and a row of
  tappable accent swatches.
- HIG polish: selection chrome (top tab bar, calendar day cells) now uses the
  `.tint` shape style so it tracks the chosen accent instead of the fixed asset
  accent color; toolbars and titles are consistent across the popped-out windows.

---

## 15. Deferred / backlog (near-term)
- IMAP mail backend (generic, for Yahoo/iCloud/etc.) including send.
- OpenAI Codex Console + Claude Console providers.
- Slack integration for agent external tools.
- Apple Mail send path (if feasible via AppleScript or Mail.app APIs).
- Full cross-device agent-task replication (`AgentTaskSharingService` beyond Bonjour discovery).

See **§22 Remaining requirements** for the full open-items list.

---

## 16. Multi-agent platform roadmap

Structured from product-owner notes (2026-06). Status: **foundation implemented**
(2026-06-27); voice (system + ElevenLabs streaming, OpenAI, xAI) implemented.
Slack,
Apple Intelligence APIs, and agent-task replication remain open.

### 16.1 Agent controller & multi-agent orchestration — **implemented (auto-run)**

- `AgentController` (AnAIOdysseyAI): creating a task starts it immediately.
  Pause/Continue keep conversation context; Stop keeps work so far (no confirm).
  Run-with-assignee is removed.
- SwiftData `AgentTask` model + repository (distinct from `ScheduledTask`).
  Statuses: `running`, `paused`, `stopped`, `done`, `error`. Stored legacy
  statuses migrate (`pending`/`handoff_*` → paused, `in_progress`/`claimed` →
  running, `completed` → done, `failed` → error).
- On cold start, any `running` task is marked `paused` (safer than silently
  resuming HTTP/tool rounds). The user taps Continue.
- Tasks UI: one status line (`Running: updating Trip Plan`, `Paused`, `Stopped`,
  `Done`, `Error: …`), a Pause/Continue toggle (`pause.fill` / `play.fill`) plus
  Stop (`stop.fill`), each an isolated borderless tap target, and a persisted
  change log of Document/Research items the run created or edited.
- Tasks can read and edit your documents and research. They can't see your email or calendar.
- Research assignments call `run_research`, which invokes `ResearchService` (same
  pipeline as the Research tab: Research feature model, web sources, saved
  Research item) and logs `Researched <title>` as a tappable change-log link.
  The task agent must not write a research report with document tools or
  `create_research`.
- Document-writing assignments call `write_document`, which invokes
  `DocumentWritingService` (Documents feature model from Settings → Default
  Models by Tab → Documents, generation pipeline, saved Document) and logs
  `Created <title>` or `Edited <title>`. Existing `read_document` /
  `edit_document` / `update_document` / `append_document` stay for small fixes.
  The task agent must not compose the full document with `create_document`.
- A task may do both: `run_research` first, then `write_document` using the
  research summary as context.
- Pause or Stop aborts an in-flight Research or Documents feature run; a
  cancelled run is not persisted. Continue asks the agent to call the tool again.

### 16.2 Adapter pattern for all AI agents — **implemented**

- `AgentAdapter` protocol: `AgentAttributes`, `AgentAssignment` (prompt/context
  combinations), `AgentWorkContext`, `run(assignment:)`.
- Adapters: `LLMAgentAdapter` (local + remote + tagged Claude/Codex personas),
  `CursorAgentAdapter` (macOS CLI).
- `AgentAdapterRegistry` + `AgentAdapterFactory.makeDefaultRegistry`.

### 16.3 Task list, history, notes, and data object creation — **implemented (foundation)**

- `AgentTaskEvent` history + `AgentArtifact` typed objects (email, task note,
  researcher message, chat→email, generic).
- Tasks UI: history + artifacts on task detail.
- `AgentTaskSharingService`: Bonjour `_anaiodyssey-agent._tcp` publish/browse stub
  (full cross-client replication deferred).

### 16.4 Task context persistence & pause/continue — **implemented**

- Inline context on `AgentTask` + file-backed context via `AgentTaskContextStore`
  (Application Support).
- Conversation JSON is saved on Pause so Continue resumes mid-run. Stop keeps
  results and the change log; it does not ask for confirmation.
- Human–AI handoff and run-with-assignee are removed. Legacy stored statuses
  map onto pause/continue/stop.

### 16.5 External tool invocation (Cursor, CLI, Slack, etc.) — **partial**

- **Cursor:** `CursorAgentAdapter` invokes `cursor agent` CLI (macOS); path in
  Settings → Agents. **`CursorCLILocator`** resolves the CLI without subprocesses
  (fixes Settings crash from blocking `which` on the main thread during layout).
- **Slack:** not implemented (investigate later).
- Tagging: cursor→coding, claude→ui_design, codex→backend on adapter metadata.

### 16.6 AI settings UI & controller AI selection — **implemented**

- Settings → **Agents & Controller**: controller picker, home/away agents,
  environment switching toggle, registered agent list with tags/availability,
  Cursor CLI path, voice provider + model/voice pickers (System always;
  ElevenLabs / OpenAI / xAI only when keyed).
- `AgentRegistrySettings` (iCloud-synced `anaiodyssey.agent.*` / `anaiodyssey.voice.*` keys).

### 16.7 Apple AI integration — **stub**

- `AppleIntelligenceService`: availability probe + status message; extend when
  App Intents / Writing Tools APIs are wired.

### 16.8 Voice integration — **implemented (system + ElevenLabs + OpenAI + xAI)**

- **`VoiceServiceProtocol`**, **`SystemVoiceService`**, **`ElevenLabsVoiceService`**,
  **`OpenAIVoiceService`**, **`XAIVoiceService`**, **`CompositeVoiceService`**.
  Settings → Voice (and Chat while voice control is on) uses the same two-row
  picker: **Voice Provider**, then **Voice**. Only providers with a working
  connection are listed. Voices use friendly names ("Ara", "Alloy") with no
  provider or model ids. Each voice has a play/stop Preview (`play.fill` /
  `stop.fill`) that plays a provider sample URL when one exists, otherwise a
  cached synthesis of a fixed phrase. ElevenLabs loads `GET /v2/voices`
  (paginated). Fetch failures show a short gray status instead of falling
  through silently. An **Add voice by ID** field looks up
  `GET /v1/voices/{id}` then `GET /v1/shared-voices`, previews the real name
  before save, and keeps added IDs in an **Added Voices** group (swipe /
  context-menu Remove). The saved `elevenLabsVoiceID` always stays in the
  list. Paid-plan / Voice Library permission errors are shown plainly.
- **Bar for every TTS provider:** LLM tokens are split by
  `StreamingSpeechChunker` into complete sentences (`.`, `!`, `?`, or newline)
  so the first spoken piece has a full intonation contour. Abbreviations,
  decimals, and ellipses are not treated as sentence ends. A very long
  unterminated run (~300 characters) flushes at the last clause boundary;
  `finish` flushes the remainder. Audio starts playing on the first streamed
  PCM/MP3 chunk. Cumulative text is the `StreamTextAccumulator` snapshot so
  prefixes are not re-spoken.
- **System voice (default):** Apple Speech framework STT (`SystemSpeechInputService`)
  + sentence-queued `AVSpeechSynthesizer` TTS (`AwaitableSpeechSynthesizer`)
  rendered with `write(_:toBufferCallback:)` into the shared duplex engine.
- **ElevenLabs:** WebSocket `wss://api.elevenlabs.io/v1/text-to-speech/{voice}/stream-input`
  (`ElevenLabsTTSCodec`, `pcm_24000`). The socket is opened when voice output
  turns on and reused across turns (idle timeout 90s, closed on background /
  voice-off). Text is flushed on the first complete sentence; base64 PCM chunks play
  through a primed `PCMStreamPlayer` as they arrive. HTTP `/v1/text-to-speech`
  sentence clips are the fallback if the socket cannot connect. STT is always
  on-device Apple Speech (ElevenLabs Scribe remains available on
  `ElevenLabsAPIClient` but is not the live input path).
- **OpenAI:** `POST /v1/audio/speech` with `gpt-4o-mini-tts` (also `tts-1`,
  `tts-1-hd`), `response_format=pcm`, `stream_format=audio`. Text cannot stream
  in, so each completed sentence is its own request; PCM chunks are scheduled as
  they arrive and the next sentence is requested while earlier audio still plays.
  That meets the bar in practice.
- **xAI:** bidirectional WebSocket `wss://api.x.ai/v1/tts` with language/voice/codec
  in query params (a bare URL is HTTP 400). Auth is `Bearer` from the xAI remote.
  Send `{"type":"text.delta","delta":...}` per sentence, then `{"type":"text.done"}`;
  receive `audio.delta` (base64 PCM) until `audio.done`. Multiple utterances share
  one connection. Voices from `GET /v1/tts/voices` (bundled `eve`, `ara`).
- **Linux tests:** encoding/protocol codecs in `AIModelOptions`
  (`ElevenLabsTTSCodec`, `XAITTSCodec`, `OpenAITTSCodec`, `PCMStreamFramer`,
  `VoiceCatalog`, `StreamingSpeechChunker`, `VoiceConnectionPolicy`,
  `VoiceLatencyTrace`, `VoiceEchoPolicy`, `VoiceAudioGraphPolicy`,
  `WorkspaceNavigationPolicy`, `VoiceLifecyclePolicy`,
  `ElevenLabsVoiceErrors`, `ThinkingSectionPolicy`). Live
  WebSocket/HTTP playback and the Voice picker need a Mac or iPhone with keys.
- **Low-latency spoken conversation:** when voice control is on (toggle, mic
  open, or foreground while still on) the app pre-warms DNS/TLS/HTTP2 to the
  LLM and TTS hosts, opens the ElevenLabs / xAI WebSocket, activates
  `AVAudioSession` as play-and-record in `.voiceChat` mode, primes a shared
  `AVAudioEngine` with voice processing (AEC), and preloads the system voice.
  Mic capture and every TTS provider (System via `write(_:toBufferCallback:)`,
  ElevenLabs / OpenAI / xAI PCM, HTTP MP3 fallback) play through that same
  engine so the voice-processing unit has a playback reference. First-turn and
  later-turn latency are timed separately (`requestSent` → `firstLLMToken` →
  `firstTTSRequest` → `firstAudioByte` → `playbackStart`). A soft tone plays
  when listening ends; the status line shows Thinking… then Speaking.
- **Duplex echo control:** speaker route defaults to AEC on and speech barge-in
  on. Headphones / AirPods / A2DP keep speech barge-in on (no room echo).
  Bluetooth HFP and Macs without voice processing turn speech barge-in off;
  tap and the stop button still interrupt. While Speaking the recognizer is
  gated (echo-transcript filter + VAD spike vs playback level). Listening
  resumes after a 300 ms tail. The mic button becomes `stop.fill` with
  “Tap to interrupt” when speech barge-in is off (`VoiceEchoPolicy`).
- **Car Bluetooth / route-change recovery:** connecting HFP or CarPlay (often
  8 or 16 kHz mono) while the shared engine is running must not crash. The
  graph observes `AVAudioEngineConfigurationChange`,
  `AVAudioSession.routeChangeNotification`, and `interruptionNotification`
  via nonisolated callbacks that hop to the main actor. On a change it stops
  the engine, removes the tap, **skips voice processing on HFP / CarAudio**,
  reconnects only when the hardware format is non-zero, restarts after a
  short settle, and re-installs the tap once. TTS PCM is converted with
  `AVAudioConverter` into the current mixer format. The speech recognizer
  request is recreated; it is never reused across a format change. Session
  category is `.playAndRecord` / `.voiceChat` with `.allowBluetooth` (HFP),
  `.allowBluetoothA2DP`, and `.defaultToSpeaker`; `setActive` is never
  force-tried and is never called while the engine is running. `UIBackgroundModes`
  includes `audio` so speech can continue when the car UI backgrounds the app.
  Recoveries show a short non-blocking banner (`VoiceAudioIssueMessage`).
  Simulated in `VoiceAudioGraphPolicy` / `VoiceLifecyclePolicy`.
- **Navigation persistence:** the phone vs tablet root is chosen by device
  idiom plus both size classes, not `horizontalSizeClass` alone (Plus/Max
  landscape is regular width but compact height, so it keeps the phone root).
  An iPhone that is regular in both directions (iPhone Duo unfolded) gets the
  tablet root, and folding it swaps back live. No view reads `UIScreen.main`;
  a source-scan test enforces that. The
  open chat ID, list-vs-detail flag, phone tab, and tablet section live in
  `@SceneStorage` (`WorkspaceNavigationPolicy`). ChatDetailView does not tear
  down voice on `onDisappear`; the voice service lives on the app model.
  Settings → Voice → Advanced has **Share audio debug log**. After an
  unexpected termination, a one-time prompt offers that log.
- **Chat integration:** mic button in `ChatDetailView` — tap to listen, tap again to
  transcribe and send; assistant reply appears in the transcript and is read aloud
  when the turn was voice-initiated or voice control is on. Listening / Thinking…
  / Speaking status shown inline.
- **Privacy:** `NSMicrophoneUsageDescription` and `NSSpeechRecognitionUsageDescription`
  in generated Info.plist (`project.yml`).
- **Apple Intelligence voice path:** still a stub (`AppleIntelligenceService` probe only).

**Agent chat tools:** `list_agent_tasks`, `enqueue_agent_task` injected into
`AgentLoopService` via `AgentQueueTools`. Task *runs* use a restricted tool set
(documents + research only: `run_research`, `write_document`, plus document
read/update and research read). Tasks can read and edit your documents and
research. They can't see your email or calendar.

---

## 17. Roadmap → deliverable formats (optional next steps)

The §16 groups can be turned into any of the following on request:

| Format | Best for |
|--------|----------|
| **Requirements document** | Scope, acceptance criteria, out-of-scope |
| **Technical architecture outline** | Protocols, services, data flow, persistence |
| **GitHub issues** | Sprint-sized tickets with dependencies |
| **Multi-agent system design diagram** | Controller, adapters, task queue, handoff |
| **Implementation task breakdown** | Phased milestones tied to existing packages |

**Suggested implementation order** (dependency-aware; updated 2026-06-28):

1. ~~§16.2 Adapter pattern~~ ✓
2. ~~§16.6 Settings UI~~ ✓
3. ~~§16.1 Agent controller~~ ✓
4. ~~§16.3 Task list / history~~ ✓
5. ~~§16.4 Context + handoff~~ ✓
6. §16.5 External tools — Cursor ✓; Slack open
7. ~~§16.8 Voice (system + ElevenLabs + OpenAI + xAI)~~ ✓; §16.7 Apple AI open

---

## 18. Voice chat in Chats workspace *(implemented 2026-06-28)*

**Request:** Button for voice input and output — speech-to-text on user speech,
then text-to-speech for the assistant reply, with both shown in the chat log.

**Implemented:**
- Mic button in `ChatDetailView` composer (left of text field).
- **Listen:** first tap starts capture; second tap stops, transcribes, sends as a
  user message. Speech-to-text is always on-device Apple Speech.
- **Respond:** normal agent/LLM path; assistant text persisted and streamed in the
  transcript as today.
- **Speak:** for voice-initiated turns (and typed turns while voice control is
  on), assistant tokens stream into TTS while the reply is still generating.
  The first complete sentence is spoken as soon as it arrives; later sentences
  follow the same rule. Audio starts on the first streamed chunk:
  - **System:** sentence-queued `AVSpeechSynthesizer` written into the duplex engine.
  - **ElevenLabs:** warm WebSocket `/stream-input` with `pcm_24000` playback via
    a primed `AVAudioEngine`; falls back to HTTP sentence clips if the socket
    cannot connect.
  - **OpenAI:** one streamed `POST /v1/audio/speech` (`pcm` + `stream_format=audio`)
    per sentence over a keep-alive HTTP/2 session.
  - **xAI:** one warm `wss://api.x.ai/v1/tts` connection; `text.delta` per sentence,
    PCM `audio.delta` until `audio.done`.
- Soft end-of-listening tone; Thinking… until the first audio buffer, then
  Speaking. Tap the transcript / Speaking line, or the stop button (mic becomes
  `stop.fill` + “Tap to interrupt” when speech barge-in is off) to interrupt.
  Speech barge-in stays on for headphones / AirPods and for the speaker when
  AEC is running; Bluetooth HFP is tap-only.
- Cancels listening/speech on navigate-away or Stop; warm sockets close after
  90s idle, on background, or when voice control is turned off.

---

## 19. Gmail send *(implemented 2026-06-28 — see §13.2)*

Summary: Reply, Reply All, Forward, and send-from-Drafts for Gmail OAuth accounts.
Apple Mail and IMAP not supported for send.

---

## 20. Platform polish *(2026-06)*

### iPad layout & window sizing
- `RootView` / `MacWorkspaceStyle`: workspace fills available space; Settings gear
  pinned outside horizontal tab scroller on iOS; compact tab bar on regular width.
- `AnAIOdysseyApp`: iOS default window size + resizable WindowGroups.

### Gallery feature flag
- Gallery tab **off by default**; Settings → Features → "Show Gallery (Photos)"
  (`FeatureSettings.galleryEnabledKey`). `RootView` hides the tab when disabled.

### Calendar AI access fix
- `list_calendar_events` previously read only the SwiftData cache. **`CalendarAgentAccess`**
  refreshes EventKit and optional Google Calendar sync before listing so the agent
  sees current events when permitted in Settings.

### Build & signing
- `project.yml`: development team, bundle id, iCloud entitlements restored;
  `CODE_SIGNING_ALLOWED: YES` for device builds. Verify scripts may still build
  unsigned for CI (`CODE_SIGNING_ALLOWED=NO`).

### Settings crash fix (Cursor CLI)
- `CursorAgentAdapter.isAvailable` no longer runs blocking `which` during SwiftUI
  layout; uses non-blocking `CursorCLILocator` PATH scan.

---

## 21. Implementation status summary *(2026-06-28)*

| Area | Data model / repos | Agent tools | UI |
|------|-------------------|-------------|-----|
| Document folders | Done | Done | Done (`FolderTreeView`) |
| Note folders | Done | Done | Done |
| Task subtasks | Done (`parentTaskID`) | Done (`list_subtasks`, `create_task` parent) | **Not done** (flat list) |
| Multi-document tabs | Done (`isActive`) | — | **Not done** |
| Notion structured import | Done | — | Settings import flow |
| Workspace export/import | Done | — | Settings backup flow (§23) |
| Email read (gated) | — | Done | Done |
| Email draft (AI) | Done | Done (`draft_email`) | Done (Drafts) |
| Email send (Gmail) | — | No send tool (by design) | Done (§13.2) |
| Voice chat | — | — | Done (§18) |
| Multi-agent queue | Done | Docs/research only; `run_research` + `write_document` hand work to those features; no email/calendar | Done (auto-run, pause/continue/stop) |

---

## 22. Remaining requirements to implement

The following items are **not yet done** or are **stub/partial** only. Ordered
roughly by user-visible impact.

### High priority (product gaps from original request log)

1. **Task subtask UI** — outline/list nesting in `TasksView` for scheduled tasks;
   "Add Subtask" on a selected task; detail pane showing children. Backend and
   agent tools already support `parentTaskID`.
2. **Multi-document tabs** — Documents workspace should support opening multiple
   documents as tabs (or equivalent) instead of single selection only; fix
   "open N tabs doesn't work" from request log item 4.
3. **IMAP mail** — generic backend for Yahoo, iCloud, etc. (`MailProvider.imap`
   exists; no reader/send implementation).

### Medium priority (roadmap §15 / §16)

4. **OpenAI Codex Console + Claude Console** — first-class remote LLM providers
   (beyond tagged agent personas on `LLMAgentAdapter`).
5. **Slack external tool** — agent invocation of Slack (post/read) per §16.5.
6. **Agent task sharing** — replicate `AgentTask` state across AnAIOdyssey instances
   on a LAN (Bonjour publish/browse exists; no task sync protocol).
7. **Apple Intelligence integration** — App Intents / on-device Writing Tools /
   Apple Intelligence voice APIs (§16.7); currently probe + status message only.
8. **Apple Mail send** — if desired, send via Mail.app integration on macOS (read
   path exists; no compose/send).

### Lower priority / polish

9. **Tasks UI polish (§10)** — richer Reminders-style rows, schedule summaries, and
   grouped detail sections described in §10 may be partially aspirational vs current
   simpler `ScheduledTaskRow` / `ScheduledTaskDetail`; reconcile and finish if still
   desired.
10. **Voice mode enhancements** — always-on TTS for typed messages *outside*
    voice control (typed turns already speak while voice control is on).
    Live ElevenLabs list + add-by-ID are implemented (see §29). Barge-in and
    continuous conversation are implemented (tap / mic interrupt, warm
    sockets, Thinking… / Speaking).
11. **Email** — new-message compose from scratch (not only reply/forward/drafts);
    send from unified inbox when message account attribution is ambiguous.
12. **CloudKit provisioning alignment** — ensure App ID container matches entitlements
    (`iCloud.com.example.anaiodyssey.app` vs bundle `com.example.anaiodyssey`) in Developer
    portal for reliable Mac ↔ iPad sync.
13. **SPEC §17 deliverables** — optional: GitHub issues, architecture diagram, or
    phased implementation tickets derived from this spec.

---

## 23. Feature: Workspace export / import *(2026-09-03)*

Backup and restore the local workspace without touching Mail or Calendar.

**Included:** chat sessions and messages, folders, documents and versions, notes,
memories, gallery albums/images (bytes on disk), comparisons, research reports,
scheduled tasks (including subtasks), agent tasks / events / artifacts, and
agent-task context files.

**Excluded:** `EmailDraft` and `CalendarEventRecord` (and live Mail / EventKit
data). Email provenance fields on documents are kept because they belong to the
document record, not the mail store.

**Format:** a zip (`manifest.json` + `payload.json` + `gallery/` + `contexts/`),
format version 1. Import is additive and idempotent (existing ids are skipped).
Memory embeddings are not stored; Settings re-indexes after import.

**UI:** Settings → Workspace Backup → Export workspace / Import workspace.

---

## 24. Model pickers, Options, Compare, xAI, and docs *(2026-10-09)*

User-facing name is **An AI Odyssey** (modules stay `AnAIOdyssey`). Documents are
a **basic** folder of files with a single editor, not a second brain and not
confirmed to sync across every device.

**Models.** Chat/documents/research/email/tasks pickers list the **10 newest chat models by
release date, newest first** (on-device AI on supported devices, plus that
remote slice). Image
pickers list image models only. Official remotes that the protocol layer actually
encodes: OpenAI GPT-6 Astra / GPT-6.1 Sol / GPT-6 Luna / GPT-5.6 via `/v1/responses`
for reasoning and tools; xAI Grok 4.7, 4.6, 4.5 and `grok-imagine-image-2.0` at
`https://api.x.ai/v1`. Settings → Add xAI seeds that catalog.

**Options.** Every function picker (Chat, Documents, Research, Email, Gallery, Settings)
reuses the same `ModelPickerOptionsView` (thinking, context, max output, remember
thinking). Inherited Settings tabs stay read-only until they have their own model.

**Compare.** No default and no chat-only filter. Empty state: “Pick two or more
models to compare.” The selected-count caption appears only after at least one
model is picked. Searchable multi-select (not one picker per slot). Image
comparison sends the same prompt to every selected model and shows equal-size
tiles (`220` pt) with the model name and a Share button (`WorkspaceImageShareLink`).
Text tiles scroll internally and open full-screen on tap so long answers can be
read. Blind comparisons title tiles “Model 1”, “Model 2”, … until names are
revealed.

**Agent always on.** The Chat agent toggle and any copy about turning agent mode
on or off are gone. Sends always run the tool-calling loop.

---

## 25. On-device models on iPhone/iPad, and Continue with ChatGPT *(2026-10-09)*

**Local support is decided per device at runtime**, never with a blanket
“iOS has no local models” rule. `LocalOnDevicePolicy` +
`OnDeviceLanguageModelSupport` probe the live device.

**On-device AI on supported devices** (Mac and supported iPhones/iPads). Apple’s
on-device model is labeled **Apple On-Device** in pickers, has no Thinking
control (same as other local models), and is suited to summarizing and
rewriting — not a full offline chatbot. `SystemLanguageModel.default.availability`
reasons are handled separately:

- `.deviceNotEligible` — hide the option
- `.appleIntelligenceNotEnabled` — keep the option and show “Turn on Apple
  Intelligence in Settings to use on-device AI.”
- `.modelNotReady` — keep the option and show “Getting ready…” with no Download
  button (the system manages that download)
- `.available` — ready to use

Eligible Apple Intelligence hardware:

- iPhone 15 Pro and later, including iPhone Air (A19 Pro, 12 GB RAM) and the
  iPhone 16 / 17 / 18 lines
- iPads with M1 or later, or A17 Pro
- Macs that support Apple Intelligence

**MLX** (Llama 3.2 1B/3B 4-bit) is offered on any platform where there is a
Metal GPU, the process is not a Simulator, and at least one catalog model fits
the ¾-RAM budget (`1.2 GB` / `2.5 GB`). Physical iOS 17+ phones with ~3 GB RAM
can run the 1B; ~4 GB and up can run both sizes. Simulator never offers MLX.

Two cases that must not be mixed:

- **This device has no local backend** (ineligible for Foundation Models, and
  MLX fails Metal/memory/simulator): hide the **entire** Settings → Local
  Models section. No Llama, no Apple On-Device in pickers or Compare.
- **Supported but nothing downloaded yet** (MLX-capable device): still show
  Local Models with a **Download** button. Pickers and Compare list only MLX
  weights that are on disk, plus Apple On-Device unless the device is ineligible.

First-run is platform-specific. ChatGPT sign-in is **Mac-only until OpenAI
allows it on mobile** (the open-source flow only documents
`http://127.0.0.1:<port>/auth/callback`, which iPhone and iPad cannot complete).
Do not show Continue with ChatGPT, the plan caption, or ChatGPT intro copy on
iOS — tapping that button would throw `iOSNotSupported`.

- **Mac:** Continue with ChatGPT first, then Add API Key, then on-device rows.
- **Supported iPhone/iPad:** Apple On-Device first, then Add API Key, then
  local MLX.
- **Unsupported iPhone/iPad** (no local backend): Add API Key only.

**Continue with ChatGPT.** Mac Settings → Remote Model Connections leads with a
“Continue with ChatGPT” text button (high-contrast fill, no blossom mark) and
the line “Uses your ChatGPT Plus or Pro plan.” Hidden on iOS/iPadOS. **TODO:
add the official ChatGPT logo from OpenAI’s brand kit**
(https://openai.com/brand) next to the label — do not ship a hand-drawn
approximation; OpenAI’s brand rules require the official asset. OAuth 2.0
Authorization Code + PKCE + OIDC against
`https://auth.openai.com/api/accounts/authorize` and
`…/oauth/token`. First registration uses `client_id=dynamic_agent_client`, a
stable `ext_agent_host_id`, and `agent_name_hint=An AI Odyssey`; the issued
`oaiapp_…` client id is saved per account and reused. Scopes: `openid profile
email offline_access resource.invoke chatgpt.tokens.use.direct` with
`resource=https://api.openai.com/v1`. No client secret. The documented callback
is `http://127.0.0.1:<port>/auth/callback` (loopback only), which the Mac
sign-in uses. Tokens live in the Keychain and are refreshed; the access token
is the Responses API Bearer. Plan-usage eligibility is the granted
`chatgpt.tokens.use.direct` scope — a valid ID token alone is not enough.
Ineligible accounts say so and point at an API key or (where local models
actually run) a Download. Inference uses `store: false`.

---

## 26. First-run, Compare, and ChatGPT branding UX *(2026-10-09)*

**First-run.** Hide `ContinueWithChatGPTButton`, `ChatGPTPlanCaption`, and
ChatGPT intro copy on iOS/iPadOS. Order on supported phones/tablets: Apple
On-Device, Add API Key, local MLX. Unsupported: Add API Key. Mac keeps Continue
with ChatGPT first. Settings → Remote Model Connections also hides the ChatGPT
button on iOS. Toolbar **Not now** stays; the duplicate bottom button is gone.

**Compare.** Equal-size `220` pt grid tiles. Text answers scroll inside the tile
and open full-screen on tap. Blind titles are “Model 1”, “Model 2”, … until
reveal. Selected-count caption is hidden while the empty state (“Pick two or
more…”) is showing.

**ChatGPT mark.** Removed the hand-drawn blossom (`ChatGPTMark`). The Mac button
is the text label “Continue with ChatGPT”. **TODO: add the official ChatGPT
logo from OpenAI’s brand kit** (https://openai.com/brand). Do not reintroduce a
drawn approximation.

**Voice preview.** `play.fill`, switching to `stop.fill` while playing (tap
stops).

**Connection editor.** Pointer copy: “Thinking and context are set under each
model picker in AI Models.”

---

## 27. Chat web search + Privacy by tab *(2026-10-11, Brave default 2026-10-12)*

**Request:** Privacy option “Allow web search in Chat,” default off. Default
engine is **Brave Search**, run by the app as a `web_search` tool (every
provider, including local). OpenAI/xAI native search is an opt-in picker
value. My Search Server (SearXNG) stays under Advanced. DuckDuckGo is **not**
a selectable engine. Saved `duckDuckGo` settings migrate to Brave. The
unofficial DuckDuckGo HTML results page is not used.

**Toggle and engine:** `AIDataAccess.chatWebSearchKey` /
`chatWebSearchEngineKey` (`anaiodyssey.ai.allowChatWebSearch` /
`anaiodyssey.ai.chatWebSearchEngine`). Engine default `brave`. Picker:
“Brave Search” and “AI provider search (may add to your bill)”.
**Advanced** (not first-run): “My Search Server”. Chat and Research share the
selected engine and the SearXNG address (`anaiodyssey.search.searxBaseURL`).

**Brave Search (official API):** `GET https://api.search.brave.com/res/v1/web/search`
with `X-Subscription-Token` (verified against Brave’s current docs). Key stored
in the Keychain as `brave-search`. Settings: key field, **Get a free key** →
https://brave.com/search/api/, **Test** next to the field, and the gray
footnote “Brave asks for a card but doesn't charge within the free limit.”
Parser: `BraveSearchCodec` (`web.results[{title,url,description}]`).

**Brave terms:** Results may be stored only temporarily. The app keeps Brave
payloads, snippets, and fetched page text in memory for the current Chat or
Research turn and does **not** cache them. Chat history and Research items
persist the model’s answer plus source titles and links — never raw Brave
JSON, snippets, or page excerpts. The free plan requires attribution: when
Brave answered, Chat and Research show “Search results from Brave” with the
sources.

**My Search Server (SearXNG):** Label is “My Search Server”; help text names
SearXNG. Address field plus **Test** → `/search?q=test&format=json`. Green
check on JSON; “Can't reach it. Is your VPN on?” if unreachable; HTML / 403 /
429 explain that JSON output must be enabled and the limiter must allow this
device. Same address is used by Research when that engine is selected.

**Snippet engines (Brave, SearXNG):** Chat still fetches the top 2–3 result
pages on device (~3k cap, 8s / 256KB) and shows source links.

**Keyless / failed fallback:** When Brave has no key or the request fails
(and the selected engine is not a working search server), Chat and Research
use official free sources only: DuckDuckGo Instant Answer API
(`https://api.duckduckgo.com/?q=…&format=json&no_html=1`) plus Wikipedia
opensearch. Never the HTML results page. No-key copy, shown at most once per
chat on the first fallback reply (tappable → Settings → Privacy, Brave key
focused): “Quick facts only. Add a free Brave key for full web results.”
Failure lines always show, e.g. “Couldn't reach Brave, so this used quick
facts.” or “Couldn't reach your search server, so this used quick facts.”
If those official sources also fail: still answer, gray line “Couldn't reach
a search service, so this answer doesn't use the web.”, and
`WEB_SEARCH_FAILED`.

**Research:** Uses the same selected engine as Chat (Brave / My Search Server /
AI provider). It does **not** keep a separate DuckDuckGo HTML cascade. Brave
sources persist title + URL only. Copy lives in
`PrivacyDisclosures.researchFooter(engine:)`.

**Chat UX:** toolbar `globe` when the toggle is on; “Searching the web…” with
`globe` while searching; tappable source links (title + domain) and a small
globe on messages that used the web. When search is off and the prompt looks
current (`latest` / `today` / `news` / date or price, or the model says it
needs the web): one line “Web search is off.” with **Turn On** → Settings →
Privacy. Not on every message.

**Privacy page:** one Form `Section` per `PrivacyTab` (Chat, Research, Search,
Tasks, Documents, Notes, Email, Calendar, Gallery, Memory, Compare). Header is
the tab name + SF Symbol; footer is `PrivacyDisclosures.disclosure`. Chat and
Research footers name the **currently selected** engine and say searches go to
Brave Search when Brave is active. Tabs that send nothing use “Nothing from
this tab leaves your device.” Mail/calendar toggles moved into those
sections; keys unchanged. First-run setup still has no search picker.

**Copy source of truth:** `PrivacyDisclosures` in AIModelOptions.
Chat Brave footer: “When on, search terms from your chat go to Brave Search,
and the result pages it reads see a normal page visit.” My Search Server:
search terms go to your own search server, which forwards them to the search
engines it's set up to use, plus the page-visit sentence. Provider footer
includes the bill warning. Fallback footer names DuckDuckGo Instant Answers
and Wikipedia. Linux tests cover Brave/SearXNG JSON fixtures, DDG→Brave
migration, fallback selection order, a disclosure for each engine, no
HTML-results-page URL builder, and that a Brave-sourced persisted message has
no raw result snippets.

**On-device checks (Mac / iPhone):**
- Brave with a key: globe, “Searching the web…”, source links, “Search
  results from Brave” in Chat and Research. Build shows the current
  marketing version (leave `CURRENT_PROJECT_VERSION` as the maintainer set it).
- No Brave key: first Chat reply that used fallback shows the tappable
  “Quick facts only. Add a free Brave key for full web results.” line once
  per chat; tap focuses the Brave key field. Get a free key + Test sit next
  to the field; card footnote underneath.
- Bad / unreachable Brave key: “Couldn't reach Brave, so this used quick
  facts.”
- Old DuckDuckGo setting is migrated to Brave.
- My Search Server: VPN **on** → Test shows a green check. VPN **off** →
  Test shows “Can't reach it. Is your VPN on?” and Chat/Research fall back
  to quick facts.
- Privacy footers update per engine and name Brave when Brave is active.

## 28. LM Studio streaming (`reasoning_content`) *(2026-10-12)*

**Request:** User: “It seems like for LM Studio protocol streaming isn't
working.” Chat sat on “Waiting for the model…” until thinking finished, then
the reply appeared all at once.

**Protocol (verified):** the app talks to LM Studio’s OpenAI-compat
`POST http://localhost:1234/v1/chat/completions` with `stream: true`
(`RemoteConnection.defaultLMStudioBaseURL`, encoding `.lmStudioHarmony` →
`OpenAIChatCompletionsAdapter`). Native `/api/v1/chat` is not used.
`shouldUseResponsesAPI` is official OpenAI / xAI only. Timeout is already
600s. SSE is `URLSession.bytes(for:)` + `bytes.lines` (line-by-line, not
whole-body). Streaming headers: `Accept: text/event-stream`,
`Cache-Control: no-cache`, `X-Accel-Buffering: no`.

**Root cause:** LM Studio (developer reasoning on) streams thoughts as
`delta.reasoning_content` (0.3.9+, DeepSeek-style) or `delta.reasoning`
(0.3.23+ gpt-oss). `StreamTextCodec.extractChatText` / `classify` only read
`delta.content`, so those chunks were skipped. `RemoteLLMService` collected
reasoning via `parseStreamingReasoning` but surfaced it only after the stream
ended when no content had arrived (`if !yielded`). The bubble stayed empty
until thinking ended, then content (or the whole thought dump) appeared at
once. File: `StreamTextCodec.swift` `extractChatText` / `classifyReasoning`;
`RemoteLLMService.swift` `performStreamingRequest` / `agentRound`.

**Fix:**
- `classifyReasoning` reads `reasoning_content` / `reasoning` on `delta` or
  `message`. Chat yields `AgentEvent.reasoning` live; ChatsView shows a
  **Thinking** disclosure and hides the hourglass while thoughts stream.
  Visible `delta.content` still goes to the bubble.
- While thoughts stream and no content has arrived, Thinking stays **open**.
  On the first content token it auto-collapses to a gray
  **Thought for N seconds** line (caret to expand) unless the user already
  expanded it. `N` is first reasoning token → first content token, rounded
  to whole seconds (`Thought for 1 second` singular; `Thought for a moment`
  if under 1s). Timing/label logic lives in `ThinkingSectionPolicy`.
- Reasoning is persisted on the assistant message (`assistantReasoning` /
  `thoughtDurationSeconds` in metadata) so reopened chats show the same
  section **collapsed**.
- Remote Chat/agent always uses `agentRound` (not only
  `supportsStructuredTools`) so Harmony LM Studio gets `onReasoning`.
- `StreamTextAccumulator` growing-prefix snapshot fold requires assembled
  text ≥ 16 characters, so repeats (`the` / `the`) and short prefixes
  (`to` / `today`) append. Whitespace-only deltas append.
- `ssePayload` accepts `data:` with or without a space and `\r\n`. Comments
  and `[DONE]` are skipped. Tool-call fragments accumulate by index.
- Voice `StreamingSpeechChunker` still waits for a sentence of **content**,
  not the full reply and not reasoning.

**Linux fixtures** (`LMStudioSSEFixtures` in `StreamTextCodecTests`): plain
content, reasoning-then-content, reasoning-only, `\r\n` / no-space `data:`,
usage-only final, tool-call fragments, repeated-token / short-prefix /
whitespace deltas.

**On-device checks (real LM Studio):**
- Developer reasoning **on**, a thinking model: Thinking disclosure grows
  while thoughts stream, then collapses to “Thought for N seconds” when the
  reply starts. Expanding it manually must not force-collapse. It must not
  freeze then dump.
- Developer reasoning **off**: no Thinking disclosure; content streams as
  before.
- Reopened chats with saved reasoning show Thinking collapsed.
- Repeated tokens (`the the`) and `to` / `today` must not collapse.
- Tool calls still stream argument fragments.
- Voice still speaks sentence chunks of the visible reply, not thoughts.

## 29. ElevenLabs voice picker (library IDs + add-by-ID) *(2026-10-12)*

**Request:** A custom ElevenLabs voice `VoiceIdPlaceholder01` did not appear in
the Voice picker. `/v1/voices` only returns account “My Voices”; a Voice
Library ID that was never added is omitted. `WorkspaceVoicePicker` used
`try?` and fell back to `VoiceCatalog.elevenLabsVoices`. `selectedVoice`
fell back to `voices.first`, which silently switched the selection.

**Fix:**
- List voices with paginated `GET /v2/voices` (`page_size` 100,
  `next_page_token` / `has_more`). Parser is tolerant of v1 bodies and
  missing `preview_url` / extra fields such as `category`.
- Surface fetch failures as a short gray status line (do not swallow).
- **Add voice by ID:** paste looks up `GET /v1/voices/{voice_id}` first,
  then `GET /v1/shared-voices?search=<id>`. Show the real name and a
  preview **before** Add. If not found: “No ElevenLabs voice with that ID.”
- Adding a library voice calls
  `POST /v1/voices/add/{public_owner_id}/{voice_id}` (`new_name` = voice
  name) so it appears in `/v2/voices`. If that add fails, still keep it in
  **Added Voices**.
- Added Voices sit at the top of the ElevenLabs list; swipe-to-delete on
  iPhone, context-menu Remove on Mac. Custom IDs persist in
  `anaiodyssey.voice.elevenLabsAddedVoices`. The current
  `elevenLabsVoiceID` is always merged into the list.
- Free / paid-only Voice Library voices (`free_users_allowed == false` or
  a plan/permission TTS or add error) show
  “This voice needs a paid ElevenLabs plan.” in the picker and when
  speaking.

**Linux tests:** v2 URL + page parser, pagination stop rules, shared-voices
parser + ID match, paid-plan error mapping, Added Voices encode/decode,
picker merge that keeps a saved ID, `ThinkingSectionPolicy` labels.

**Mac / iPhone checklist:**
- Voice `VoiceIdPlaceholder01` appears (via `/v2/voices` or Add voice by
  ID) and preview / spoken reply play.
- Thinking collapses with an LM Studio reasoning model.

---

## 30. Subscription sign-in: ChatGPT on every platform, Grok plumbing *(2026-10-15, build 22)*

Supersedes the “Mac-only” rules in §25–26 for Continue with ChatGPT.

**iPhone/iPad.** The open-source flow still only allows
`http://127.0.0.1:<port>/auth/callback`. The app binds an `NWListener` to
`127.0.0.1` (never other interfaces), shows `ASWebAuthenticationSession` with no
callback scheme, and closes the sheet itself when the listener receives the
callback. The listener ignores other paths (favicon) and empty preconnects.
First-run and Settings show the ChatGPT offer on every platform.

**UI (OpenAI UI/UX guidelines).** Offer block “Use your ChatGPT plan” +
“Complete eligible AI requests in this app with usage included in your ChatGPT
plan or credits balance.” + **Continue with ChatGPT**. One-time alert
“You’re using your ChatGPT plan” / “Eligible usage in this app uses your ChatGPT
plan. Manage usage in your ChatGPT settings.” with **Got it** (and Manage usage),
stored in `anaiodyssey.chatgpt.planNoticeShown`. “Using ChatGPT plan · Manage
usage” sits above the chat composer and on the connection row; Manage usage
opens `https://chatgpt.com/settings/usage`. Ineligible rows offer **Enable
ChatGPT plan usage** (re-auth with the saved client id and `prompt=consent`).

**Inference.** Plan connections always use `POST /v1/responses` with
`stream: true`, `store: false`, full history in `input`, system text in
`instructions`, and no `previous_response_id`, `temperature`, `top_p`,
`max_output_tokens`, `truncation`, `metadata`, `user`, etc. Non-streaming callers
collect the stream. Tool rounds resend the model’s `function_call` items before
their outputs because nothing is stored server-side.

**Errors.** `subscription_sharing_user_not_eligible` (403): mark plan usage off,
keep the sign-in, retry once on an enabled API-key connection for the same host,
and say so; with no key, explain Plus/Pro and point to adding an API key.
`…usage_limit_exceeded` (429): Manage usage, no billing switch.
`…unavailable` (503): keep credentials, retry later. Refresh `invalid_grant` /
`refresh_token_*`: clear tokens, keep the issued client id, ask to sign in
again. Network/5xx refresh errors keep credentials.

**Grok (pending).** `DeviceAuthorizationCodec`, `OIDCDiscoveryDocument`,
`OAuthTokenSet`, and `SubscriptionBillingPolicy.classifyEntitlement` (402/403 →
API key) are ready. `XAISubscriptionConfig.bundledClientID` is `nil`; no Grok
sign-in UI ships until the maintainer approves a client id.

