// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import AnAIOdysseyAI
import AnAIOdysseyCore
import SwiftUI

/// User-selectable preference for which mail backend the app should use.
///
/// `.automatic` prefers Gmail when signed in and otherwise falls back to Apple Mail.
/// Conforms to `CaseIterable`/`Identifiable` so it can drive a SwiftUI picker.
public enum MailBackendPreference: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case gmail
    case appleMail

    public var id: String { rawValue }

    /// Human-readable label shown in settings UI for each option.
    public var title: String {
        switch self {
        case .automatic: "Automatic (Gmail if signed in, else Apple Mail)"
        case .gmail: "Gmail (Google API)"
        case .appleMail: "Apple Mail (local database)"
        }
    }
}

/// Google OAuth + Gemini credentials stored in UserDefaults / Keychain.
///
/// Observable settings store that persists each property to `UserDefaults` on write and
/// reloads when iCloud delivers remote changes (so settings sync across devices). The
/// OAuth tokens themselves are held separately in `tokenStore`. A `shared` singleton is
/// provided for app-wide use.
public final class GoogleSettings: ObservableObject {
    public static let shared = GoogleSettings()

    /// `UserDefaults` keys for each persisted setting (namespaced to avoid collisions).
    private enum Keys {
        static let oauthClientID = "anaiodyssey.google.oauthClientID"
        static let mailBackend = "anaiodyssey.google.mailBackend"
        static let geminiAPIKey = "anaiodyssey.google.geminiAPIKey"
        static let geminiModel = "anaiodyssey.google.geminiModel"
        static let accountEmail = "anaiodyssey.google.accountEmail"
    }

    /// Gemini's OpenAI-compatible endpoint used when applying credentials to provider settings.
    public static let defaultGeminiBaseURL = "https://generativelanguage.googleapis.com/v1beta/openai"
    /// Default Gemini model used until the user picks another.
    public static let defaultGeminiModel = "gemini-2.0-flash"

    /// Google OAuth client id; persisted on change so sign-in can use it.
    @Published public var oauthClientID: String {
        didSet { defaults.set(oauthClientID, forKey: Keys.oauthClientID) }
    }

    /// Which mail backend to use; persisted on change.
    @Published public var mailBackend: MailBackendPreference {
        didSet { defaults.set(mailBackend.rawValue, forKey: Keys.mailBackend) }
    }

    /// Gemini API key for the remote AI provider; persisted on change.
    @Published public var geminiAPIKey: String {
        didSet { defaults.set(geminiAPIKey, forKey: Keys.geminiAPIKey) }
    }

    /// Selected Gemini model name; persisted on change.
    @Published public var geminiModel: String {
        didSet { defaults.set(geminiModel, forKey: Keys.geminiModel) }
    }

    /// The signed-in Google account email (for display); persisted on change.
    @Published public var accountEmail: String {
        didSet { defaults.set(accountEmail, forKey: Keys.accountEmail) }
    }

    private let defaults: UserDefaults
    public let tokenStore: GoogleTokenStore
    private var cloudSyncObserver: NSObjectProtocol?

    /// Loads all settings from `UserDefaults` and subscribes to iCloud remote-change notifications.
    ///
    /// Each property is seeded from defaults (with sensible fallbacks) and the observer
    /// re-syncs published values when another device pushes changes via iCloud.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.tokenStore = GoogleTokenStore(defaults: defaults)
        // Seed each published property from persisted defaults (with fallbacks).
        oauthClientID = defaults.string(forKey: Keys.oauthClientID) ?? ""
        let backendRaw = defaults.string(forKey: Keys.mailBackend) ?? MailBackendPreference.automatic.rawValue
        mailBackend = MailBackendPreference(rawValue: backendRaw) ?? .automatic
        geminiAPIKey = defaults.string(forKey: Keys.geminiAPIKey) ?? ""
        geminiModel = defaults.string(forKey: Keys.geminiModel) ?? Self.defaultGeminiModel
        accountEmail = defaults.string(forKey: Keys.accountEmail) ?? ""
        // Re-pull values whenever iCloud applies remote changes from another device.
        cloudSyncObserver = NotificationCenter.default.addObserver(
            forName: CloudDefaultsSync.didApplyRemoteChanges,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reloadFromDefaults()
        }
    }

    /// Removes the iCloud sync observer on teardown.
    deinit {
        if let cloudSyncObserver {
            NotificationCenter.default.removeObserver(cloudSyncObserver)
        }
    }

    /// Reloads published values from `UserDefaults` after iCloud delivers remote changes.
    ///
    /// Each value is only reassigned when it actually differs, to avoid redundant
    /// `didSet` writes and spurious `@Published` change notifications (which could loop).
    private func reloadFromDefaults() {
        let newClientID = defaults.string(forKey: Keys.oauthClientID) ?? ""
        if newClientID != oauthClientID { oauthClientID = newClientID }
        let backendRaw = defaults.string(forKey: Keys.mailBackend) ?? MailBackendPreference.automatic.rawValue
        let newBackend = MailBackendPreference(rawValue: backendRaw) ?? .automatic
        if newBackend != mailBackend { mailBackend = newBackend }
        let newKey = defaults.string(forKey: Keys.geminiAPIKey) ?? ""
        if newKey != geminiAPIKey { geminiAPIKey = newKey }
        let newModel = defaults.string(forKey: Keys.geminiModel) ?? Self.defaultGeminiModel
        if newModel != geminiModel { geminiModel = newModel }
        let newEmail = defaults.string(forKey: Keys.accountEmail) ?? ""
        if newEmail != accountEmail { accountEmail = newEmail }
    }

    /// True when an OAuth client id has been entered (a prerequisite for sign-in).
    public var isOAuthConfigured: Bool {
        !oauthClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// True when we hold credentials usable for Google API calls.
    ///
    /// Considered signed in if there's a valid (unexpired) access token or a refresh
    /// token we can exchange for a new one.
    public var isSignedIn: Bool {
        guard tokenStore.tokens != nil else { return false }
        return tokenStore.hasValidAccessToken || tokenStore.refreshTokenValue() != nil
    }

    /// True when a Gemini API key has been provided.
    public var isGeminiConfigured: Bool {
        !geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Performs interactive Google sign-in via `WorkspaceConnectionManager`
    /// (ASWebAuthenticationSession + PKCE on iOS, iPadOS, and macOS).
    @MainActor
    public func signIn() async throws {
        let account = try await WorkspaceConnectionManager.shared.connectGoogle()
        if !account.email.isEmpty {
            accountEmail = account.email
        }
    }

    /// Pushes the stored Gemini base URL, key, and model into the shared provider settings.
    ///
    /// Runs on the main actor since `ProviderSettings` is UI/state bound.
    @MainActor
    public func applyGeminiToProviderSettings(_ providerSettings: ProviderSettings) {
        providerSettings.apiBaseURL = Self.defaultGeminiBaseURL
        providerSettings.apiKey = geminiAPIKey
        providerSettings.remoteModel = geminiModel
    }

    /// Clears stored OAuth tokens and the cached account email (local sign-out).
    public func signOut() {
        tokenStore.clear()
        accountEmail = ""
    }
}

/// SwiftUI environment key exposing the shared `GoogleSettings` to views.
private struct GoogleSettingsKey: EnvironmentKey {
    static let defaultValue: GoogleSettings? = nil
}

public extension EnvironmentValues {
    /// Access the app's `GoogleSettings` via `@Environment(\.googleSettings)`.
    var googleSettings: GoogleSettings? {
        get { self[GoogleSettingsKey.self] }
        set { self[GoogleSettingsKey.self] = newValue }
    }
}
