// SPDX-License-Identifier: MIT
import Foundation

/// Turns a growing LLM transcript into speakable sentence segments for TTS.
///
/// The first chunk waits for a complete sentence (`.`, `!`, `?`, or newline)
/// so the voice has a full intonation contour. Later chunks use the same rule.
/// Abbreviations (`Dr.`, `U.S.`), decimals (`3.14`), and ellipses (`... then`)
/// are not treated as sentence ends. A very long run with no terminator flushes
/// at the last clause boundary; `finish` flushes any trailing remainder.
public struct StreamingSpeechChunker: Sendable {
    /// Soft cap before a terminator-less sentence is cut at a clause boundary.
    public var maxPendingCharacters: Int
    /// Prefix of the cumulative stream that has already been emitted (or skipped).
    public private(set) var committedPrefix = ""
    /// Inside a ``` / ~~~ fenced code block: pieces are skipped, not spoken.
    private var inCodeFence = false
    /// The next piece starts a line (every newline is a boundary).
    private var atLineStart = true

    public init(maxPendingCharacters: Int = StreamingSpeechChunker.defaultMaxPendingCharacters) {
        self.maxPendingCharacters = maxPendingCharacters
    }

    public static let defaultMaxPendingCharacters = 300

    public mutating func reset() {
        committedPrefix = ""
        inCodeFence = false
        atLineStart = true
    }

    /// Marks everything up to `text` as already spoken without emitting it.
    public mutating func markSpoken(cumulative text: String) {
        committedPrefix = text
    }

    /// Returns newly completed segments from `text` that have not been emitted yet.
    public mutating func consume(cumulative text: String) -> [String] {
        if !text.hasPrefix(committedPrefix) {
            committedPrefix = String(text.commonPrefix(with: committedPrefix, options: .literal))
        }

        let unread = String(text.dropFirst(committedPrefix.count))
        guard !unread.isEmpty else { return [] }

        var segments: [String] = []
        var buffer = ""

        for character in unread {
            buffer.append(character)
            if let cut = Self.boundaryLength(
                in: buffer,
                maxPendingCharacters: maxPendingCharacters
            ) {
                let piece = String(buffer.prefix(cut))
                buffer.removeFirst(cut)
                committedPrefix += piece
                if let speakable = speakablePiece(piece) {
                    segments.append(speakable)
                }
            }
        }

        return segments
    }

    /// Emits any remaining unspoken text after the stream ends.
    public mutating func finish(cumulative text: String) -> [String] {
        var segments = consume(cumulative: text)
        if text.count > committedPrefix.count {
            let remainder = String(text.dropFirst(committedPrefix.count))
            committedPrefix = text
            if let speakable = speakablePiece(remainder) {
                segments.append(speakable)
            }
        }
        return segments
    }

    /// Strips Markdown so TTS does not read markup aloud (shared sanitizer).
    public static func speakableText(_ text: String) -> String? {
        SpeechMarkdownSanitizer.speakable(text)
    }

    /// One emitted piece: fences toggle skipping, a bare "1." list number is
    /// dropped (the item text follows as its own piece), the rest is cleaned.
    private mutating func speakablePiece(_ piece: String) -> String? {
        let startsLine = atLineStart
        atLineStart = piece.last?.isNewline == true
        if startsLine, SpeechMarkdownSanitizer.isFenceLine(piece) {
            inCodeFence.toggle()
            return nil
        }
        if inCodeFence { return nil }
        if startsLine, piece.range(of: #"^\s*\d{1,3}[.)]\s+$"#, options: .regularExpression) != nil {
            atLineStart = true
            return nil
        }
        return SpeechMarkdownSanitizer.speakableLine(piece, atLineStart: startsLine)
    }

    /// Character length of the first speakable sentence (or overflow cut) in `buffer`.
    public static func boundaryLength(
        in buffer: String,
        maxPendingCharacters: Int = StreamingSpeechChunker.defaultMaxPendingCharacters
    ) -> Int? {
        if let newline = buffer.firstIndex(where: { $0.isNewline }) {
            return buffer.distance(from: buffer.startIndex, to: newline) + 1
        }

        if let sentence = firstSentenceEnd(in: buffer) {
            return sentence
        }

        if buffer.count >= maxPendingCharacters {
            return overflowCut(in: buffer, limit: maxPendingCharacters)
        }

        return nil
    }

    // MARK: - Sentence detection

