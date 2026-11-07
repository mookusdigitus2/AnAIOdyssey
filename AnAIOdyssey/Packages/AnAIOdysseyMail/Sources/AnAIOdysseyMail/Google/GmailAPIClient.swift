// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation

/// Errors shared across the Google REST clients (Gmail and Calendar).
public enum GoogleAPIError: Error, LocalizedError {
    case unauthorized
    case requestFailed(String)
    case invalidResponse

    /// Human-readable description for each failure case.
    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            "Google account is not signed in."
        case .requestFailed(let detail):
            detail
        case .invalidResponse:
            "Google API returned an unexpected response."
        }
    }

    /// Turns common Google project/configuration failures into an actionable message.
    static func requestFailure(status: Int, body: String) -> GoogleAPIError {
        if status == 403,
           body.localizedCaseInsensitiveContains("project #"),
           body.localizedCaseInsensitiveContains("has been deleted") {
            return .requestFailed(
                "The Google Cloud project for this OAuth Client ID has been deleted. "
                + "Create or select an active Google Cloud project, enable the Gmail and "
                + "Google Calendar APIs, enter its OAuth Client ID in Preferences, then sign in again."
            )
        }
        return .requestFailed("HTTP \(status): \(body.prefix(300))")
    }
}

/// A Gmail label (folder/category) with its message counts.
struct GmailLabel: Sendable {
    let id: String
    let name: String
    let type: String?
    let messagesTotal: Int
    let messagesUnread: Int
}

/// List-friendly metadata for a Gmail message; `labelIDs` encodes read/starred state.
struct GmailMessageSummary: Sendable {
    let id: String
    let threadID: String
    let subject: String
    let senderAddress: String
    let senderName: String?
    let dateReceived: Date?
    let snippet: String?
    let labelIDs: [String]
}

/// A fully fetched Gmail message: its summary plus decoded body and recipient headers.
struct GmailMessageDetailPayload: Sendable {
    let summary: GmailMessageSummary
    let bodyText: String?
    let bodyHTML: String?
    let to: String?
    let cc: String?
}

/// Async client for the Gmail REST API (labels, message lists, message details).
///
/// Each request is authorized with a fresh bearer token from `GoogleOAuthService`.
/// Listing messages requires a two-step fetch (id list, then per-message metadata) because
/// Gmail's list endpoint returns only message ids.
public final class GmailAPIClient {
    private let oauth: GoogleOAuthService
    private let session: URLSession

    public init(oauth: GoogleOAuthService, session: URLSession = .shared) {
        self.oauth = oauth
        self.session = session
    }

    /// Fetches all Gmail labels for the signed-in user.
    func listLabels() async throws -> [GmailLabel] {
        let object = try await requestJSON(path: "/gmail/v1/users/me/labels")
        guard let labels = object["labels"] as? [[String: Any]] else {
            ConnectionDebug.log("Gmail", "labels response contained no labels array")
            return []
        }
        let parsed = labels.compactMap(Self.parseLabel)
        ConnectionDebug.log("Gmail", "labels fetched raw=\(labels.count) parsed=\(parsed.count)")
        return parsed
    }

    /// Lists messages in a label, resolving each id into a metadata summary.
    ///
    /// Gmail's list endpoint returns only ids, so this fetches up to `limit` of them and
    /// then issues a per-message metadata request for each.
    func listMessages(labelID: String, limit: Int) async throws -> [GmailMessageSummary] {
        // Ask for the message id list within the label (bounded by maxResults).
        var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
        components.queryItems = [
            URLQueryItem(name: "labelIds", value: labelID),
            URLQueryItem(name: "maxResults", value: String(max(limit, 1))),
        ]
        let object = try await requestJSON(url: components.url!)
        guard let messages = object["messages"] as? [[String: Any]] else {
            ConnectionDebug.log("Gmail", "message list fetched label=\(labelID) count=0")
            return []
        }
        ConnectionDebug.log("Gmail", "message ids fetched label=\(labelID) count=\(messages.count) limit=\(limit)")

        // Hydrate each id into a full summary (sequentially, up to limit).
        var summaries: [GmailMessageSummary] = []
        for entry in messages.prefix(limit) {
            guard let id = entry["id"] as? String else { continue }
            summaries.append(try await fetchMessageSummary(id: id))
        }
        ConnectionDebug.log("Gmail", "message summaries fetched label=\(labelID) count=\(summaries.count)")
        return summaries
    }

