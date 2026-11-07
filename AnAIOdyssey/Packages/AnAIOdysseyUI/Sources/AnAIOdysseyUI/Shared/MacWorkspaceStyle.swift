// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import SwiftUI

// Platform-styling helpers that keep per-OS chrome differences out of the feature
// views. Each modifier applies macOS-specific styling and is a no-op (or the iOS
// equivalent) elsewhere, so call sites read the same on both platforms.
extension View {
    /// Expands the scene root to the full window bounds on iPad/iPhone.
    ///
    /// SwiftUI can otherwise propose a phone-sized ideal layout on iPad, leaving
    /// letterboxing and the wrong aspect ratio inside resizable windows.
    @ViewBuilder
    func workspaceSceneRoot() -> some View {
        #if os(iOS)
        GeometryReader { proxy in
            self
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .background {
            Color(uiColor: .systemBackground).ignoresSafeArea()
        }
        #else
        self
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
    }

    /// Ensures nested split views expand to fill the workspace on iPad.
    @ViewBuilder
    func workspaceNavigationSplit() -> some View {
        #if os(iOS)
        self
            .navigationSplitViewStyle(.balanced)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        #else
        self
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
    }

    /// Sidebar list styling: the native `.sidebar` look on macOS, inset-grouped on iOS.
    @ViewBuilder
    func macWorkspaceSidebarListStyle() -> some View {
        #if os(macOS)
        listStyle(.sidebar)
        #else
        listStyle(.insetGrouped)
        #endif
    }

    /// Constrains the sidebar column width so toolbar actions stay visible
    /// instead of collapsing behind the overflow chevrons.
    @ViewBuilder
    func macSidebarColumn() -> some View {
        navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
    }

    /// Convenience combining the sidebar list style and column width for the
    /// master columns of nested split views.
    @ViewBuilder
    func macWorkspaceSplit() -> some View {
        macWorkspaceSidebarListStyle()
            .macSidebarColumn()
    }

    /// Removes the redundant sidebar-toggle button that a nested `NavigationSplitView`
    /// adds (the double-chevron control). The app-level tab bar is the navigator.
    @ViewBuilder
    func removeNestedSidebarToggle() -> some View {
        #if os(macOS)
        toolbar(removing: .sidebarToggle)
        #else
        if #available(iOS 18.0, *) {
            toolbar(removing: .sidebarToggle)
        } else {
            self
        }
        #endif
    }

    /// Standard settings form chrome for macOS Settings window and iOS navigation.
    @ViewBuilder
    func workspaceSettingsForm() -> some View {
        #if os(macOS)
        formStyle(.grouped)
        #else
        self
        #endif
    }

    /// Expands nested split-view panes to fill the parent detail column.
    @ViewBuilder
    func workspaceFillDetailPane() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(macOS)
        .background(Color(nsColor: .textBackgroundColor))
        #else
        .background(Color(uiColor: .systemBackground))
        #endif
    }

    /// Edge-to-edge editor / message scroller inside a split-view detail pane.
    @ViewBuilder
    func workspaceEdgeToEdgeScrollContent() -> some View {
        #if os(macOS)
        if #available(macOS 15.0, *) {
            contentMargins(.horizontal, 0, for: .scrollContent)
        } else {
            self
        }
        #else
        self
        #endif
    }

    /// Bottom composer strip shared by chat and research follow-ups.
    @ViewBuilder
    func workspaceComposerBar() -> some View {
        #if os(macOS)
        padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.bar)
        #else
        padding(.horizontal, 12)
            .padding(.vertical, 10)
        #endif
    }
}
