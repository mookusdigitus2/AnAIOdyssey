// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import AnAIOdysseyAI
import AnAIOdysseyMail
import SwiftUI

/// The Email workspace (cross-platform): browse a unified inbox and per-account
/// mailboxes from one or more Gmail accounts (and Apple Mail on macOS), with AI
/// summarize/reply assists.
///
/// Before showing the browser, the view resolves the reader's access status and
/// routes to the appropriate gate — a permissions prompt (Full Disk Access on
/// macOS), a "no accounts" prompt that offers Gmail sign-in, or the live browser.
struct EmailView: View {
    /// Unified, multi-account mail reader; `nil` if none was injected.
    @Environment(\.mailReader) private var mailReader
    /// Multi-account store driving Gmail OAuth sign-in / account management.
    @EnvironmentObject private var accountStore: MailAccountStore
    /// Data layer, used to surface AI-composed email drafts.
    @Environment(\.repositories) private var repositories

    /// Resolved access state that decides which gate/browser to show.
    @State private var accessStatus: MailAccessStatus = .mailNotConfigured
    /// Mailboxes for the leading column (incl. the synthetic "All Inboxes").
    @State private var mailboxes: [MailMailbox] = []
    /// Message summaries for the selected mailbox.
    @State private var messages: [MailMessageSummary] = []
    /// Selected mailbox id (defaults to the unified inbox).
    @State private var selectedMailboxID: Int64? = UnifiedMailReaderService.unifiedInboxID
    /// Selected message id.
    @State private var selectedMessageID: Int64?
    /// Fully loaded body/headers for the selected message.
    @State private var messageDetail: MailMessageDetail?
    /// True while a message body is being fetched.
    @State private var isLoadingDetail = false
    /// True while a background mailbox/message refresh is in flight (drives the
    /// "Updating…" indicator shown over the instantly-rendered cached data).
    @State private var isUpdating = false
    /// Surfaces mailbox/message load errors.
    @State private var loadError: String?
    /// Fingerprint of the Google accounts whose mail is currently displayed,
    /// so account-change observers do not rebuild readers twice after sign-in.
    @State private var displayedAccountFingerprint = ""
    /// True while an interactive Gmail sign-in is in flight.
    @State private var isAddingAccount = false
    /// Surfaces sign-in failures.
    @State private var accountError: String?
    /// Presents the Drafts review/edit sheet.
    @State private var showingDrafts = false
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// iPhone: when true, stay on the message list even if a message id is selected.
    @State private var phoneBrowsingMessageList = true
    #endif

    /// True when at least one Gmail account has usable tokens. On macOS this
    /// must win over Apple Mail's Full Disk Access denial so Google sign-in
    /// can open the inbox.
    private var hasSignedInGmail: Bool {
        accountStore.googleAccounts.contains { accountStore.isSignedIn($0) }
    }