    /// Fetches a message in `full` format and decodes its body and recipient headers.
    func fetchMessageDetail(id: String) async throws -> GmailMessageDetailPayload {
        // `format=full` returns the complete MIME payload tree with bodies.
        var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(id)")!
        components.queryItems = [URLQueryItem(name: "format", value: "full")]
        let object = try await requestJSON(url: components.url!)
        let summary = try Self.parseMessageSummary(object, fallbackID: id)
        // Walk the payload tree to extract text/html bodies and To/Cc headers.
        let payload = object["payload"] as? [String: Any]
        let decoded = Self.decodeBody(from: payload)
        return GmailMessageDetailPayload(
            summary: summary,
            bodyText: decoded.text,
            bodyHTML: decoded.html,
            to: Self.header(named: "To", in: payload),
            cc: Self.header(named: "Cc", in: payload)
        )
    }

    /// Threading metadata for reply / reply-all / forward compose.
    func fetchComposeContext(id: String) async throws -> GmailMIMEComposer.ThreadContext {
        var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(id)")!
        components.queryItems = [URLQueryItem(name: "format", value: "metadata")]
        components.queryItems?.append(URLQueryItem(name: "metadataHeaders", value: "From"))
        components.queryItems?.append(URLQueryItem(name: "metadataHeaders", value: "To"))
        components.queryItems?.append(URLQueryItem(name: "metadataHeaders", value: "Cc"))
        components.queryItems?.append(URLQueryItem(name: "metadataHeaders", value: "Subject"))
        components.queryItems?.append(URLQueryItem(name: "metadataHeaders", value: "Message-ID"))
        components.queryItems?.append(URLQueryItem(name: "metadataHeaders", value: "Date"))
        let object = try await requestJSON(url: components.url!)
        let payload = object["payload"] as? [String: Any]
        let from = Self.header(named: "From", in: payload) ?? ""
        let detail = try await fetchMessageDetail(id: id)
        let internalDate = (object["internalDate"] as? String).flatMap(Double.init).map {
            Date(timeIntervalSince1970: $0 / 1000)
        }
        return GmailMIMEComposer.ThreadContext(
            gmailMessageID: id,
            threadID: object["threadId"] as? String ?? id,
            messageIDHeader: Self.header(named: "Message-ID", in: payload),
            from: from,
            to: Self.header(named: "To", in: payload),
            cc: Self.header(named: "Cc", in: payload),
            subject: Self.header(named: "Subject", in: payload) ?? detail.summary.subject,
            date: internalDate ?? detail.summary.dateReceived,
            bodyText: detail.bodyText ?? detail.summary.snippet
        )
    }

    /// Sends a MIME message via Gmail API; returns the sent message id.
    @discardableResult
    func sendMessage(rawRFC822: String, threadID: String?) async throws -> String {
        var body: [String: Any] = [
            "raw": Data(rawRFC822.utf8).gmailBase64URL(),
        ]
        if let threadID, !threadID.isEmpty {
            body["threadId"] = threadID
        }
        let object = try await postJSON(
            url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/send")!,
            body: body
        )
        guard let id = object["id"] as? String else {
            throw GoogleAPIError.invalidResponse
        }
        return id
    }

    /// Fetches just the metadata (headers, snippet, labels) for a single message.
    private func fetchMessageSummary(id: String) async throws -> GmailMessageSummary {
        // `format=metadata` is lighter than full and sufficient for list rows.
        var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(id)")!
        components.queryItems = [URLQueryItem(name: "format", value: "metadata")]
        let object = try await requestJSON(url: components.url!)
        return try Self.parseMessageSummary(object, fallbackID: id)
    }

    /// Convenience overload that resolves a relative API path against the Gmail host.
    private func requestJSON(path: String) async throws -> [String: Any] {
        try await requestJSON(url: URL(string: "https://gmail.googleapis.com\(path)")!)
    }

    /// Performs an authenticated GET and decodes the JSON object body.
    ///
    /// Mirrors the Calendar client: attaches a bearer token, retries once with a
    /// force-refreshed token on 401, maps a repeated 401 to `.unauthorized`, other
    /// non-2xx to `.requestFailed`, and non-object bodies to `.invalidResponse`.
    private func requestJSON(url: URL) async throws -> [String: Any] {
        try await GoogleAuthorizedJSONRequest.perform(oauth: oauth, session: session) { token in
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            return request
        }
    }

    /// Performs an authenticated POST with a JSON object body (same 401 retry).
    private func postJSON(url: URL, body: [String: Any]) async throws -> [String: Any] {
        let payload = try JSONSerialization.data(withJSONObject: body)
        return try await GoogleAuthorizedJSONRequest.perform(oauth: oauth, session: session) { token in
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = payload
            return request
        }
    }