    private static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "vs", "etc",
        "eg", "e.g", "ie", "i.e", "inc", "ltd", "st", "ave", "blvd",
        "dept", "est", "al", "fig", "no", "vol", "pp", "pg",
        "approx", "jan", "feb", "mar", "apr", "jun", "jul", "aug",
        "sep", "sept", "oct", "nov", "dec", "gen", "col", "sgt",
        "rev", "hon", "mt", "ft", "univ", "assn",
    ]

    private static let closers: Set<Character> = ["\"", "'", "\u{201D}", "\u{2019}", ")", "]", "}", "*", "_", "`", "~"]
    private static let sentencePunctuation: Set<Character> = [".", "!", "?"]

    private static func firstSentenceEnd(in buffer: String) -> Int? {
        var index = buffer.startIndex
        while index < buffer.endIndex {
            let character = buffer[index]
            if sentencePunctuation.contains(character) {
                let punctStart = index
                var punctEnd = buffer.index(after: index)
                while punctEnd < buffer.endIndex, sentencePunctuation.contains(buffer[punctEnd]) {
                    punctEnd = buffer.index(after: punctEnd)
                }

                var closerEnd = punctEnd
                while closerEnd < buffer.endIndex, closers.contains(buffer[closerEnd]) {
                    closerEnd = buffer.index(after: closerEnd)
                }

                guard closerEnd < buffer.endIndex, buffer[closerEnd].isWhitespace else {
                    index = punctEnd
                    continue
                }

                var afterWhitespace = buffer.index(after: closerEnd)
                while afterWhitespace < buffer.endIndex, buffer[afterWhitespace].isWhitespace {
                    afterWhitespace = buffer.index(after: afterWhitespace)
                }

                let punctRun = String(buffer[punctStart..<punctEnd])
                if isValidSentenceTerminator(
                    punctRun: punctRun,
                    before: buffer[..<punctStart],
                    afterWhitespace: afterWhitespace < buffer.endIndex ? buffer[afterWhitespace] : nil
                ) {
                    return buffer.distance(from: buffer.startIndex, to: buffer.index(after: closerEnd))
                }

                index = punctEnd
                continue
            }
            index = buffer.index(after: index)
        }
        return nil
    }

    private static func isValidSentenceTerminator(
        punctRun: String,
        before: Substring,
        afterWhitespace: Character?
    ) -> Bool {
        let isQuestionOrExclaim = punctRun.contains(where: { $0 == "!" || $0 == "?" })
        if isQuestionOrExclaim {
            return true
        }

        // Incomplete ellipsis (".." still growing into "...") is not a boundary.
        // A finished "..." only ends the sentence when the next word is not a
        // lowercase continuation ("Wait... then we kept going").
        if punctRun.count >= 2 {
            if punctRun.contains(where: { $0 != "." }) {
                return true
            }
            if let next = afterWhitespace {
                return !next.isLowercase
            }
            return false
        }

        let token = tokenBeforeTerminator(before)
        if isAbbreviation(token) {
            return false
        }

        return true
    }

    private static func tokenBeforeTerminator(_ before: Substring) -> String {
        var end = before.endIndex
        while end > before.startIndex {
            let previous = before.index(before: end)
            if before[previous].isWhitespace { break }
            end = previous
        }
        return String(before[end...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isAbbreviation(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’()[]{}"))
        guard !trimmed.isEmpty else { return false }
        let lowered = trimmed.lowercased()
        if abbreviations.contains(lowered) { return true }

        // Initials and dotted acronyms: "A.", "U.S.", "U.S.A."
        let letters = lowered.split(separator: ".", omittingEmptySubsequences: true)
        if !letters.isEmpty, letters.allSatisfy({ $0.count == 1 && $0.first?.isLetter == true }) {
            return true
        }
        return false
    }

    /// Long sentence with no terminator: cut at the last clause punctuation, else whitespace.
    private static func overflowCut(in buffer: String, limit: Int) -> Int {
        let window = String(buffer.prefix(limit))
        let clauseMarks: Set<Character> = [",", ";", ":", "—", "–"]
        if let clause = window.lastIndex(where: { clauseMarks.contains($0) }),
           clause > window.startIndex {
            let after = window.index(after: clause)
            if after < window.endIndex, window[after].isWhitespace {
                return window.distance(from: window.startIndex, to: after) + 1
            }
            if after == window.endIndex {
                return window.distance(from: window.startIndex, to: after)
            }
        }
        if let space = window.lastIndex(where: { $0.isWhitespace }),
           space > window.startIndex {
            return window.distance(from: window.startIndex, to: space) + 1
        }
        return window.count
    }
}
