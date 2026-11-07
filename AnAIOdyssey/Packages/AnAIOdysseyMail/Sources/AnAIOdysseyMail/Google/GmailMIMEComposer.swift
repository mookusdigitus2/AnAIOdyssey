// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation

/// Builds RFC 822 messages and reply/forward recipient lists for Gmail.
enum GmailMIMEComposer {
    struct ParsedAddress: Hashable {
        let display: String
        let email: String
    }

    /// Metadata needed to thread a reply or forward.
    struct ThreadContext: Sendable {
        let gmailMessageID: String
        let threadID: String
        let messageIDHeader: String?
        let from: String
        let to: String?
        let cc: String?
        let subject: String
        let date: Date?
        let bodyText: String?
    }

    /// Builds recipient/subject/body fields for the chosen compose mode.
    static func composeFields(
        mode: MailSendMode,
        userBody: String,
        context: ThreadContext?,
        selfAddresses: Set<String>
    ) -> (to: String, cc: String, subject: String, body: String, threadID: String?, inReplyTo: String?) {
        switch mode {
        case .new:
            return ("", "", "", userBody, nil, nil)
        case .reply, .replyAll:
            guard let context else {
                return ("", "", userBody, userBody, nil, nil)
            }
            let recipients = replyRecipients(
                mode: mode,
                originalFrom: context.from,
                originalTo: context.to,
                originalCc: context.cc,
                selfAddresses: selfAddresses
            )
            let subject = replySubject(context.subject)
            return (
                recipients.to,
                recipients.cc,
                subject,
                userBody,
                context.threadID,
                context.messageIDHeader
            )
        case .forward:
            guard let context else {
                return ("", "", userBody, userBody, nil, nil)
            }
            let subject = forwardSubject(context.subject)
            let body = forwardBody(userBody: userBody, context: context)
            return ("", "", subject, body, nil, nil)
        }
    }

    /// Encodes a plain-text message as RFC 822 bytes for Gmail's `raw` send field.
    static func buildRFC822(
        to: String,
        cc: String,
        subject: String,
        body: String,
        inReplyTo: String?,
        references: String?
    ) -> String {
        var lines: [String] = []
        if !to.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("To: \(to)")
        }
        if !cc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("Cc: \(cc)")
        }
        lines.append("Subject: \(foldHeader(subject))")
        if let inReplyTo, !inReplyTo.isEmpty {
            lines.append("In-Reply-To: \(inReplyTo)")
        }
        if let references, !references.isEmpty {
            lines.append("References: \(references)")
        }
        lines.append("MIME-Version: 1.0")
        lines.append("Content-Type: text/plain; charset=UTF-8")
        lines.append("Content-Transfer-Encoding: 8bit")
        lines.append("")
        lines.append(body)
        return lines.joined(separator: "\r\n")
    }

    private static func replyRecipients(
        mode: MailSendMode,
        originalFrom: String,
        originalTo: String?,
        originalCc: String?,
        selfAddresses: Set<String>
    ) -> (to: String, cc: String) {
        let fromAddress = parseAddressList(originalFrom).first?.display ?? originalFrom
        guard mode == .replyAll else {
            return (fromAddress, "")
        }

        var ccSet: [String] = []
        var seen = Set<String>()
        let selfLower = Set(selfAddresses.map { $0.lowercased() })

        func add(_ raw: String?) {
            for parsed in parseAddressList(raw ?? "") {
                let key = parsed.email.lowercased()
                guard !key.isEmpty, !seen.contains(key), !selfLower.contains(key) else { continue }
                if parsed.display.lowercased() == fromAddress.lowercased() { continue }
                seen.insert(key)
                ccSet.append(parsed.display)
            }
        }

        add(originalTo)
        add(originalCc)
        return (fromAddress, ccSet.joined(separator: ", "))
    }

    static func parseAddressList(_ raw: String) -> [ParsedAddress] {
        raw.split(separator: ",").map { part in
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if let open = trimmed.firstIndex(of: "<"), let close = trimmed.firstIndex(of: ">"), open < close {
                let name = trimmed[..<open].trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                let email = String(trimmed[trimmed.index(after: open)..<close])
                let display = name.isEmpty ? email : "\(name) <\(email)>"
                return ParsedAddress(display: display, email: email)
            }
            return ParsedAddress(display: trimmed, email: trimmed)
        }
    }

    private static func replySubject(_ subject: String) -> String {
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("re:") { return trimmed }
        return "Re: \(trimmed)"
    }

    private static func forwardSubject(_ subject: String) -> String {
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("fwd:") || trimmed.lowercased().hasPrefix("fw:") { return trimmed }
        return "Fwd: \(trimmed)"
    }

    private static func forwardBody(userBody: String, context: ThreadContext) -> String {
        var lines: [String] = []
        if !userBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append(userBody)
            lines.append("")
        }
        lines.append("---------- Forwarded message ----------")
        lines.append("From: \(context.from)")
        if let date = context.date {
            lines.append("Date: \(date.formatted(date: .complete, time: .complete))")
        }
        lines.append("Subject: \(context.subject)")
        if let to = context.to { lines.append("To: \(to)") }
        if let cc = context.cc, !cc.isEmpty { lines.append("Cc: \(cc)") }
        lines.append("")
        lines.append(context.bodyText ?? "")
        return lines.joined(separator: "\n")
    }

    /// Folds long header values onto continuation lines per RFC 5322.
    private static func foldHeader(_ value: String) -> String {
        value.replacingOccurrences(of: "\n", with: " ")
    }
}

public enum MailSendMode: String, Sendable, CaseIterable {
    case new
    case reply
    case replyAll = "reply_all"
    case forward

    public var displayName: String {
        switch self {
        case .new: return "New Message"
        case .reply: return "Reply"
        case .replyAll: return "Reply All"
        case .forward: return "Forward"
        }
    }
}

extension Data {
    /// Gmail API `raw` field encoding (base64url without padding).
    func gmailBase64URL() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
