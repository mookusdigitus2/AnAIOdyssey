// SPDX-License-Identifier: MIT
import Foundation

/// One rule for a connection's API key, shared by the requests, model refresh, the tool test and
/// the key field: only the known cloud providers require one (``OpenAICompatibleAPI/requiresAPIKey(baseURL:)``),
/// and a Sign in with ChatGPT row uses its token instead.
extension RemoteConnection {
    /// True when requests can't go out without a key.
    public var requiresAPIKey: Bool {
        !usesChatGPTAccount && OpenAICompatibleAPI.requiresAPIKey(baseURL: trimmedBaseURL)
    }

    /// True when the key is required and blank (or only spaces).
    public var isMissingRequiredAPIKey: Bool {
        requiresAPIKey && apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The key field's label in the connection sheet.
    public var apiKeyFieldLabel: String {
        requiresAPIKey ? "API Key" : "API Key (optional)"
    }

    /// The note under the key field, when the key is optional.
    public var apiKeyFieldFooter: String? {
        requiresAPIKey ? nil : "Leave blank if your server doesn't use one, like LM Studio."
    }
}
