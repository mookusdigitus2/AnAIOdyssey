// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import AnAIOdysseyCore
import AnAIOdysseyMail
import SwiftUI

/// Compose sheet for reply, reply-all, forward, or sending a saved draft.
struct EmailComposeView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.mailSendService) private var mailSendService

    @State private var toRecipients: String
    @State private var ccRecipients: String
    @State private var subject: String
    @State private var bodyText: String
    @State private var isSending = false
    @State private var errorMessage: String?
    @State private var didSend = false

    let mode: MailSendMode
    let accountID: String
    let originalGmailMessageID: String?
    let onSent: (() -> Void)?

    init(
        mode: MailSendMode,
        accountID: String,
        toRecipients: String = "",
        ccRecipients: String = "",
        subject: String = "",
        body: String = "",
        originalGmailMessageID: String? = nil,
        onSent: (() -> Void)? = nil
    ) {
        self.mode = mode
        self.accountID = accountID
        _toRecipients = State(initialValue: toRecipients)
        _ccRecipients = State(initialValue: ccRecipients)
        _subject = State(initialValue: subject)
        _bodyText = State(initialValue: body)
        self.originalGmailMessageID = originalGmailMessageID
        self.onSent = onSent
    }

    init(outgoing: OutgoingEmail, onSent: (() -> Void)? = nil) {
        self.init(
            mode: outgoing.mode,
            accountID: outgoing.accountID,
            toRecipients: outgoing.to,
            ccRecipients: outgoing.cc,
            subject: outgoing.subject,
            body: outgoing.body,
            originalGmailMessageID: outgoing.originalGmailMessageID,
            onSent: onSent
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Type", value: mode.displayName)
                }

                Section("Recipients") {
                    TextField("To", text: $toRecipients)
                        .workspaceSettingsField()
                    TextField("Cc", text: $ccRecipients)
                        .workspaceSettingsField()
                }

                Section("Subject") {
                    TextField("Subject", text: $subject)
                        .workspaceSettingsField()
                }

                Section("Message") {
                    TextEditor(text: $bodyText)
                        .frame(minHeight: 220)
                        .accessibilityIdentifier("email-compose-body")
                }

                if let errorMessage {
                    Section {
                        StatusMessage(kind: .error, text: errorMessage)
                    }
                }
            }
            .workspaceSettingsForm()
            .navigationTitle(mode.displayName)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await send() }
                    } label: {
                        if isSending {
                            ProgressView()
                        } else {
                            Text("Send")
                        }
                    }
                    .disabled(isSending || mailSendService == nil)
                    .accessibilityIdentifier("email-send-button")
                }
            }
            .overlay {
                if didSend {
                    ContentUnavailableView {
                        Label("Sent", systemImage: "checkmark.circle.fill")
                    } description: {
                        Text("Your message was sent.")
                    }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 480)
    }

    @MainActor
    private func send() async {
        guard let mailSendService else {
            errorMessage = "Mail send service is not configured."
            return
        }
        isSending = true
        errorMessage = nil
        defer { isSending = false }

        let outgoing = OutgoingEmail(
            accountID: accountID,
            to: toRecipients,
            cc: ccRecipients,
            subject: subject,
            body: bodyText,
            mode: mode,
            originalGmailMessageID: originalGmailMessageID
        )

        do {
            try await mailSendService.send(outgoing)
            didSend = true
            onSent?()
            try? await Task.sleep(for: .milliseconds(900))
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

extension EmailDraftMode {
    var mailSendMode: MailSendMode {
        switch self {
        case .new: return .new
        case .reply: return .reply
        case .replyAll: return .replyAll
        case .forward: return .forward
        }
    }
}
