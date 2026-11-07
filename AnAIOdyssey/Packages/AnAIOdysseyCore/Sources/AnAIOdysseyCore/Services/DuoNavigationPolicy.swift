// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation

/// Which side of the window the section sidebar sits on.
public enum SidebarEdge: String, Sendable, Equatable {
    case leading
    case trailing
}

/// iPhone Duo: the system's bars and the status bar run down the right of the open phone, so the
/// app's section sidebar goes on the right too instead of the left. iPad, Mac and every compact
/// phone (the Duo's outer display, ordinary iPhones) keep the usual left sidebar or tab bar.
public enum DuoNavigationPolicy {
    /// DEBUG only: treat the device as an open iPhone Duo, so an iPad simulator can stand in for
    /// the inner display (there is no iPhone Duo simulator before Xcode 27.1).
    public static let simulateDuoArgument = "-DuoLayout"

    /// An open iPhone Duo is a phone that is regular in both directions; a Plus/Max phone on its
    /// side is regular width but compact height and isn't one.
    public static func sectionSidebarEdge(
        idiomIsPhone: Bool,
        horizontalSizeClassIsRegular: Bool,
        verticalSizeClassIsRegular: Bool
    ) -> SidebarEdge {
        idiomIsPhone && horizontalSizeClassIsRegular && verticalSizeClassIsRegular ? .trailing : .leading
    }
}
