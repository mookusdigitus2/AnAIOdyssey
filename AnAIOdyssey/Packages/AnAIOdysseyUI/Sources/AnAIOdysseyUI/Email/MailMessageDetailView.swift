// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import AnAIOdysseyAI
import AnAIOdysseyMail
import SwiftUI

/// Reading pane for a single message with AI assists and send actions.
struct MailMessageDetailView: View {
    @Environment(\.llmService) private var llmService
    @Environment(\.mailReader) private var mailReader
    @Environment(\.mailSendService) private var mailSendService
    @EnvironmentObject private var providerSettings: ProviderSettings
    @EnvironmentObject private var agentRegistrySettings: AgentRegistrySettings
    @EnvironmentObject private var featureModelSettings: FeatureModelSettings

    let detail: MailMessageDetail
    let messageRowID: Int64?

    @State private var summary: String?
    @State private var replyDraft = ""
    @State private var isSummarizing = false
    @State private var isDraftingReply = false
    @State private var aiError: String?
    @State private var composeOutgoing: OutgoingEmail?
    @State private var isPreparingCompose = false
    @State private var modelSelectionKey = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    Task { await summarizeEmail() }
                } label: {
                    Label(isSummarizing ? "Summarizing..." : "Summarize", systemImage: "text.alignleft")
                }
                .disabled(isSummarizing || isDraftingReply || llmService == nil)

                Button {
                    Task { await draftReply() }
                } label: {
                    Label(isDraftingReply ? "Drafting..." : "Draft Reply", systemImage: "sparkles")
                }
                .disabled(isSummarizing || isDraftingReply || llmService == nil)

                Button {
                    Task { await openCompose(mode: .reply, body: replyDraft) }
                } label: {
                    Label("Reply", systemImage: "arrowshape.turn.up.left")
                }
                .disabled(isPreparingCompose || !canSend)

                Button {
                    Task { await openCompose(mode: .replyAll, body: replyDraft) }
                } label: {
                    Label("Reply All", systemImage: "arrowshape.turn.up.left.2")
                }
                .disabled(isPreparingCompose || !canSend)

                Button {
                    Task { await openCompose(mode: .forward, body: replyDraft) }
                } label: {
                    Label("Forward", systemImage: "arrowshape.turn.up.right")
                }
                .disabled(isPreparingCompose || !canSend)

                Spacer()
            }
            .padding(.horizontal)
            .padding(.top, 12)
            .accessibilityIdentifier("summarize-email-button")

            if let aiError {
                StatusMessage(kind: .error, text: aiError)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.top, 8)
            }

            if let loadNotice = detail.loadNotice {
                Text(loadNotice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.top, 8)
            }

            if let summary {
                WorkspacePanel {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Summary")
                            .font(AnAIOdysseyFont.listTitle)
                        PlainMessageContentView(content: summary)
                    }
                }
                .padding()
                .accessibilityIdentifier("email-summary-panel")
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(detail.summary.subject)
                        .font(AnAIOdysseyFont.detailTitle)

                    LabeledContent("From", value: detail.summary.senderName ?? detail.summary.senderAddress)
                    if let to = detail.to {
                        LabeledContent("To", value: to)
                    }
                    if let cc = detail.cc, !cc.isEmpty {
                        LabeledContent("Cc", value: cc)
                    }
                    if let date = detail.summary.dateReceived {
                        LabeledContent("Date", value: date.formatted(date: .abbreviated, time: .shortened))
                    }

                    Divider()

                    if let bodyHTML = detail.bodyHTML, !bodyHTML.isEmpty {
                        // Render rich HTML in a WebKit view (self-sizing) instead of
                        // dumping the raw markup as plain text.
                        HTMLEmailView(html: bodyHTML)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("email-body-html")
                    } else if let bodyText = detail.bodyText, !bodyText.isEmpty {
                        Text(bodyText)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("email-body-text")
                    } else if let snippet = detail.summary.snippet, !snippet.isEmpty {
                        Text(snippet)
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("email-body-snippet")
                    } else {
                        Text("No message body available.")
                            .foregroundStyle(.secondary)
                    }

                    if !replyDraft.isEmpty {
                        Divider()
                        HStack {
                            Text("Reply Draft")
                                .font(.headline)
                            Spacer()
                            Button {
                                Task { await openCompose(mode: .reply, body: replyDraft) }
                            } label: {
                                Label("Send", systemImage: "paperplane.fill")
                            }
                            .disabled(isPreparingCompose || !canSend)
                        }
                        TextEditor(text: $replyDraft)
                            .frame(minHeight: 140)
                            .accessibilityIdentifier("email-reply-draft")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .workspaceEdgeToEdgeScrollContent()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Message")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                WorkspaceModelPicker(
                    label: "Model",
                    selectionKey: $modelSelectionKey,
                    providerSettings: providerSettings,
                    accessibilityIdentifier: "email-model-picker",
                    pickerScope: .chatRecent
                )
            }
            ToolbarItem(placement: .automatic) {
                WorkspaceModelOptionsButton(
                    selectionKey: modelSelectionKey,
                    accessibilityIdentifier: "email-model-options"
                )
            }
        }
        .onAppear(perform: applyEmailPickerDefault)
        .onChange(of: featureModelSettings.settingsRevision) { _, _ in
            applyEmailPickerDefault()
        }
        .accessibilityIdentifier("email-message-detail")
        .sheet(isPresented: Binding(
            get: { composeOutgoing != nil },
            set: { if !$0 { composeOutgoing = nil } }
        )) {
            if let composeOutgoing {
                EmailComposeView(outgoing: composeOutgoing)
            }
        }
    }

    private var canSend: Bool {
        mailSendService != nil && sendContext != nil
    }

    private var sendContext: (accountID: String, gmailMessageID: String)? {
        guard let messageRowID,
              let unified = mailReader as? UnifiedMailReaderService else { return nil }
        return unified.gmailSendContext(forGlobalMessageRowID: messageRowID)
            ?? detail.summary.accountID.flatMap { accountID in
                // Single-account Gmail reader (non-unified) fallback.
                guard let reader = mailReader as? GmailMailReaderService,
                      let gmailID = reader.gmailMessageID(for: messageRowID) else { return nil }
                return (accountID, gmailID)
            }
    }

    @MainActor
    private func openCompose(mode: MailSendMode, body: String) async {
        guard let mailSendService, let context = sendContext else {
            aiError = "Sending requires a Gmail account for this message."
            return
        }
        isPreparingCompose = true
        aiError = nil
        defer { isPreparingCompose = false }
        do {
            composeOutgoing = try await mailSendService.prepareCompose(
                mode: mode,
                accountID: context.accountID,
                originalGmailMessageID: context.gmailMessageID,
                body: body
            )
        } catch {
            aiError = error.localizedDescription
        }
    }

    /// Packs the message into the AI service's input shape.
    private var aiInput: EmailAIInput {
        EmailAIInput(
            sender: detail.summary.senderName ?? detail.summary.senderAddress,
            subject: detail.summary.subject,
            body: detail.bodyText ?? detail.bodyHTML ?? detail.summary.snippet ?? "",
            recipient: detail.summary.senderAddress
        )
    }

    private func applyEmailPickerDefault() {
        if modelSelectionKey.isEmpty {
            WorkspaceModelSelection.applyFeatureDefault(
                for: .email,
                selectionKey: &modelSelectionKey,
                featureModelSettings: featureModelSettings,
                providerSettings: providerSettings,
                agentSettings: agentRegistrySettings
            )
        }
    }

    @MainActor
    private func applyEmailModelDefault() async throws {
        guard let llmService else { return }
        applyEmailPickerDefault()
        WorkspaceModelSelection.apply(
            selectionKey: modelSelectionKey,
            to: llmService,
            providerSettings: providerSettings
        )
        try await llmService.loadSelectedModel()
    }

    @MainActor
    private func summarizeEmail() async {
        guard let llmService else { return }
        isSummarizing = true
        aiError = nil
        defer { isSummarizing = false }

        do {
            try await applyEmailModelDefault()
            let service = EmailAIService(llmService: llmService)
            summary = try await service.summarize(aiInput)
        } catch {
            aiError = error.localizedDescription
        }
    }

    @MainActor
    private func draftReply() async {
        guard let llmService else { return }
        isDraftingReply = true
        aiError = nil
        defer { isDraftingReply = false }

        do {
            try await applyEmailModelDefault()
            let service = EmailAIService(llmService: llmService)
            replyDraft = try await service.draftReply(aiInput)
        } catch {
            aiError = error.localizedDescription
        }
    }
}