    /// Routes between the permission gate, the no-accounts gate, and the browser.
    var body: some View {
        Group {
            if mailReader != nil {
                if hasSignedInGmail || accessStatus == .available {
                    mailBrowser
                } else {
                    switch accessStatus {
                    case .permissionDenied:
                        #if os(macOS)
                        MailPermissionView {
                            Task { await reloadReaderAndDisplayMail() }
                        }
                        #else
                        notConfiguredView
                        #endif
                    case .mailNotConfigured, .available:
                        notConfiguredView
                    }
                }
            } else {
                ContentUnavailableView(
                    "Email Unavailable",
                    systemImage: "envelope",
                    description: Text("Mail reader was not configured.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("Email")
        .toolbar { accountToolbar }
        .accessibilityIdentifier("email-view")
        .onAppear(perform: refresh)
        .onChange(of: signedInGoogleAccountFingerprint) { _, newValue in
            guard newValue != displayedAccountFingerprint else { return }
            Task { await reloadReaderAndDisplayMail() }
        }
        .sheet(isPresented: $showingDrafts) {
            if let repositories {
                EmailDraftsView(repositories: repositories)
            }
        }
    }

    /// Signed-in Gmail account ids; changing this set means mail sources changed.
    private var signedInGoogleAccountFingerprint: String {
        accountStore.googleAccounts
            .filter { accountStore.isSignedIn($0) }
            .map(\.id)
            .sorted()
            .joined(separator: ",")
    }

    /// Toolbar actions: refresh mail, review AI drafts, and connect another Gmail
    /// account (available in any state).
    @ToolbarContentBuilder
    private var accountToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await pullToRefresh() }
            } label: {
                if isUpdating {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .disabled(isUpdating || mailReader == nil)
            .help("Refresh mail")
            .accessibilityIdentifier("email-refresh-button")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                showingDrafts = true
            } label: {
                Label("Drafts", systemImage: "square.and.pencil")
            }
            .disabled(repositories == nil)
            .accessibilityIdentifier("email-drafts-button")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await addGoogleAccount() }
            } label: {
                Label("Add Gmail Account", systemImage: "plus")
            }
            .disabled(isAddingAccount)
            .accessibilityIdentifier("add-gmail-account-button")
        }
        ToolbarItem(placement: .primaryAction) {
            PopOutWindowButton(windowID: AppWindowID.email)
        }
    }

    /// Empty-state shown when no usable mail source is configured yet.
    ///
    /// Prompts to connect a Gmail account via OAuth (and, when no client id is
    /// set, explains the one-time Google OAuth client id requirement).
    private var notConfiguredView: some View {
        ContentUnavailableView {
            Label("No Mail Accounts", systemImage: "envelope.badge")
        } description: {
            if accountStore.isOAuthConfigured {
                Text("Connect a Gmail account to read your mail securely over OAuth.")
            } else {
                Text("Enter a Google OAuth Client ID in Settings, then connect a Gmail account to read your mail securely over OAuth.")
            }
        } actions: {
            Button {
                Task { await addGoogleAccount() }
            } label: {
                Label(isAddingAccount ? "Connecting…" : "Connect Gmail", systemImage: "envelope.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(isAddingAccount || !accountStore.isOAuthConfigured)
            .accessibilityIdentifier("connect-gmail-button")

            if let accountError {
                StatusMessage(kind: .error, text: accountError)
            }
        }
        .accessibilityIdentifier("email-not-configured")
    }

    /// The live mail browser.
    ///
    /// macOS uses a two-column `NavigationSplitView` (mailbox sidebar + a detail
    /// that puts the message list beside the reading pane via `HSplitView`).
    ///
    /// iPadOS (regular width) uses the same mailbox sidebar in a
    /// `NavigationSplitView`, with the message list as the detail pushing the
    /// reading pane. This works because the app's root on iPad is a tab bar, not
    /// a split view, so nothing collapses the mailbox column.
    ///
    /// iPhone (compact width) keeps a single stack level: the message list swaps
    /// with the reading pane in place, with a toolbar menu to switch mailboxes.
    @ViewBuilder
    private var mailBrowser: some View {
        #if os(macOS)
        NavigationSplitView {
            mailboxColumn
        } detail: {
            HSplitView {
                messageListPane
                    .frame(minWidth: 260, idealWidth: 320, maxWidth: 460, maxHeight: .infinity)
                messageDetailPane
                    .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .removeNestedSidebarToggle()
        .workspaceNavigationSplit()
        .accessibilityIdentifier("email-browser")
        // Switching mailboxes clears the current message and loads the new list.
        .onChange(of: selectedMailboxID) { _, _ in
            switchMailbox()
        }
        #else
        if usesPhoneStackNavigation {
            compactPhoneMailBrowser
        } else {
            // iPad: mailboxes live in a persistent leading column (like Mail),
            // not a flattened toolbar menu.
            NavigationSplitView {
                mailboxColumn
            } detail: {
                NavigationStack {
                    messageListPane
                }
            }
            .workspaceNavigationSplit()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("email-browser")
            .onChange(of: selectedMailboxID) { _, _ in
                switchMailbox()
            }
        }
        #endif
    }

    #if os(iOS)
    /// iPhone uses one stack level from the tab shell; list/detail swap in place.
    private var usesPhoneStackNavigation: Bool {
        horizontalSizeClass == .compact
    }

    private var phoneSelectedMessageID: Int64? {
        usesPhoneStackNavigation && !phoneBrowsingMessageList ? selectedMessageID : nil
    }

    private var compactPhoneMailBrowser: some View {
        Group {
            if let messageID = phoneSelectedMessageID {
                messageDetailPane
                    .navigationTitle("Message")
                    .navigationBarTitleDisplayMode(.inline)
                    .task(id: messageID) {
                        selectedMessageID = messageID
                        await loadDetail(messageRowID: messageID)
                    }
            } else {
                messageListPane
                    .toolbar { mailboxMenuToolbar }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar { phoneMessageToolbar }
        .accessibilityIdentifier("email-browser")
        .onChange(of: selectedMailboxID) { _, _ in
            switchMailbox()
        }
    }

    @ToolbarContentBuilder
    private var phoneMessageToolbar: some ToolbarContent {
        if phoneSelectedMessageID != nil {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    phoneBrowsingMessageList = true
                    selectedMessageID = nil
                    messageDetail = nil
                    loadError = nil
                } label: {
                    Label("Inbox", systemImage: "chevron.left")
                }
            }
        }
    }
    #endif

    /// On mailbox change: clear the reading pane, show cached messages instantly,
    /// then refresh the new mailbox in the background.
    private func switchMailbox() {
        selectedMessageID = nil
        messageDetail = nil
        loadError = nil
        #if os(iOS)
        phoneBrowsingMessageList = true
        #endif
        if let unified = mailReader as? UnifiedMailReaderService {
            messages = unified.cachedMessages(forMailboxID: selectedMailboxID)
            ensureMessageSelection()
        }
        Task { await refreshSelectedMessages() }
    }

    #if !os(macOS)
    /// iPhone (compact) mailbox switcher: a toolbar menu listing the unified inbox
    /// and each account's mailboxes. iPad and macOS show `mailboxColumn` instead.
    @ToolbarContentBuilder
    private var mailboxMenuToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                if mailboxes.contains(where: { $0.id == UnifiedMailReaderService.unifiedInboxID }) {
                    Button {
                        selectedMailboxID = UnifiedMailReaderService.unifiedInboxID
                    } label: {
                        Label("All Inboxes", systemImage: "tray.2")
                    }
                }
                ForEach(accountLabelsInOrder, id: \.self) { label in
                    Section(label) {
                        ForEach(mailboxes.filter { $0.accountLabel == label && $0.id != UnifiedMailReaderService.unifiedInboxID }) { mailbox in
                            // Full path conveys nesting in a flat menu (Work › Projects › Alpha).
                            Button(fullPathTitle(mailbox)) {
                                selectedMailboxID = mailbox.id
                            }
                        }
                    }
                }
            } label: {
                Label("Mailbox: \(selectedMailboxTitle)", systemImage: "tray.full")
            }
            .accessibilityIdentifier("mailbox-menu")
        }
    }
    #endif

    /// Leading column: the unified inbox plus per-account mailbox sections, with
    /// nested labels/folders shown as a real tree.
    private var mailboxColumn: some View {
        List(selection: $selectedMailboxID) {
            // Synthetic "All Inboxes" entry merging every account.
            if let unified = mailboxes.first(where: { $0.id == UnifiedMailReaderService.unifiedInboxID }) {
                Label("All Inboxes", systemImage: "tray.2")
                    .tag(unified.id)
            }
            // Per-account sections; each renders its mailbox hierarchy.
            ForEach(accountLabelsInOrder, id: \.self) { label in
                Section(label) {
                    OutlineGroup(mailboxTree(for: label), children: \.children) { node in
                        mailboxTreeRow(node)
                    }
                }
            }
        }
        .navigationTitle("Mailboxes")
        .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 300)
        .refreshable { await pullToRefresh() }
        .safeAreaInset(edge: .bottom) { updatingBar }
    }

    /// A single row in the mailbox tree. Real mailboxes are selectable; pure
    /// grouping nodes (a parent path with no own label) are shown as plain folders.
    @ViewBuilder
    private func mailboxTreeRow(_ node: MailboxTreeNode) -> some View {
        if let mailbox = node.mailbox {
            HStack {
                Label(node.title, systemImage: mailboxIcon(for: node))
                Spacer()
                if mailbox.unreadCount > 0 {
                    Text("\(mailbox.unreadCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .tag(mailbox.id)
        } else {
            Label(node.title, systemImage: "folder")
                .foregroundStyle(.secondary)
        }
    }

    /// A small "Updating…" strip shown while a background refresh is running.
    @ViewBuilder
    private var updatingBar: some View {
        if isUpdating {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Updating…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }

    /// Picks an SF Symbol for well-known system folders, else a generic icon
    /// (folder when the node has children, tag for a leaf label).
    private func mailboxIcon(for node: MailboxTreeNode) -> String {
        switch node.title.lowercased() {
        case "inbox": return "tray"
        case "starred": return "star"
        case "sent": return "paperplane"
        case "drafts": return "doc"
        case "spam", "junk": return "xmark.bin"
        case "trash": return "trash"
        default: return (node.children?.isEmpty == false) ? "folder" : "tag"
        }
    }

    /// Full hierarchical title for a mailbox (e.g. "Work › Projects › Alpha"),
    /// used in the flat iOS mailbox menu to convey nesting.
    private func fullPathTitle(_ mailbox: MailMailbox) -> String {
        let path = mailbox.displayPath ?? [mailbox.displayName]
        return path.joined(separator: " › ")
    }

    /// Builds the nested mailbox tree for one account from each mailbox's
    /// `displayPath`, creating intermediate grouping nodes where a parent label
    /// has no mailbox of its own.
    private func mailboxTree(for accountLabel: String) -> [MailboxTreeNode] {
        let boxes = mailboxes.filter {
            $0.accountLabel == accountLabel && $0.id != UnifiedMailReaderService.unifiedInboxID
        }
        return MailboxTreeNode.build(from: boxes, keyPrefix: accountLabel)
    }

    /// Distinct account labels in first-seen order (for stable section ordering).
    private var accountLabelsInOrder: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for mailbox in mailboxes where mailbox.id != UnifiedMailReaderService.unifiedInboxID {
            guard let label = mailbox.accountLabel, !seen.contains(label) else { continue }
            seen.insert(label)
            ordered.append(label)
        }
        return ordered
    }

    /// The selected mailbox's messages as a list.
    ///
    /// macOS uses `List(selection:)` so the reading pane (beside it in an
    /// `HSplitView`) tracks the highlighted row. iOS/iPadOS uses value-based
    /// `NavigationLink`s that push the reading pane, which is the reliable way to
    /// drive navigation from a list inside a `NavigationStack`.
    @ViewBuilder
    private var messageListPane: some View {
        #if os(macOS)
        List(selection: $selectedMessageID) {
            ForEach(messages) { message in
                messageRow(message)
                    .tag(message.id)
                    .accessibilityIdentifier("email-message-\(message.id)")
            }
        }
        .overlay { messageListEmptyState }
        .safeAreaInset(edge: .top) { updatingBar }
        .refreshable { await pullToRefresh() }
        .navigationTitle(selectedMailboxTitle)
        .onChange(of: selectedMessageID) { _, newValue in
            guard let newValue, newValue != messageDetail?.summary.id else { return }
            loadError = nil
            Task { await loadDetail(messageRowID: newValue) }
        }
        .accessibilityIdentifier("email-message-list")
        #else
        List {
            ForEach(messages) { message in
                if usesPhoneStackNavigation {
                    Button {
                        selectedMessageID = message.id
                        phoneBrowsingMessageList = false
                    } label: {
                        messageRow(message)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("email-message-\(message.id)")
                } else {
                    NavigationLink(value: message.id) {
                        messageRow(message)
                    }
                    .accessibilityIdentifier("email-message-\(message.id)")
                }
            }
        }
        .overlay { messageListEmptyState }
        .safeAreaInset(edge: .top) { updatingBar }
        .refreshable { await pullToRefresh() }
        .navigationTitle(selectedMailboxTitle)
        .navigationDestination(for: Int64.self) { id in
            messageDetailPane
                .task(id: id) {
                    selectedMessageID = id
                    await loadDetail(messageRowID: id)
                }
        }
        .accessibilityIdentifier("email-message-list")
        #endif
    }

    /// Empty-list overlay: a spinner while the first fetch runs, else an empty inbox.
    @ViewBuilder
    private var messageListEmptyState: some View {
        if messages.isEmpty {
            if let loadError {
                ContentUnavailableView {
                    Label("Couldn't Load Mail", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(loadError)
                }
            } else if isUpdating {
                ProgressView("Updating…")
            } else {
                ContentUnavailableView(
                    "No Messages",
                    systemImage: "tray",
                    description: Text("This mailbox is empty.")
                )
            }
        }
    }

    /// Reading pane: the loaded message, a loading skeleton, an error, or a prompt.
    @ViewBuilder
    private var messageDetailPane: some View {
        if let messageDetail {
            MailMessageDetailView(
                detail: messageDetail,
                messageRowID: selectedMessageID
            )
            .workspaceFillDetailPane()
        } else if isLoadingDetail, let summary = selectedMessageSummary {
            VStack(alignment: .leading, spacing: 12) {
                ProgressView("Loading message…")
                Text(summary.subject)
                    .font(.title3.bold())
                if let snippet = summary.snippet {
                    Text(snippet)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding()
        } else if let loadError {
            ContentUnavailableView {
                Label("Could Not Load Message", systemImage: "exclamationmark.triangle")
            } description: {
                Text(loadError)
            }
        } else {
            ContentUnavailableView(
                "No Message Selected",
                systemImage: "envelope.open",
                description: Text("Select a message to read.")
            )
        }
    }

    /// A message list row: subject + flag, sender, an account badge, and a snippet.
    private func messageRow(_ message: MailMessageSummary) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if !message.isRead {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 8, height: 8)
                    .padding(.top, 6)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(message.subject)
                        .font(message.isRead ? .headline : .headline.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    if message.isFlagged {
                        Image(systemName: "flag.fill")
                            .foregroundStyle(.orange)
                    }
                }
                HStack(spacing: 6) {
                    Text(message.senderName ?? message.senderAddress)
                        .font(.subheadline)
                        .fontWeight(message.isRead ? .regular : .semibold)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    // Show which account a message belongs to in the merged inbox.
                    if showAccountBadges, let label = message.accountLabel {
                        Text(label)
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                            .lineLimit(1)
                    }
                }
                if let snippet = message.snippet {
                    Text(snippet)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("email-row-\(message.subject)")
        .accessibilityLabel(
            "\(message.isRead ? "Read" : "Unread") message, \(message.subject), \(message.senderName ?? message.senderAddress)"
        )
    }

    /// Show per-row account badges only when more than one account is connected.
    private var showAccountBadges: Bool {
        accountLabelsInOrder.count > 1 || selectedMailboxID == UnifiedMailReaderService.unifiedInboxID
    }

    /// Title for the message-list column based on the current selection.
    private var selectedMailboxTitle: String {
        if selectedMailboxID == UnifiedMailReaderService.unifiedInboxID { return "All Inboxes" }
        return mailboxes.first { $0.id == selectedMailboxID }?.displayName ?? "Inbox"
    }

    /// The summary for the currently selected message id, if present.
    private var selectedMessageSummary: MailMessageSummary? {
        guard let selectedMessageID else { return nil }
        return messages.first { $0.id == selectedMessageID }
    }

    // MARK: - Actions

    /// Re-resolves access, renders cached data instantly, then refreshes in the
    /// background so reopening the Email tab never blocks on the network.
    private func refresh() {
        guard let mailReader else {
            ConnectionDebug.log("EmailView", "refresh skipped: no reader")
            return
        }
        mailReader.refreshAccessStatus()
        applyAccessStatus(from: mailReader)
        loadError = nil
        ConnectionDebug.log(
            "EmailView",
            "refresh status=\(String(describing: accessStatus)) signedInGmail=\(hasSignedInGmail) accounts=\(accountStore.googleAccounts.count)"
        )

        guard hasSignedInGmail || accessStatus == .available else {
            ConnectionDebug.log("EmailView", "refresh stopped at account/permission gate")
            return
        }

        applyCachedMailIfNeeded()
        ConnectionDebug.log("EmailView", "cached render mailboxes=\(mailboxes.count) messages=\(messages.count)")
        Task { await updateFromNetwork() }
    }

    /// Pull-to-refresh / toolbar Refresh: re-resolve access first — a reconnect
    /// or token refresh may have just changed it — then fetch fresh mailboxes
    /// and messages, holding the spinner until the fetch completes.
    @MainActor
    private func pullToRefresh() async {
        guard let mailReader else { return }
        ConnectionDebug.log("EmailView", "manual refresh start")
        mailReader.refreshAccessStatus()
        applyAccessStatus(from: mailReader)
        loadError = nil
        applyCachedMailIfNeeded()
        await updateFromNetwork()
    }

    /// Rebuilds account readers (needed after Google sign-in) then fetches mail
    /// and publishes it into the browser so the inbox appears without a manual refresh.
    @MainActor
    private func reloadReaderAndDisplayMail() async {
        guard let mailReader else { return }
        ConnectionDebug.log(
            "EmailView",
            "reader reload start fingerprint=\(signedInGoogleAccountFingerprint) signedInGmail=\(hasSignedInGmail)"
        )
        if let unified = mailReader as? UnifiedMailReaderService {
            unified.reload()
            unified.refreshAccessStatus()
            ConnectionDebug.log(
                "EmailView",
                "reader reloaded children=\(unified.childCount) status=\(String(describing: unified.accessStatus))"
            )
        } else {
            mailReader.refreshAccessStatus()
        }
        applyAccessStatus(from: mailReader)
        selectedMailboxID = UnifiedMailReaderService.unifiedInboxID
        selectedMessageID = nil
        messageDetail = nil
        loadError = nil
        applyCachedMailIfNeeded()
        displayedAccountFingerprint = signedInGoogleAccountFingerprint
        await updateFromNetwork()
        displayedAccountFingerprint = signedInGoogleAccountFingerprint
        ConnectionDebug.log(
            "EmailView",
            "reader reload complete mailboxes=\(mailboxes.count) messages=\(messages.count) error=\(loadError ?? "none")"
        )
    }

    /// Prefer Gmail's signed-in state over Apple Mail Full Disk Access denial.
    private func applyAccessStatus(from mailReader: any MailReaderServiceProtocol) {
        if hasSignedInGmail {
            accessStatus = .available
        } else {
            accessStatus = mailReader.accessStatus
        }
    }

    private func applyCachedMailIfNeeded() {
        guard let unified = mailReader as? UnifiedMailReaderService else { return }
        mailboxes = unified.cachedMailboxes()
        ensureMailboxSelection()
        messages = unified.cachedMessages(forMailboxID: selectedMailboxID)
        ensureMessageSelection()
    }

    /// Refreshes mailboxes + the selected mailbox's messages off the main thread.
    @MainActor
    private func updateFromNetwork() async {
        guard hasSignedInGmail || accessStatus == .available else {
            ConnectionDebug.log("EmailView", "network refresh skipped status=\(String(describing: accessStatus))")
            return
        }
        ConnectionDebug.log("EmailView", "network refresh start")
        isUpdating = true
        defer { isUpdating = false }
        do {
            try await fetchMailboxes()
            try await fetchMessages()
            ConnectionDebug.log(
                "EmailView",
                "network refresh complete mailboxes=\(mailboxes.count) messages=\(messages.count)"
            )
        } catch {
            loadError = error.localizedDescription
            ConnectionDebug.log("EmailView", "network refresh failed error=\(error.localizedDescription)")
        }
    }

    /// Refreshes only the selected mailbox's messages (used when switching mailbox).
    @MainActor
    private func refreshSelectedMessages() async {
        guard hasSignedInGmail || accessStatus == .available else { return }
        isUpdating = true
        defer { isUpdating = false }
        do {
            try await fetchMessages()
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Fetches the mailbox list (off-main for the unified reader) and reconciles selection.
    @MainActor
    private func fetchMailboxes() async throws {
        guard let mailReader else { return }
        if let unified = mailReader as? UnifiedMailReaderService {
            mailboxes = try await unified.refreshMailboxes()
        } else {
            mailboxes = try mailReader.listMailboxes()
        }
        ensureMailboxSelection()
    }

    /// Fetches the selected mailbox's messages (off-main for the unified reader).
    @MainActor
    private func fetchMessages() async throws {
        guard let mailReader else { return }
        if let unified = mailReader as? UnifiedMailReaderService {
            messages = try await unified.refreshMessages(mailboxID: selectedMailboxID, limit: 100)
        } else {
            messages = try mailReader.listMessages(mailboxID: selectedMailboxID, limit: 100)
        }
        ensureMessageSelection()
    }

    /// Picks a default mailbox when none is selected or the selection vanished.
    private func ensureMailboxSelection() {
        if selectedMailboxID == nil || !mailboxes.contains(where: { $0.id == selectedMailboxID }) {
            selectedMailboxID = mailboxes.first?.id ?? UnifiedMailReaderService.unifiedInboxID
        }
    }

    /// Keeps a valid message selected (macOS reading pane) without clobbering a
    /// user's explicit choice when it's still present.
    private func ensureMessageSelection() {
        #if os(macOS)
        if selectedMessageID == nil, let first = messages.first {
            selectedMessageID = first.id
        } else if let selectedMessageID,
                  !messages.contains(where: { $0.id == selectedMessageID }),
                  let first = messages.first {
            self.selectedMessageID = first.id
        }
        #endif
    }

    /// Loads the full body/headers for a message into the reading pane (off-main).
    @MainActor
    private func loadDetail(messageRowID: Int64) async {
        guard let mailReader else { return }
        isLoadingDetail = true
        loadError = nil
        defer { isLoadingDetail = false }

        do {
            if let unified = mailReader as? UnifiedMailReaderService {
                messageDetail = try await unified.loadMessageDetailAsync(messageRowID: messageRowID)
            } else {
                messageDetail = try mailReader.loadMessageDetail(messageRowID: messageRowID)
            }
            markMessageReadLocally(messageRowID: messageRowID)
        } catch {
            loadError = error.localizedDescription
            messageDetail = nil
        }
    }

    /// Updates the in-memory message list so opened messages no longer appear unread.
    private func markMessageReadLocally(messageRowID: Int64) {
        messages = messages.map { message in
            guard message.id == messageRowID, !message.isRead else { return message }
            return MailMessageSummary(
                id: message.id,
                messageID: message.messageID,
                subject: message.subject,
                senderAddress: message.senderAddress,
                senderName: message.senderName,
                dateReceived: message.dateReceived,
                snippet: message.snippet,
                isRead: true,
                isFlagged: message.isFlagged,
                mailboxURL: message.mailboxURL,
                accountID: message.accountID,
                accountLabel: message.accountLabel
            )
        }
    }

    /// Runs interactive Gmail OAuth, persists tokens, then downloads mail and
    /// syncs Google Calendar.
    @MainActor
    private func addGoogleAccount() async {
        guard !isAddingAccount else { return }
        isAddingAccount = true
        accountError = nil
        defer { isAddingAccount = false }
        do {
            _ = try await GoogleWorkspaceConnector(
                accountStore: accountStore,
                mailReader: mailReader,
                calendarCache: repositories?.calendarEvents
            ).connect()
            selectedMailboxID = UnifiedMailReaderService.unifiedInboxID
            selectedMessageID = nil
            messageDetail = nil
            #if os(iOS)
            phoneBrowsingMessageList = true
            #endif
            await reloadReaderAndDisplayMail()
        } catch GoogleOAuthError.cancelled {
            // User dismissed the sheet; not an error worth surfacing.
        } catch {
            accountError = error.localizedDescription
        }
    }
}