    /// Decodes a single label JSON object, defaulting counts to zero when absent.
    private static func parseLabel(_ object: [String: Any]) -> GmailLabel? {
        guard let id = object["id"] as? String,
              let name = object["name"] as? String else { return nil }
        return GmailLabel(
            id: id,
            name: name,
            type: object["type"] as? String,
            messagesTotal: object["messagesTotal"] as? Int ?? 0,
            messagesUnread: object["messagesUnread"] as? Int ?? 0
        )
    }

    /// Builds a `GmailMessageSummary` from a message JSON object's headers and metadata.
    ///
    /// Flattens the payload headers into a case-insensitive map, parses the `From` header
    /// into name/address, and converts Gmail's millisecond `internalDate` into a `Date`.
    private static func parseMessageSummary(_ object: [String: Any], fallbackID: String) throws -> GmailMessageSummary {
        let id = object["id"] as? String ?? fallbackID
        // Flatten payload headers into a lowercased name->value lookup. Messages can
        // legitimately repeat header names (e.g. multiple `Received`), so merge
        // duplicates (keeping the first) instead of trapping like
        // `Dictionary(uniqueKeysWithValues:)` would.
        let headers = (object["payload"] as? [String: Any])?["headers"] as? [[String: Any]] ?? []
        let headerMap = Dictionary(
            headers.compactMap { header -> (String, String)? in
                guard let name = header["name"] as? String,
                      let value = header["value"] as? String else { return nil }
                return (name.lowercased(), value)
            },
            uniquingKeysWith: { first, _ in first }
        )

        // Split the From header into display name and email address.
        let from = headerMap["from"] ?? ""
        let parsedFrom = parseAddress(from)
        // Gmail's internalDate is epoch milliseconds as a string; convert to seconds.
        let internalDate = (object["internalDate"] as? String).flatMap(Double.init).map {
            Date(timeIntervalSince1970: $0 / 1000)
        }

        return GmailMessageSummary(
            id: id,
            threadID: object["threadId"] as? String ?? id,
            subject: headerMap["subject"] ?? "(No subject)",
            senderAddress: parsedFrom.address,
            senderName: parsedFrom.name,
            dateReceived: internalDate,
            snippet: object["snippet"] as? String,
            labelIDs: object["labelIds"] as? [String] ?? []
        )
    }

    /// Splits an RFC 822 `From` value into an optional display name and an email address.
    ///
    /// Handles the `Name <email>` form (stripping quotes around the name); falls back to
    /// treating the whole string as a bare address when no angle brackets are present.
    private static func parseAddress(_ raw: String) -> (name: String?, address: String) {
        // "Display Name <addr@host>": extract the name and the bracketed address.
        if let open = raw.firstIndex(of: "<"), let close = raw.firstIndex(of: ">"), open < close {
            let name = raw[..<open].trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let address = String(raw[raw.index(after: open)..<close])
            return (name.nilIfEmpty, address)
        }
        // Otherwise treat the entire value as the address with no display name.
        return (nil, raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Case-insensitively looks up a single header value within a payload object.
    private static func header(named name: String, in payload: [String: Any]?) -> String? {
        let headers = payload?["headers"] as? [[String: Any]] ?? []
        return headers.first { ($0["name"] as? String)?.lowercased() == name.lowercased() }?["value"] as? String
    }

    /// Recursively walks the MIME payload tree, collecting the text/plain and text/html bodies.
    ///
    /// Gmail nests multipart messages as `parts`; this depth-first walk decodes each
    /// base64url-encoded leaf body and keeps the last text/plain and text/html it finds.
    private static func decodeBody(from payload: [String: Any]?) -> (text: String?, html: String?) {
        guard let payload else { return (nil, nil) }
        var text: String?
        var html: String?

        // Visit a single MIME node: decode its body if it's a text part we want.
        func walk(_ part: [String: Any]) {
            if let mimeType = part["mimeType"] as? String,
               let body = part["body"] as? [String: Any],
               let data = body["data"] as? String,
               let decoded = decodeBase64URL(data) {
                if mimeType == "text/plain" {
                    text = decoded
                } else if mimeType == "text/html" {
                    html = decoded
                }
            }
            // Recurse into any nested multipart sub-parts.
            if let parts = part["parts"] as? [[String: Any]] {
                parts.forEach(walk)
            }
        }

        walk(payload)
        return (text, html)
    }

    /// Decodes Gmail's base64url body encoding (URL-safe alphabet, padding optional) to a String.
    private static func decodeBase64URL(_ value: String) -> String? {
        // Translate the URL-safe alphabet back to standard base64.
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        // Restore the '=' padding that base64url omits.
        let padding = 4 - (base64.count % 4)
        if padding < 4 {
            base64 += String(repeating: "=", count: padding)
        }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

private extension String {
    /// Returns `nil` for an empty string, otherwise the string itself.
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
