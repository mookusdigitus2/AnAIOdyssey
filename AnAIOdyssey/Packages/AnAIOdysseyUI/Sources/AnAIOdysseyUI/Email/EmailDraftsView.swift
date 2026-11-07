// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import AnAIOdysseyCore
import AnAIOdysseyMail
import SwiftUI

/// Reviews, edits, and sends email drafts composed by the assistant or the user.
struct EmailDraftsView: View {
    let repositories: RepositoryBundle

    @Environment(\.dismiss) private var dismiss
    @Environment(\.mailSendService) private var mailSendService
    @State private var drafts: [EmailDraft] = []
    @State private var loadError: String?
    @State private var composeOutgoing: OutgoingEmail?
    @State private var sendingDraftID: String?

    var body: some View {
        NavigationStack {
            Group {
                if drafts.isEmpty {
                    ContentUnavailableView {
                        Label("No Drafts", systemImage: "square.and.pencil")
                    } description: {
                        Text("Drafts you or the assistant compose appear here. Review and send via Gmail.")
                    }
                } else {
                    List {
                        ForEach(drafts, id: \.id) { draft in
                            NavigationLink {
                                EmailDraftEditor(draft: draft, repositories: repositories) {
                                    delete(draft)
                                } onSend: {
                                    prepareSend(for: draft)
                                }
                            } label: {
                                draftRow(draft)
                            }
                        }
                        .onDelete(perform: deleteAt)
                    }
                }
            }
            .navigationTitle("Drafts")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear(perform: reload)
            .overlay(alignment: .bottom) {
                if let loadError {
                    StatusMessage(kind: .error, text: loadError).padding()
                }
            }
            .sheet(isPresented: Binding(
                get: { composeOutgoing != nil },
                set: { if !$0 { composeOutgoing = nil } }
            )) {
                if let composeOutgoing {
                    EmailComposeView(outgoing: composeOutgoing) {
                        if let id = sendingDraftID {
                            try? repositories.emailDrafts.deleteDraft(id: id)
                            sendingDraftID = nil
                            reload()
                        }
                    }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 360)
    }

    private func draftRow(_ draft: EmailDraft) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(EmailDraftMode(rawValue: draft.mode)?.displayName ?? "Draft")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.tint.opacity(0.15), in: Capsule())
                    .foregroundStyle(.tint)
                Text(draft.subject.isEmpty ? "(no subject)" : draft.subject)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text(draft.updatedAt, format: .relative(presentation: .named))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text(draft.toRecipients.isEmpty ? "No recipients" : "To: \(draft.toRecipients)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    private func reload() {
        do {
            drafts = try repositories.emailDrafts.listDrafts()
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func deleteAt(_ offsets: IndexSet) {
        for index in offsets {
            delete(drafts[index])
        }
    }

    private func delete(_ draft: EmailDraft) {
        try? repositories.emailDrafts.deleteDraft(id: draft.id)
        reload()
    }

    private func prepareSend(for draft: EmailDraft) {
        draft.updatedAt = .now
        try? repositories.emailDrafts.save()
        guard let accountID = draft.accountID, !accountID.isEmpty else {
            loadError = "This draft has no Gmail account. Open the original message and reply from there."
            return
        }
        sendingDraftID = draft.id
        let mode = EmailDraftMode(rawValue: draft.mode)?.mailSendMode ?? .new
        composeOutgoing = OutgoingEmail(
            accountID: accountID,
            to: draft.toRecipients,
            cc: draft.ccRecipients,
            subject: draft.subject,
            body: draft.body,
            mode: mode,
            originalGmailMessageID: draft.originalMessageID
        )
    }
}

/// Editable detail for a single draft, with send and delete.
private struct EmailDraftEditor: View {
    @Bindable var draft: EmailDraft
    let repositories: RepositoryBundle
    let onDelete: () -> Void
    let onSend: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                LabeledContent("Type", value: EmailDraftMode(rawValue: draft.mode)?.displayName ?? "Draft")
                if let original = draft.originalSubject, !original.isEmpty {
                    LabeledContent("In reply to", value: original)
                }
            }

            Section("Recipients") {
                TextField("To", text: $draft.toRecipients)
                    .workspaceSettingsField()
                TextField("Cc", text: $draft.ccRecipients)
                    .workspaceSettingsField()
            }

            Section("Subject") {
                TextField("Subject", text: $draft.subject)
                    .workspaceSettingsField()
            }

            Section("Body") {
                TextEditor(text: $draft.body)
                    .frame(minHeight: 200)
                    .accessibilityIdentifier("email-draft-body")
            }

            Section {
                Button {
                    onSend()
                } label: {
                    Label("Review & Send", systemImage: "paperplane.fill")
                }
                .accessibilityIdentifier("send-draft-button")

                Button(role: .destructive) {
                    onDelete()
                    dismiss()
                } label: {
                    Label("Delete Draft", systemImage: "trash")
                }
            } footer: {
                Text("Send uses your connected Gmail account.")
            }
        }
        .workspaceSettingsForm()
        .navigationTitle("Edit Draft")
        .onDisappear {
            draft.updatedAt = .now
            try? repositories.emailDrafts.save()
        }
    }
}
