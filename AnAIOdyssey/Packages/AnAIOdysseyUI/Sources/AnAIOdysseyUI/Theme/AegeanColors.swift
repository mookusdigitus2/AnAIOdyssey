// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import SwiftUI

/// Aegean design tokens from `IPHONE_DESIGN.md`.
public enum AegeanColors {
    public static func accent(_ colorScheme: ColorScheme) -> Color {
        AegeanPalette.accent(for: colorScheme)
    }

    public static func accentFill(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.16, green: 0.66, blue: 0.75)
            : Color(red: 0.00, green: 0.58, blue: 0.68)
    }

    public static func aiViolet(_ colorScheme: ColorScheme) -> Color {
        AegeanPalette.aiViolet(for: colorScheme)
    }

    public static func groupedBackground(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.05, green: 0.08, blue: 0.13)
            : Color(red: 0.96, green: 0.97, blue: 0.98)
    }

    public static func label(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.91, green: 0.93, blue: 0.96)
            : Color(red: 0.06, green: 0.09, blue: 0.16)
    }

    public static func secondaryLabel(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.58, green: 0.63, blue: 0.71)
            : Color(red: 0.36, green: 0.42, blue: 0.50)
    }

    public static func surface(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.09, green: 0.13, blue: 0.18)
            : Color.white
    }

    public static func success(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.29, green: 0.87, blue: 0.50)
            : Color(red: 0.12, green: 0.54, blue: 0.33)
    }

    public static func warning(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.98, green: 0.57, blue: 0.24)
            : Color(red: 0.76, green: 0.25, blue: 0.05)
    }
}

/// Programmatic Aegean palette colors.
public enum AegeanPalette {
    public static func accent(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.21, green: 0.77, blue: 0.86)
            : Color(red: 0.00, green: 0.48, blue: 0.58)
    }

    public static func aiViolet(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.65, green: 0.55, blue: 0.98)
            : Color(red: 0.43, green: 0.29, blue: 0.88)
    }
}
