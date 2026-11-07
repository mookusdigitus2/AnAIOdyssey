// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import SwiftUI
import AIModelOptions

#if os(iOS)
import UIKit

/// Native selectable text on iOS — SwiftUI `Text(AttributedString)` often blocks copy/select.
struct CopyableUITextView: UIViewRepresentable {
    let plainText: String
    var isScrollEnabled: Bool = false

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = isScrollEnabled
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.dataDetectorTypes = [.link, .phoneNumber]
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        textView.isScrollEnabled = isScrollEnabled
        textView.font = .preferredFont(forTextStyle: .body)
        textView.text = plainText
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard !isScrollEnabled else { return nil }
        // The view's own container, never the whole screen (wrong on a foldable or in Split View).
        guard let width = WorkspaceNavigationPolicy.textFitWidth(
            proposed: proposal.width,
            containerWidth: uiView.superview?.bounds.width ?? uiView.window?.bounds.width
        ) else { return nil }
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: max(fitted.height, 20))
    }
}
#endif

enum PasteboardSupport {
    static func copy(_ text: String) {
        guard !text.isEmpty else { return }
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

extension View {
    /// Long-press / right-click fallback when system text selection is awkward.
    func copyableContextMenu(text: String) -> some View {
        contextMenu {
            Button("Copy") {
                PasteboardSupport.copy(text)
            }
        }
    }
}
