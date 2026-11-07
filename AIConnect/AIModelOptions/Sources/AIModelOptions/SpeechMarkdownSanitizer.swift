// SPDX-License-Identifier: MIT
import Foundation

/// Strips Markdown before text reaches any TTS provider (ElevenLabs, xAI,
/// OpenAI, system): read aloud, markup garbles speech ("asterisk asterisk").
///
/// `speakable` handles a whole reply (fenced code blocks may span lines).
/// `speakableLine` handles one streamed piece; `StreamingSpeechChunker`
/// tracks fence state across pieces, because every newline is a boundary.
public enum SpeechMarkdownSanitizer {
    /// Whole text: fenced code blocks are skipped entirely, every other line
    /// is cleaned. Nil when nothing speakable is left.
    public static func speakable(_ text: String) -> String? {
        var lines: [String] = []
        var inFence = false
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(raw)
            if isFenceLine(line) {
                inFence.toggle()
                continue
            }
            if inFence { continue }
            if let cleaned = speakableLine(line) { lines.append(cleaned) }
        }
        let joined = lines.joined(separator: "\n")
        return joined.isEmpty ? nil : joined
    }

    /// True for a ``` or ~~~ fence (opening, with optional language, or closing).
    public static func isFenceLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
    }

    /// One line (or a sentence piece of one). Line-start rules (headers,
    /// lists, quotes, rules, table separators) apply only when the piece
    /// starts a line.
    public static func speakableLine(_ line: String, atLineStart: Bool = true) -> String? {
        var text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if atLineStart {
            if matches(text, #"^([-*_])(\s*\1){2,}$"#) { return nil }              // horizontal rule
            if matches(text, #"^\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)*\|?$"#) { return nil } // table separator
            text = replace(text, #"^(>\s*)+"#, "")                                 // blockquote
            text = replace(text, #"^#{1,6}\s+"#, "")                               // header
            text = replace(text, #"\s+#+$"#, "")                                   // closing hashes
            text = replace(text, #"^([-*+]|\d{1,3}[.)])\s+"#, "")                  // list marker
        }

        text = replace(text, #"!\[([^\]]*)\]\([^)]*\)"#, "$1")                     // image -> alt
        text = replace(text, #"\[([^\]]+)\]\([^)]*\)"#, "$1")                      // link -> label
        text = replace(text, #"<(https?://|mailto:)[^>]*>"#, "")                   // autolink
        text = replace(text, #"(https?://|www\.)[^\s)\]]*[^\s)\].,;:!?]"#, "")    // bare URL
        text = replace(text, #"`+([^`]*)`+"#, "$1")                                // inline code
        text = text.replacingOccurrences(of: "`", with: "")
        text = text.replacingOccurrences(of: "~~", with: "")                       // strikethrough
        text = text.replacingOccurrences(of: "*", with: "")                        // emphasis
        text = replace(text, #"(?<![A-Za-z0-9])_+|_+(?![A-Za-z0-9])"#, "")         // _em_ / __strong__, not snake_case

        if text.contains("|") {                                                    // table row
            let cells = text.split(separator: "|")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            text = cells.joined(separator: ", ")
        }

        text = replace(text, #"\s{2,}"#, " ")
        text = replace(text, #"\s+([.,;:!?])"#, "$1")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        return text
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func replace(_ text: String, _ pattern: String, _ template: String) -> String {
        text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
    }
}
