// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Combine
import AnAIOdysseyCore
import SwiftUI

/// Selectable accent palettes for the app's tint color.
///
/// Each case maps to a tasteful, HIG-friendly accent applied app-wide via
/// `.tint(...)`. The raw value is persisted (and iCloud-synced), so add cases at
/// the end to keep existing selections stable.
public enum AppAccent: String, CaseIterable, Identifiable, Sendable {
    case aegean
    case ocean
    case indigo
    case violet
    case rose
    case sunset
    case forest
    case graphite

    public var id: String { rawValue }

    /// User-facing palette name.
    public var displayName: String {
        switch self {
        case .aegean: return "Aegean"
        case .ocean: return "Ocean"
        case .indigo: return "Indigo"
        case .violet: return "Violet"
        case .rose: return "Rose"
        case .sunset: return "Sunset"
        case .forest: return "Forest"
        case .graphite: return "Graphite"
        }
    }

    /// The accent color for this palette (light-appearance value).
    ///
    /// Prefer ``color(for:)`` where a `ColorScheme` is available so dark mode
    /// gets its brighter pair.
    public var color: Color {
        color(for: .light)
    }

    /// The accent color for this palette, adapted to the appearance.
    ///
    /// Light values are deep enough to carry white glyphs; dark values are
    /// lifted so the accent stays legible against dark backgrounds (matching how
    /// `AegeanPalette.accent(for:)` adapts).
    public func color(for colorScheme: ColorScheme) -> Color {
        let rgb = components(for: colorScheme)
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    /// A legible color for glyphs drawn on top of the accent (the swatch
    /// checkmark, today's day number, …), chosen by the accent's relative
    /// luminance rather than fixed white.
    public func onAccentColor(for colorScheme: ColorScheme) -> Color {
        let rgb = components(for: colorScheme)
        // Rec. 709 relative-luminance weighting on the raw sRGB components —
        // a sufficient approximation to pick black vs. white overlays.
        let luminance = 0.2126 * rgb.red + 0.7152 * rgb.green + 0.0722 * rgb.blue
        return luminance > 0.5 ? Color.black.opacity(0.85) : .white
    }

    /// Raw sRGB components per palette and appearance.
    private func components(for colorScheme: ColorScheme) -> (red: Double, green: Double, blue: Double) {
        switch (self, colorScheme) {
        case (.aegean, .dark): return (0.21, 0.77, 0.86)
        case (.aegean, _): return (0.00, 0.48, 0.58)
        case (.ocean, .dark): return (0.16, 0.78, 0.88)
        case (.ocean, _): return (0.00, 0.58, 0.68)
        case (.indigo, .dark): return (0.48, 0.56, 0.97)
        case (.indigo, _): return (0.27, 0.35, 0.80)
        case (.violet, .dark): return (0.69, 0.52, 0.96)
        case (.violet, _): return (0.50, 0.31, 0.78)
        case (.rose, .dark): return (0.96, 0.47, 0.64)
        case (.rose, _): return (0.85, 0.27, 0.46)
        case (.sunset, .dark): return (0.98, 0.62, 0.33)
        case (.sunset, _): return (0.92, 0.49, 0.18)
        case (.forest, .dark): return (0.36, 0.76, 0.53)
        case (.forest, _): return (0.18, 0.55, 0.34)
        case (.graphite, .dark): return (0.62, 0.67, 0.73)
        case (.graphite, _): return (0.36, 0.40, 0.45)
        }
    }
}

/// The app's appearance mode preference.
public enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    /// User-facing label.
    public var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// The `ColorScheme` to force, or `nil` to follow the system.
    public var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// Observable, user-changeable appearance settings (accent palette + light/dark).
///
/// Persisted in `UserDefaults` under the `anaiodyssey.` prefix so `CloudDefaultsSync`
/// mirrors the choice across devices. A single instance is created at the app's
/// composition root and shared into every window, so changing the theme updates
/// the whole app — including pop-out windows — live.
@MainActor
public final class ThemeSettings: ObservableObject {
    private enum Keys {
        static let accent = "anaiodyssey.appearance.accent"
        static let appearance = "anaiodyssey.appearance.mode"
    }

    /// The selected accent palette.
    @Published public var accent: AppAccent {
        didSet { defaults.set(accent.rawValue, forKey: Keys.accent) }
    }

    /// The selected appearance mode.
    @Published public var appearance: AppAppearance {
        didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance) }
    }

    private let defaults: UserDefaults
    private var cancellable: AnyCancellable?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.accent = defaults.string(forKey: Keys.accent).flatMap(AppAccent.init) ?? .aegean
        self.appearance = defaults.string(forKey: Keys.appearance).flatMap(AppAppearance.init) ?? .system

        // Reload when another device pushes a change down via iCloud.
        cancellable = NotificationCenter.default.publisher(for: CloudDefaultsSync.didApplyRemoteChanges)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reloadFromDefaults() }
    }

    /// Resolved accent color for `.tint(...)` (light-appearance value).
    public var accentColor: Color { accent.color }

    /// Resolved accent color for `.tint(...)`, adapted to the appearance.
    public func accentColor(for colorScheme: ColorScheme) -> Color {
        accent.color(for: colorScheme)
    }

    /// Resolved color scheme for `.preferredColorScheme(...)` (nil = system).
    public var colorScheme: ColorScheme? { appearance.colorScheme }

    /// Re-reads values from `UserDefaults` (after an iCloud sync) without echoing
    /// them back out through the `didSet` persisters.
    private func reloadFromDefaults() {
        let newAccent = defaults.string(forKey: Keys.accent).flatMap(AppAccent.init) ?? .aegean
        let newAppearance = defaults.string(forKey: Keys.appearance).flatMap(AppAppearance.init) ?? .system
        if newAccent != accent { accent = newAccent }
        if newAppearance != appearance { appearance = newAppearance }
    }
}

/// Applies the active theme (accent tint + color scheme) to its content.
///
/// Used to wrap each window's root so the whole scene — including pop-out windows
/// — reacts live to theme changes via the shared ``ThemeSettings``.
public struct ThemeContainer<Content: View>: View {
    @ObservedObject private var theme: ThemeSettings
    private let content: Content

    public init(theme: ThemeSettings, @ViewBuilder content: () -> Content) {
        self.theme = theme
        self.content = content()
    }

    public var body: some View {
        // The tint is applied by an inner view so it can read the *resolved*
        // color scheme (after `preferredColorScheme`) and pick the accent's
        // light/dark pair.
        AdaptiveTint(theme: theme) {
            content
                .workspaceSceneRoot()
        }
        .preferredColorScheme(theme.colorScheme)
    }
}

/// Applies the theme's accent as `.tint`, using the light/dark pair that matches
/// the resolved appearance.
private struct AdaptiveTint<Content: View>: View {
    @ObservedObject var theme: ThemeSettings
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder var content: Content

    var body: some View {
        content
            .tint(theme.accentColor(for: colorScheme))
    }
}
