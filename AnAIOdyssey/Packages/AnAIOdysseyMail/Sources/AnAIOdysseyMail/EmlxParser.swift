// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation

/// The result of parsing an email: its headers plus optional plain-text and HTML bodies.
public struct ParsedEmail: Sendable, Equatable {
    public let headers: [String: String]
    public let bodyText: String?
    public let bodyHTML: String?

    public init(headers: [String: String], bodyText: String?, bodyHTML: String?) {
        self.headers = headers
        self.bodyText = bodyText
        self.bodyHTML = bodyHTML
    }
}

/// Minimal parser for Apple Mail `.emlx` files and the MIME messages they wrap.
///
/// An `.emlx` file is a plain-text byte-count line, followed by the raw RFC 822/MIME
/// message, followed by a binary plist of Mail metadata (which we ignore). This parser
/// extracts the headers and a best-effort plain-text/HTML body, handling both single-part
/// and `multipart/*` messages. It is intentionally lightweight rather than a full MIME
/// implementation.
public enum EmlxParser {
    /// Parses raw `.emlx` file bytes into a `ParsedEmail`.
    ///
    /// Reads the leading decimal byte-count header that delimits the MIME payload from
    /// the trailing metadata plist, slices out exactly that many bytes, and parses them.
    /// Throws `.emlxParseFailed` for any malformed structure.
    public static func parse(data: Data) throws -> ParsedEmail {
        // The first line is a decimal byte count; locate its terminating newline.
        guard let newlineIndex = data.firstIndex(of: 0x0A) else {
            throw MailReaderError.emlxParseFailed("Missing byte-count header line")
        }

        // Parse and validate that byte count.
        guard let countLine = String(data: data[..<newlineIndex], encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            let byteCount = Int(countLine),
            byteCount > 0 else {
            throw MailReaderError.emlxParseFailed("Invalid byte-count header")
        }

        // The MIME payload begins immediately after the byte-count newline.
        let mimeStart = data.index(after: newlineIndex)
        guard mimeStart <= data.endIndex else {
            throw MailReaderError.emlxParseFailed("Missing MIME payload")
        }

        // Take exactly `byteCount` bytes (clamped to the data end) as the MIME message,
        // deliberately excluding the trailing Apple metadata plist.
        let mimeEnd = data.index(mimeStart, offsetBy: byteCount, limitedBy: data.endIndex) ?? data.endIndex
        let mimeData = Data(data[mimeStart..<mimeEnd])
        return try parseMIME(mimeData)
    }

    /// Convenience that reads a `.emlx` file from disk and parses it.
    public static func parse(fileURL: URL) throws -> ParsedEmail {
        let data = try Data(contentsOf: fileURL)
        return try parse(data: data)
    }

    /// Parses a raw MIME message (headers + body) into a `ParsedEmail`.
    ///
    /// Splits on the first blank line to separate headers from body, then dispatches by
    /// content type: multipart messages have their text/plain and text/html parts
    /// extracted; otherwise the whole body is treated as text or HTML. Tries UTF-8 then
    /// ISO-Latin-1 so legacy encodings still decode.
    static func parseMIME(_ data: Data) throws -> ParsedEmail {
        // Decode bytes to text, tolerating non-UTF-8 legacy messages.
        guard let raw = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw MailReaderError.emlxParseFailed("Could not decode MIME payload")
        }

        // Normalize CRLF to LF, then split headers from body at the first blank line.
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        guard let separatorRange = normalized.range(of: "\n\n") else {
            throw MailReaderError.emlxParseFailed("Missing MIME header/body separator")
        }

        let headerBlock = String(normalized[..<separatorRange.lowerBound])
        let bodyBlock = String(normalized[separatorRange.upperBound...])
        let headers = parseHeaders(headerBlock)
        // Detect multipart either from the parsed header or a raw header scan as a fallback.
        let contentType = headerValue(named: "Content-Type", in: headers) ?? ""
        let isMultipart = contentType.lowercased().contains("multipart/")
            || headerBlock.lowercased().contains("content-type: multipart/")

        // Multipart: pull out the text/plain and text/html sub-parts by boundary.
        if isMultipart {
            let boundary = extractBoundary(from: contentType)
            return ParsedEmail(
                headers: headers,
                bodyText: extractMultipartPart(named: "text/plain", from: bodyBlock, boundary: boundary),
                bodyHTML: extractMultipartPart(named: "text/html", from: bodyBlock, boundary: boundary)
            )
        }

        // Single-part HTML message: the whole body is the HTML.
        if contentType.lowercased().contains("text/html") {
            return ParsedEmail(headers: headers, bodyText: nil, bodyHTML: bodyBlock.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // Default: treat the body as plain text.
        return ParsedEmail(
            headers: headers,
            bodyText: bodyBlock.trimmingCharacters(in: .whitespacesAndNewlines),
            bodyHTML: nil
        )
    }

    /// Case-insensitive lookup of a header value by name.
    private static func headerValue(named name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// Parses an RFC 822 header block into a name→value dictionary.
    ///
    /// Handles header folding: continuation lines (starting with space/tab) are appended
    /// to the value of the preceding header rather than treated as new headers.
    private static func parseHeaders(_ block: String) -> [String: String] {
        var headers: [String: String] = [:]
        var currentName: String?
        var currentValue = ""

        for line in block.components(separatedBy: "\n") {
            // Folded continuation line: append to the current header's value.
            if line.hasPrefix(" ") || line.hasPrefix("\t"), let currentName {
                currentValue += " " + line.trimmingCharacters(in: .whitespaces)
                headers[currentName] = currentValue
            } else if let separator = line.firstIndex(of: ":") {
                // New "Name: value" header; flush the previous one first.
                if let currentName {
                    headers[currentName] = currentValue
                }
                currentName = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
                currentValue = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            }
        }

        // Flush the final header accumulated in the loop.
        if let currentName {
            headers[currentName] = currentValue
        }

        return headers
    }

    /// Extracts the `boundary=...` token from a multipart `Content-Type` header.
    ///
    /// Strips surrounding quotes so the returned value can be used directly as the part
    /// delimiter. Returns `nil` if no boundary parameter is present.
    private static func extractBoundary(from contentType: String) -> String? {
        // Scan the `;`-separated parameters for the boundary declaration.
        for part in contentType.split(separator: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("boundary=") {
                return trimmed.dropFirst("boundary=".count).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
        return nil
    }

    /// Finds the first multipart section whose headers declare `mimeType` and returns its body.
    ///
    /// Splits the body on the `--boundary` delimiter and, for each non-terminating
    /// section, checks whether its header block mentions the requested type. Returns the
    /// section's decoded text, or `nil` if no boundary or matching part exists.
    private static func extractMultipartPart(named mimeType: String, from body: String, boundary: String?) -> String? {
        guard let boundary else { return nil }
        let normalized = body.replacingOccurrences(of: "\r\n", with: "\n")
        let delimiter = "--\(boundary)"
        // Each section is the text between two boundary delimiters.
        let sections = normalized.components(separatedBy: delimiter)
        for section in sections {
            let trimmed = section.trimmingCharacters(in: .whitespacesAndNewlines)
            // Skip empties and the closing "--" terminator.
            if trimmed.isEmpty || trimmed == "--" { continue }
            // Split this part's own headers from its body.
            guard let separatorRange = trimmed.range(of: "\n\n") else { continue }
            let headerBlock = String(trimmed[..<separatorRange.lowerBound]).lowercased()
            // Return the body of the first part declaring the desired content type.
            if headerBlock.contains(mimeType) {
                return String(trimmed[separatorRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }
}
