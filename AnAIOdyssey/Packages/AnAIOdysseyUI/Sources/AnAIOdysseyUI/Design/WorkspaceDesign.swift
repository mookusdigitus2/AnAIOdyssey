// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Typography

/// Semantic text styles aligned with Apple's Human Interface Guidelines.
enum AnAIOdysseyFont {
    static let listTitle = Font.headline
    static let listSubtitle = Font.subheadline
    static let metadata = Font.caption
    static let footnote = Font.footnote
    static let detailTitle = Font.title2.weight(.semibold)
    static let detailSubtitle = Font.title3.weight(.semibold)
    static let editorTitle = Font.title2.weight(.semibold)
}

// MARK: - Colors & Metrics

/// Shared color tokens and layout metrics, with platform-appropriate system
/// colors for chat bubbles so they sit naturally on each OS.
enum AnAIOdysseyColor {
    static let selectionBackground = Color.accentColor.opacity(0.15)

    #if os(macOS)
    static let chatBubbleUser = Color.accentColor.opacity(0.14)
    static let chatBubbleAssistant = Color(nsColor: .controlBackgroundColor)
    #else
    static let chatBubbleUser = Color.accentColor.opacity(0.14)
    static let chatBubbleAssistant = Color(uiColor: .secondarySystemBackground)
    #endif

    static let panelCornerRadius: CGFloat = 10
}

// MARK: - List rows

/// Standard sidebar / master-list row with title and optional subtitles.
struct SidebarListRow: View {
    let title: String
    var subtitle: String?
    var secondaryLine: String?
    var lineLimit: Int = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(AnAIOdysseyFont.listTitle)
                .lineLimit(lineLimit)

            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(AnAIOdysseyFont.metadata)
                    .foregroundStyle(.secondary)
                    .lineLimit(lineLimit)
            }

            if let secondaryLine, !secondaryLine.isEmpty {
                Text(secondaryLine)
                    .font(AnAIOdysseyFont.metadata)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Placeholder text for empty sidebar lists.
struct WorkspaceEmptyListLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(AnAIOdysseyFont.metadata)
            .foregroundStyle(.secondary)
    }
}

// MARK: - Action button affordance

/// Gives workspace action buttons ("New", "Delete", "Import", …) an explicit
/// enabled/disabled affordance. macOS toolbar buttons render the same neutral
/// gray whether or not they are enabled, so actionable controls read as
/// disabled. This tints the label with the app accent (red for destructive
/// actions) while the button is enabled and dims it only when it is actually
/// disabled.
///
/// Apply directly on the `Button`, before any `.disabled(...)` modifier, so
/// the environment's `isEnabled` is visible to it.
struct WorkspaceActionButtonTint: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    var isDestructive = false

    func body(content: Content) -> some View {
        content.foregroundStyle(tint)
    }

    private var tint: AnyShapeStyle {
        guard isEnabled else { return AnyShapeStyle(.tertiary) }
        return isDestructive ? AnyShapeStyle(Color.red) : AnyShapeStyle(Color.accentColor)
    }
}

extension View {
    /// Accent-tints an action button while enabled (red when `destructive`),
    /// dimming it only when actually disabled. See ``WorkspaceActionButtonTint``.
    func workspaceActionButtonTint(destructive: Bool = false) -> some View {
        modifier(WorkspaceActionButtonTint(isDestructive: destructive))
    }
}

// MARK: - Status feedback

/// An inline status line (error/success/info) with a tinted icon, used across the
/// app to report operation results in a consistent style.
struct StatusMessage: View {
    /// The semantic category of the message, which selects its icon and tint.
    enum Kind {
        case error
        case success
        case info

        /// SF Symbol representing this kind.
        var symbol: String {
            switch self {
            case .error: "exclamationmark.triangle.fill"
            case .success: "checkmark.circle.fill"
            case .info: "info.circle.fill"
            }
        }

        /// Foreground color conveying severity.
        var tint: Color {
            switch self {
            case .error: .red
            case .success: .green
            case .info: .secondary
            }
        }
    }

    let kind: Kind
    let text: String
    /// When true, the text is selectable (useful for copyable results/errors).
    var allowsSelection: Bool = false
    /// When true, renders inside a scroll view with a generous max height.
    var scrollable: Bool = false

    var body: some View {
        Group {
            if scrollable {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: kind.symbol)
                        .foregroundStyle(kind.tint)
                    ScrollableTextDocumentView(text: text)
                }
                .copyableContextMenu(text: text)
            } else {
                Label {
                    if allowsSelection {
                        Text(text)
                            .textSelection(.enabled)
                            .copyableContextMenu(text: text)
                    } else {
                        Text(text)
                    }
                } icon: {
                    Image(systemName: kind.symbol)
                }
                .foregroundStyle(kind.tint)
                .font(AnAIOdysseyFont.metadata)
            }
        }
        .accessibilityLabel(text)
    }
}

// MARK: - Panels & selection

/// A rounded, lightly-filled container used to group content (e.g. compare
/// responses, email summaries) into a visually distinct panel.
struct WorkspacePanel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: AnAIOdysseyColor.panelCornerRadius, style: .continuous))
    }
}

extension View {
    /// Native form field appearance — avoids legacy `.roundedBorder` inside `Form` on macOS.
    @ViewBuilder
    func workspaceFormField() -> some View {
        #if os(iOS)
        self
        #else
        self.textFieldStyle(.plain)
        #endif
    }

    /// Independent tap target inside a Form or List row.
    ///
    /// iOS otherwise delivers one tap to every `Button` (and to a `NavigationLink`
    /// sharing the row). `.plain` is not enough; accent swatches already use this.
    func isolatedFormButton() -> some View {
        buttonStyle(.borderless)
    }

    /// Applies URL and email keyboard hygiene for settings fields.
    func workspaceSettingsField() -> some View {
        self
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .autocorrectionDisabled()
            .workspaceFormField()
    }

    /// Applies the standard selection highlight to a list row when selected.
    @ViewBuilder
    func workspaceSelectionBackground(isSelected: Bool) -> some View {
        listRowBackground(isSelected ? AnAIOdysseyColor.selectionBackground : Color.clear)
    }

    /// Applies the role-appropriate chat-bubble fill (user vs. assistant) with the
    /// shared rounded shape.
    @ViewBuilder
    func workspaceChatBubbleBackground(role: String) -> some View {
        let isUser = role == "user"
        background(
            isUser ? AnAIOdysseyColor.chatBubbleUser : AnAIOdysseyColor.chatBubbleAssistant,
            in: RoundedRectangle(cornerRadius: AnAIOdysseyColor.panelCornerRadius, style: .continuous)
        )
    }
}

/// Loads a SwiftUI `Image` from a file URL using the platform image decoder.
struct WorkspaceFileImage: View {
    let url: URL

    var body: some View {
        if let image = PlatformFileImage(contentsOf: url) {
            image
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "photo")
                .foregroundStyle(.secondary)
        }
    }
}

#if os(macOS)
private typealias PlatformFileImage = Image

private extension Image {
    init?(contentsOf url: URL) {
        guard let nsImage = NSImage(contentsOf: url) else { return nil }
        self.init(nsImage: nsImage)
    }
}
#else
private typealias PlatformFileImage = Image

private extension Image {
    init?(contentsOf url: URL) {
        guard let uiImage = UIImage(contentsOfFile: url.path) else { return nil }
        self.init(uiImage: uiImage)
    }
}
#endif

