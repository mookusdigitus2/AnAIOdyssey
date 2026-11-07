// SPDX-License-Identifier: MIT
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Reusable destructive-delete confirmation, presented on the **window** rather
/// than as a SwiftUI `confirmationDialog`.
///
/// Split views and navigation stacks attach SwiftUI popovers/alerts to a single
/// column (usually the sidebar). Deleting from an album, document, or other
/// detail then hides the confirmation until you navigate back. A window-modal
/// sheet/alert always appears over whatever the user is looking at.
private struct DestructiveDeleteBoolAlertModifier: ViewModifier {
    let title: String
    @Binding var isPresented: Bool
    let message: String
    let confirmAction: () -> Void

    func body(content: Content) -> some View {
        content.background {
            WindowDeleteAlertHost(
                title: title,
                isPresented: $isPresented,
                message: message,
                confirmAction: confirmAction
            )
        }
    }
}

/// Item-driven variant: presents whenever an optional `Item` is non-nil.
private struct DestructiveDeleteItemAlertModifier<Item: Identifiable>: ViewModifier {
    let title: String
    @Binding var item: Item?
    let message: (Item) -> String
    let confirmAction: (Item) -> Void

    func body(content: Content) -> some View {
        content.background {
            WindowDeleteAlertHost(
                title: title,
                isPresented: Binding(
                    get: { item != nil },
                    set: { if !$0 { item = nil } }
                ),
                message: item.map(message) ?? "",
                confirmAction: {
                    guard let item else { return }
                    confirmAction(item)
                }
            )
        }
    }
}

public extension View {
    /// Attaches a `Bool`-driven destructive-delete confirmation.
    func destructiveDeleteAlert(
        _ title: String,
        isPresented: Binding<Bool>,
        message: String,
        confirmAction: @escaping () -> Void
    ) -> some View {
        modifier(DestructiveDeleteBoolAlertModifier(
            title: title,
            isPresented: isPresented,
            message: message,
            confirmAction: confirmAction
        ))
    }

    /// Attaches an item-driven destructive-delete confirmation with per-item copy.
    func destructiveDeleteAlert<Item: Identifiable>(
        _ title: String,
        item: Binding<Item?>,
        message: @escaping (Item) -> String,
        confirmAction: @escaping (Item) -> Void
    ) -> some View {
        modifier(DestructiveDeleteItemAlertModifier(
            title: title,
            item: item,
            message: message,
            confirmAction: confirmAction
        ))
    }
}

// MARK: - Window-modal host

/// Invisible view that presents a native delete confirmation on the key window.
private struct WindowDeleteAlertHost: View {
    let title: String
    @Binding var isPresented: Bool
    let message: String
    let confirmAction: () -> Void

    var body: some View {
        WindowDeleteAlertPresenter(
            title: title,
            isPresented: $isPresented,
            message: message,
            confirmAction: confirmAction
        )
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

#if os(macOS)
private struct WindowDeleteAlertPresenter: NSViewRepresentable {
    let title: String
    @Binding var isPresented: Bool
    let message: String
    let confirmAction: () -> Void

    final class Coordinator {
        var isShowing = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if !isPresented {
            context.coordinator.isShowing = false
            return
        }
        guard !context.coordinator.isShowing else { return }
        guard let window = nsView.window ?? NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible) else {
            return
        }

        context.coordinator.isShowing = true
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        let deleteButton = alert.addButton(withTitle: "Delete")
        deleteButton.hasDestructiveAction = true
        deleteButton.setAccessibilityIdentifier("confirm-delete-button")
        alert.addButton(withTitle: "Cancel")

        alert.beginSheetModal(for: window) { response in
            DispatchQueue.main.async {
                context.coordinator.isShowing = false
                if response == .alertFirstButtonReturn {
                    confirmAction()
                }
                isPresented = false
            }
        }
    }
}
#else
private struct WindowDeleteAlertPresenter: UIViewControllerRepresentable {
    let title: String
    @Binding var isPresented: Bool
    let message: String
    let confirmAction: () -> Void

    final class Coordinator {
        var isShowing = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ host: UIViewController, context: Context) {
        if !isPresented {
            context.coordinator.isShowing = false
            return
        }
        guard !context.coordinator.isShowing else { return }
        guard let presenter = topViewController(from: host) ?? topViewController() else { return }
        guard presenter.presentedViewController == nil else { return }

        context.coordinator.isShowing = true
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        let delete = UIAlertAction(title: "Delete", style: .destructive) { _ in
            DispatchQueue.main.async {
                context.coordinator.isShowing = false
                confirmAction()
                isPresented = false
            }
        }
        alert.addAction(delete)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
            DispatchQueue.main.async {
                context.coordinator.isShowing = false
                isPresented = false
            }
        })
        presenter.present(alert, animated: true)
    }
}

private func topViewController(from base: UIViewController? = nil) -> UIViewController? {
    let root: UIViewController?
    if let base, base.view.window != nil {
        root = base.view.window?.rootViewController ?? base
    } else {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let active = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let window = active?.windows.first { $0.isKeyWindow } ?? active?.windows.first
        root = window?.rootViewController
    }
    return topMost(from: root)
}

private func topMost(from controller: UIViewController?) -> UIViewController? {
    guard let controller else { return nil }
    if let presented = controller.presentedViewController {
        return topMost(from: presented)
    }
    if let nav = controller as? UINavigationController {
        return topMost(from: nav.visibleViewController ?? nav)
    }
    if let tab = controller as? UITabBarController {
        return topMost(from: tab.selectedViewController ?? tab)
    }
    if let split = controller as? UISplitViewController {
        return topMost(from: split.viewControllers.last ?? split)
    }
    return controller
}
#endif
