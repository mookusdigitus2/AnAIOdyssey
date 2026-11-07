// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
// Portions adapted from Odysseus v1.0, Copyright (c) 2025 Odysseus Contributors,
// used under the MIT License (see ACKNOWLEDGMENTS.md).
import Foundation

/// Centralized prompt templates for the email AI features.
///
/// Holds the system prompts (which define the model's role and the strict
/// `<<<MARKER>>>` output contract that `EmailResponseParser` relies on) and builders for
/// the per-message user prompts. Bodies are clipped to bounded lengths to stay within the
/// model's context window. The reply prompt enforces identity/anti-fabrication and
/// plain-text style rules.
public enum EmailPrompts {
    /// System prompt instructing the model to emit a terse, marker-fenced bullet summary.
    public static let summarizeSystemPrompt = """
        You are an email summarizer. Format: 1-3 short bullet points (use '- '). Cover: main point, action items, deadlines. If the email has attachments (marked '--- ATTACHMENTS ---'), USE THEIR CONTENTS — pull invoice totals, deadlines, key clauses, concrete numbers/dates from PDFs/docs into the bullets. Be terse.

        OUTPUT FORMAT: Put ONLY the bullet points between these exact markers, each on its own line:
        <<<SUMMARY>>>
        - ...
        <<<END>>>
        Any reasoning must come BEFORE <<<SUMMARY>>> (ideally inside <think>...</think>). Only the text between the markers is kept.
        """

    /// Base system prompt for reply drafting (identity, anti-fabrication, style, and format rules).
    public static let replySystemPromptBase = """
        You are drafting an email reply. Write only the reply body, no subject line, and no extra commentary. Be direct and concise. Match the tone of the original email.

        MECHANICAL STYLE RULES — CRITICAL: Never use an em dash or en dash; use -- instead. Never use curly apostrophes; write I'm, don't, we'll with straight '. Do not start with 'Hey' unless explicitly requested.

        IDENTITY RULE — CRITICAL: write as the user/mailbox owner only. NEVER sign as, speak as, or imply you are the recipient, original sender, quoted sender, spouse, assistant, company, or any third party.

        CRITICAL RULE: NEVER invent facts, names, dates, phone numbers, emails, addresses, or any specifics not explicitly present in the original email itself. If the sender asks for information you don't have, say plainly that you don't have it on hand — do NOT guess or fabricate.

        OUTPUT FORMAT — IMPORTANT: Put ONLY the final email reply between these exact markers, each on its own line:
        <<<REPLY>>>
        (the reply body goes here)
        <<<END>>>
        Any reasoning, planning, or notes-to-self must come BEFORE the <<<REPLY>>> marker. Only the text between <<<REPLY>>> and <<<END>>> is sent as the email.
        """

    /// Builds the summarization user prompt, clipping the body to ~12k chars for the context window.
    public static func summarizeUserPrompt(sender: String, subject: String, body: String) -> String {
        // Bound the body length so very long emails still fit the model context.
        let clipped = String(body.prefix(12_000))
        return """
        From: \(sender)
        Subject: \(subject)

        \(clipped)

        ---

        Summarize the email. Output the bullets between <<<SUMMARY>>> and <<<END>>>.
        """
    }

    /// Builds the reply user prompt, clipping the original body to ~6k chars for the context window.
    public static func replyUserPrompt(
        recipient: String,
        subject: String,
        originalBody: String
    ) -> String {
        // Bound the original body length to keep the prompt within the model context.
        let clipped = String(originalBody.prefix(6_000))
        return """
        Recipient: \(recipient)
        Subject: \(subject)

        Original email and any current draft:
        \(clipped)

        Draft a reply. Return only the reply body text.
        """
    }

    /// Returns the reply system prompt, appending the user's writing style when provided.
    ///
    /// Falls back to the base prompt when no (non-empty) style is supplied.
    public static func replySystemPrompt(writingStyle: String?) -> String {
        // Without a meaningful writing style, use the base reply rules unchanged.
        guard let writingStyle, !writingStyle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return replySystemPromptBase
        }
        // Otherwise append the style sample the model should imitate.
        return replySystemPromptBase + "\n\nWRITING STYLE TO MATCH:\n\(writingStyle)"
    }
}
