// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation

/// Cleans raw LLM output into the final email text shown/sent to the user.
///
/// The prompts (see `EmailPrompts`) instruct the model to wrap its real answer between
/// `<<<SUMMARY>>>`/`<<<REPLY>>>`/`<<<OUTPUT>>>` and `<<<END>>>` markers and to put any
/// reasoning before them (often inside `<think>` tags). This parser extracts just the
/// fenced content, strips reasoning, and applies plain-text style fixups.
public enum EmailResponseParser {
    private static let openPattern = #"<<<\s*(?:REPLY|SUMMARY|OUTPUT)\s*>>+"#
    private static let closePattern = #"<<<\s*END\s*>>+"#

    /// Extracts the model's final answer from between the output markers and tidies it.
    ///
    /// If an opening marker is found, keeps only the text up to the closing marker (or to
    /// the end if no close is present). Any stray markers are then stripped, reasoning
    /// `<think>` blocks removed, and email style mechanics applied. Returns `""` for empty input.
    public static func extractFencedOutput(from text: String) -> String {
        guard !text.isEmpty else { return "" }

        // If an opening marker exists, slice to the content after it, then cut at the close.
        var content = text
        if let openRange = content.range(of: openPattern, options: [.regularExpression, .caseInsensitive]) {
            content = String(content[openRange.upperBound...])
            if let closeRange = content.range(of: closePattern, options: [.regularExpression, .caseInsensitive]) {
                content = String(content[..<closeRange.lowerBound])
            }
        }

        // Remove any remaining/duplicated open and close markers the model may have emitted.
        content = content.replacingOccurrences(
            of: openPattern,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        content = content.replacingOccurrences(
            of: closePattern,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        // Drop chain-of-thought, then normalize punctuation for plain-text email.
        return applyEmailStyleMechanics(stripThinkTags(from: content))
    }

    /// Normalizes "smart" typography into ASCII suitable for plain-text email.
    ///
    /// Converts em/en dashes to `--` and curly quotes to straight `'`, matching the
    /// mechanical style rules in the reply prompt, and trims surrounding whitespace.
    public static func applyEmailStyleMechanics(_ text: String) -> String {
        text
            .replacingOccurrences(of: "—", with: "--")
            .replacingOccurrences(of: "–", with: "--")
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‘", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes `<think>...</think>` reasoning blocks that some models emit before the answer.
    private static func stripThinkTags(from text: String) -> String {
        text.replacingOccurrences(
            of: "<think>[\\s\\S]*?</think>",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
    }
}
