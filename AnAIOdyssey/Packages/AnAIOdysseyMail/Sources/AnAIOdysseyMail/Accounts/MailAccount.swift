// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation

/// The kind of mail source an account is backed by.
///
/// `appleMail` is the local Mail.app store (macOS only, single implicit account).
/// `gmail` is the Google REST API behind OAuth. `imap` is reserved for a future
/// generic IMAP backend (not yet implemented).
public enum MailProvider: String, Codable, Sendable, CaseIterable, Identifiable {
    case gmail
    case appleMail
    case imap

    public var id: String { rawValue }

    /// Human-readable provider name for settings/UI.
    public var displayName: String {
        switch self {
        case .gmail: "Gmail"
        case .appleMail: "Apple Mail"
        case .imap: "IMAP"
        }
    }

    /// SF Symbol used to represent the provider in lists.
    public var systemImage: String {
        switch self {
        case .gmail: "envelope.fill"
        case .appleMail: "mail.stack"
        case .imap: "tray.full"
        }
    }

    /// Whether signing into this provider uses an OAuth flow (vs. local access).
    public var usesOAuth: Bool {
        self == .gmail
    }
}

/// A single configured mail account in the multi-account model.
///
/// Accounts are persisted as a list (their non-secret metadata) while each
/// account's OAuth tokens live separately in the Keychain keyed by `id`. The
/// `id` is a stable UUID string used both as the persistence key and the
/// Keychain item account, so removing an account also removes its secrets.
public struct MailAccount: Identifiable, Codable, Sendable, Hashable {
    public let id: String
    public let provider: MailProvider
    /// The account's email address (e.g. the signed-in Google address).
    public var email: String
    /// Optional friendly label; falls back to `email` for display.
    public var displayName: String?
    public let dateAdded: Date

    public init(
        id: String = UUID().uuidString,
        provider: MailProvider,
        email: String,
        displayName: String? = nil,
        dateAdded: Date = .now
    ) {
        self.id = id
        self.provider = provider
        self.email = email
        self.displayName = displayName
        self.dateAdded = dateAdded
    }

    /// Best label for UI: the explicit display name, else the email, else the provider.
    public var label: String {
        if let displayName, !displayName.isEmpty { return displayName }
        if !email.isEmpty { return email }
        return provider.displayName
    }

    /// A short label combining provider and address, e.g. "Gmail · me@example.com".
    public var detailedLabel: String {
        email.isEmpty ? provider.displayName : "\(provider.displayName) · \(email)"
    }
}
