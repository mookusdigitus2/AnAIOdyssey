// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import SwiftUI
// AppKit is needed for the macOS NSTextView-backed editors below.
#if os(macOS)
import AppKit
#endif

/// A cross-platform multi-line text editor used by the note/document editors.
///
/// On macOS it wraps a custom `NSTextView` (``MacWorkspaceTextEditor``) for proper
/// scrolling and inset behavior the SwiftUI `TextEditor` lacks; on iOS it uses the
/// native `TextEditor`. Both expose the same binding/font/accessibility surface.
struct WorkspaceTextEditor: View {
    /// The edited text.
    @Binding var text: String
    /// Editor font (e.g. monospaced for documents).
    var font: Font = .body
    /// Optional accessibility identifier override.
    var accessibilityIdentifier: String?

    var body: some View {
        // macOS uses an AppKit-backed editor; iOS uses the native TextEditor.
        #if os(macOS)
        MacWorkspaceTextEditor(text: $text)
            .font(font)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier(accessibilityIdentifier ?? "workspace-text-editor")
        #else
        TextEditor(text: $text)
            .font(font)
            .scrollContentBackground(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier(accessibilityIdentifier ?? "workspace-text-editor")
        #endif
    }
}

/// A growing single/multi-line composer used by chat and research follow-ups.
///
/// macOS uses an `NSTextView` (``MacChatComposerField``) so that Return sends and
/// Shift+Return inserts a newline; iOS uses a vertically-growing `TextField` that
/// submits on Return. The `isFocused` binding lets callers drive first responder.
struct ChatComposerField: View {
    /// The in-progress message text.
    @Binding var text: String
    /// Placeholder shown when empty.
    var placeholder: String = "Message"
    /// Invoked when the user submits (Return on macOS, onSubmit on iOS).
    var onSend: () -> Void
    /// External focus binding so parents can focus/blur the composer.
    @FocusState.Binding var isFocused: Bool

    var body: some View {
        // macOS uses an AppKit composer for Return-to-send; iOS uses a TextField.
        #if os(macOS)
        MacChatComposerField(text: $text, placeholder: placeholder, onSend: onSend, isFocused: $isFocused)
            .frame(maxWidth: .infinity, minHeight: 36, maxHeight: 120, alignment: .leading)
            .accessibilityIdentifier("chat-composer")
        #else
        TextField(placeholder, text: $text, axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .lineLimit(1...6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .focused($isFocused)
            .accessibilityIdentifier("chat-composer")
            .onSubmit(onSend)
        #endif
    }
}

// macOS-only AppKit bridges. SwiftUI's TextEditor lacks the scrolling/inset and
// keyboard control these editors need, so they wrap NSTextView directly.
#if os(macOS)
/// AppKit-backed multi-line editor for macOS, synced to a SwiftUI `String` binding.
private struct MacWorkspaceTextEditor: NSViewRepresentable {
    @Binding var text: String

    /// Creates the delegate that mirrors text changes back to the binding.
    func makeCoordinator() -> TextEditorCoordinator {
        TextEditorCoordinator(text: $text)
    }

    /// Builds the scrollable text view and seeds it with the current text.
    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = configureEditorScrollView(NSTextView.scrollableTextView())
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }

        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.string = text
        context.coordinator.textView = textView
        return scrollView
    }

    /// Pushes external binding changes into the text view, avoiding redundant
    /// writes that would disrupt the insertion point.
    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
    }

    /// Bridges `NSTextView` edits back into the SwiftUI binding.
    final class TextEditorCoordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        weak var textView: NSTextView?

        init(text: Binding<String>) {
            _text = text
        }

        /// Mirrors every edit into the bound string.
        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
        }
    }
}

/// AppKit-backed chat composer for macOS that sends on Return (Shift+Return for a
/// newline) and honors the SwiftUI focus binding.
private struct MacChatComposerField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onSend: () -> Void
    @FocusState.Binding var isFocused: Bool

    /// Creates the delegate handling text sync and Return-to-send.
    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, placeholder: placeholder, onSend: onSend)
    }

    /// Builds a bordered, fixed-height text view styled like a composer field.
    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = configureEditorScrollView(NSTextView.scrollableTextView())
        scrollView.borderType = .bezelBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }

        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.minSize = NSSize(width: 0, height: 36)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: 120)
        textView.string = text
        context.coordinator.textView = textView
        return scrollView
    }

    /// Syncs the binding into the view and reconciles first-responder state with
    /// the SwiftUI focus binding.
    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        // Honor the focus binding by promoting the text view to first responder.
        if isFocused, scrollView.window?.firstResponder != textView {
            scrollView.window?.makeFirstResponder(textView)
        }
    }

    /// Bridges edits to the binding and intercepts Return to trigger sending.
    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        let onSend: () -> Void
        weak var textView: NSTextView?

        init(text: Binding<String>, placeholder: String, onSend: @escaping () -> Void) {
            _text = text
            self.onSend = onSend
        }

        /// Mirrors every edit into the bound string.
        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
        }

        /// Intercepts the newline command: Shift+Return inserts a newline (return
        /// `false` to let AppKit handle it), a bare Return sends the message.
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else {
                return false
            }
            if NSEvent.modifierFlags.contains(.shift) {
                return false
            }
            onSend()
            return true
        }
    }
}

/// Shared styling for the AppKit editor scroll views: scrollers, background, and
/// a plain-text, width-tracking, vertically-growing text container.
private func configureEditorScrollView(_ scrollView: NSScrollView) -> NSScrollView {
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.borderType = .noBorder
    scrollView.drawsBackground = true
    scrollView.backgroundColor = .textBackgroundColor
    scrollView.setContentHuggingPriority(.defaultLow, for: .horizontal)
    scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
    scrollView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    scrollView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

    guard let textView = scrollView.documentView as? NSTextView else { return scrollView }

    textView.isRichText = false
    textView.importsGraphics = false
    textView.font = .systemFont(ofSize: NSFont.systemFontSize)
    textView.drawsBackground = true
    textView.backgroundColor = .textBackgroundColor
    textView.textContainerInset = NSSize(width: 12, height: 12)
    textView.textContainer?.lineFragmentPadding = 0
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.containerSize = NSSize(
        width: scrollView.contentSize.width,
        height: CGFloat.greatestFiniteMagnitude
    )
    return scrollView
}
#endif
