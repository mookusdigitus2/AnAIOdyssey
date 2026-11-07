// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import AnAIOdysseyAI
import AnAIOdysseyCore
import AnAIOdysseyMail

// Agent tools giving the AI read access to the user's email. They live here (in
// AnAIOdysseyUI) because this is the one module that depends on both AnAIOdysseyAI
// (the `AgentTool` protocol) and AnAIOdysseyMail (the reader + models). The app's
// composition root injects them into `AgentLoopService` via its `extraTools`.
//
// Access is privacy-gated: every tool checks `AIDataAccess.isEmailAllowed` and
// refuses (with a helpful message) until the user enables it in Settings.

/// Builds the email tool set and its catalog text for injection into the agent.
public enum EmailAgentTools {
    /// Returns the email tools plus the catalog description shown to the model.
    @MainActor
    public static func make(mailReader: any MailReaderServiceProtocol) -> (tools: [any AgentTool], descriptions: String) {
        let tools: [any AgentTool] = [
            ListEmailsTool(mailReader: mailReader),
            ReadEmailTool(mailReader: mailReader),
        ]
        let descriptions = """
        ## Email (requires the user to enable "Allow AI to access Email" in Settings)
        ```list_emails
        <max messages, default 15>
        ```
        List recent email messages across all connected accounts (most recent first),
        each with its id, sender, date, and read state.

        ```read_email
        <email-id>
        ```
        Read a single email's full content (subject, sender, recipients, body) by the
        id returned from list_emails.
        """
        return (tools, descriptions)
    }
}

/// Agent tool: lists recent email across all connected accounts (gated by Settings).
@MainActor
struct ListEmailsTool: AgentTool {
    let name = "list_emails"
    private let mailReader: any MailReaderServiceProtocol

    init(mailReader: any MailReaderServiceProtocol) {
        self.mailReader = mailReader
    }

    func execute(content: String, context: inout AgentContext) async throws -> String {
        guard AIDataAccess.isEmailAllowed else {
            return EmailAgentSupport.accessDisabledMessage
        }

        let requested = Int(content.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 15
        let limit = min(max(requested, 1), 50)
        let messages = try await fetchMessages(limit: limit)
        guard !messages.isEmpty else {
            return "No email messages found."
        }

        let lines = messages.prefix(limit).map { message -> String in
            let unread = message.isRead ? "" : "[unread] "
            let sender = message.senderName?.nonEmpty ?? message.senderAddress
            let date = message.dateReceived.map(EmailAgentSupport.formatDate) ?? "—"
            let account = message.accountLabel.map { " · \($0)" } ?? ""
            let subject = message.subject.nonEmpty ?? "(no subject)"
            return "- \(unread)\(subject) — \(sender) (id: \(message.id), \(date)\(account))"
        }
        return "Emails (\(messages.count)):\n" + lines.joined(separator: "\n")
    }

    /// Prefers the unified reader's async/off-main fetch; falls back to the sync API.
    private func fetchMessages(limit: Int) async throws -> [MailMessageSummary] {
        if let unified = mailReader as? UnifiedMailReaderService {
            return try await unified.refreshMessages(mailboxID: nil, limit: limit)
        }
        return try mailReader.listMessages(mailboxID: nil, limit: limit)
    }
}

/// Agent tool: reads a single email's full content by id (gated by Settings).
@MainActor
struct ReadEmailTool: AgentTool {
    let name = "read_email"
    private let mailReader: any MailReaderServiceProtocol

    init(mailReader: any MailReaderServiceProtocol) {
        self.mailReader = mailReader
    }

    func execute(content: String, context: inout AgentContext) async throws -> String {
        guard AIDataAccess.isEmailAllowed else {
            return EmailAgentSupport.accessDisabledMessage
        }

        guard let rowID = Int64(content.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return "Provide the numeric email id (from list_emails) to read."
        }

        let detail = try await loadDetail(rowID: rowID)
        let summary = detail.summary
        let sender = summary.senderName?.nonEmpty.map { "\($0) <\(summary.senderAddress)>" } ?? summary.senderAddress

        var output = """
        Subject: \(summary.subject.nonEmpty ?? "(no subject)")
        From: \(sender)
        """
        if let to = detail.to?.nonEmpty { output += "\nTo: \(to)" }
        if let cc = detail.cc?.nonEmpty { output += "\nCc: \(cc)" }
        if let date = summary.dateReceived { output += "\nDate: \(EmailAgentSupport.formatDate(date))" }

        let body = detail.bodyText?.nonEmpty
            ?? EmailAgentSupport.plainText(fromHTML: detail.bodyHTML)
            ?? summary.snippet?.nonEmpty
            ?? "(no content)"
        let (preview, truncated) = EmailAgentSupport.truncate(body)
        output += "\n\n" + preview
        if let notice = detail.loadNotice { output += "\n\n(\(notice))" }
        if truncated { output += "\n(Content truncated for display.)" }
        return output
    }

    /// Prefers the unified reader's async/off-main load; falls back to the sync API.
    private func loadDetail(rowID: Int64) async throws -> MailMessageDetail {
        if let unified = mailReader as? UnifiedMailReaderService {
            return try await unified.loadMessageDetailAsync(messageRowID: rowID)
        }
        return try mailReader.loadMessageDetail(messageRowID: rowID)
    }
}

/// Shared formatting/limits for the email tools.
private enum EmailAgentSupport {
    static let previewLimit = 4000

    static let accessDisabledMessage =
        "Email access is disabled. The user can enable \"Allow AI to access Email\" in Settings to grant access."

    static func formatDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    static func truncate(_ text: String) -> (String, Bool) {
        if text.count <= previewLimit { return (text, false) }
        return (String(text.prefix(previewLimit)), true)
    }

    /// Best-effort conversion of an HTML body to readable plain text: strips tags,
    /// decodes a few common entities, and collapses whitespace.
    static func plainText(fromHTML html: String?) -> String? {
        guard let html, !html.isEmpty else { return nil }
        var text = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'"]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

private extension String {
    /// Self when non-empty, else nil — for terse fallback chains.
    var nonEmpty: String? { isEmpty ? nil : self }
}
