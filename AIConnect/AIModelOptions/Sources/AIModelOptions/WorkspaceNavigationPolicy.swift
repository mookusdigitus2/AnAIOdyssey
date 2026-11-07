// SPDX-License-Identifier: MIT
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Which chrome the scene should show. Driven by device idiom plus both size
/// classes, never by `horizontalSizeClass` alone — a Plus/Max iPhone in
/// landscape is `.regular` width (but compact height) and must stay on the
/// phone root so the open chat and voice session survive. A phone that is
/// regular in both directions (the unfolded iPhone Duo inner screen) gets the
/// tablet root.
public enum WorkspaceLayoutKind: String, Sendable, Equatable {
    case phone
    case tablet
}

/// Why a chat or root view disappeared. Rotation and size-class flips are
/// layout rebuilds; they must not clear the open chat.
public enum WorkspaceNavigationDisappearReason: String, Sendable, Equatable {
    case sizeClassChange
    case rotation
    case sceneBackground
    case sceneDiscarded
    case userLeftChat
    case userChangedTab
}

/// Persistence keys and restore rules for the open chat and the selected tab.
public enum WorkspaceNavigationPolicy {
    public static let openChatSceneKey = "chats.openSessionID"
    public static let browsingListSceneKey = "chats.browsingList"
    public static let phoneTabSceneKey = "phone.selectedTab"
    public static let tabletSectionSceneKey = "tablet.selection"

    /// Plus/Max landscape (`regular` width) still uses the phone chrome.
    public static func rootKind(
        idiomIsPhone: Bool,
        horizontalSizeClassIsRegular: Bool
    ) -> WorkspaceLayoutKind {
        _ = horizontalSizeClassIsRegular
        return idiomIsPhone ? .phone : .tablet
    }

    public static func shouldRecreateRoot(
        previous: WorkspaceLayoutKind,
        next: WorkspaceLayoutKind
    ) -> Bool {
        previous != next
    }

    /// Fold-aware root: iPad always gets the tablet shell; an iPhone gets it only
    /// when it is regular in both directions (iPhone Duo unfolded). Re-evaluated on
    /// every size-class change, so folding and unfolding swap the shell live.
    public static func rootKind(
        idiomIsPhone: Bool,
        horizontalSizeClassIsRegular: Bool,
        verticalSizeClassIsRegular: Bool
    ) -> WorkspaceLayoutKind {
        guard idiomIsPhone else { return .tablet }
        return horizontalSizeClassIsRegular && verticalSizeClassIsRegular ? .tablet : .phone
    }

    public static func shouldUsePhoneChatLayout(idiomIsPhone: Bool) -> Bool {
        idiomIsPhone
    }

    /// The chat list uses the stack layout exactly when the root is the phone shell.
    public static func shouldUsePhoneChatLayout(
        idiomIsPhone: Bool,
        horizontalSizeClassIsRegular: Bool,
        verticalSizeClassIsRegular: Bool
    ) -> Bool {
        rootKind(
            idiomIsPhone: idiomIsPhone,
            horizontalSizeClassIsRegular: horizontalSizeClassIsRegular,
            verticalSizeClassIsRegular: verticalSizeClassIsRegular
        ) == .phone
    }

    /// Width to fit wrapping text to: the proposed width when SwiftUI gives a finite
    /// one, else the containing view's width. Never the screen's, which is wrong on a
    /// foldable, in Split View and in Stage Manager. `nil` lets the caller defer.
    public static func textFitWidth(proposed: CGFloat?, containerWidth: CGFloat?) -> CGFloat? {
        if let proposed, proposed.isFinite, proposed > 0 { return proposed }
        if let containerWidth, containerWidth.isFinite, containerWidth > 0 { return containerWidth }
        return nil
    }

    public static func storedOpenChatID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func persistOpenChatID(_ id: String?) -> String {
        id ?? ""
    }

    /// After a rebuild, show the list only when there is no stored chat or the
    /// user explicitly went back.
    public static func shouldShowSessionList(
        storedOpenChatID: String?,
        userBrowsingList: Bool
    ) -> Bool {
        Self.storedOpenChatID(storedOpenChatID) == nil || userBrowsingList
    }

    public static func shouldClearOpenChat(reason: WorkspaceNavigationDisappearReason) -> Bool {
        switch reason {
        case .sizeClassChange, .rotation, .sceneBackground, .sceneDiscarded:
            return false
        case .userLeftChat, .userChangedTab:
            return false
        }
    }

    public static func restoredPhoneTab(_ raw: String?) -> String {
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "chats" : value
    }

    public static func restoredTabletSection(_ raw: String?) -> String {
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "chats" : value
    }
}

/// Clean-exit flag used to offer the audio debug log after a crash or watchdog.
public enum UnexpectedTerminationPolicy {
    public static let cleanExitKey = "anaiodyssey.clean-exit"
    public static let promptCopy = "An AI Odyssey closed unexpectedly. Share the audio log to help fix it?"

    public static func shouldPromptForAudioLog(cleanExitFlag: Bool, hasAudioLog: Bool) -> Bool {
        !cleanExitFlag && hasAudioLog
    }
}
