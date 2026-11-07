// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import SwiftUI
import WebKit

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Renders an email's HTML body in a `WKWebView` — the standard way to display
/// rich HTML on Apple platforms (SwiftUI has no native HTML renderer).
///
/// Like Apple Mail, **remote content (images, stylesheets, fonts, scripts) is
/// blocked by default** for privacy — loading it would leak that you opened the
/// message (and your IP) to the sender via tracking pixels. When a message
/// references remote resources, a banner offers to load them on demand.
///
/// The view is *self-sizing*: after the content loads it measures the document
/// height via JavaScript and reports it through `contentHeight`, so it can live
/// inside the message's outer `ScrollView` without nested scrolling. Tapped links
/// open in the system browser rather than navigating inside the email.
struct HTMLEmailView: View {
    let html: String
    @State private var contentHeight: CGFloat = 200
    /// Set once the user explicitly approves loading this message's remote content.
    @State private var loadRemoteImages = false

    private var hasRemoteContent: Bool {
        HTMLEmailWebView.containsRemoteContent(html)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if hasRemoteContent && !loadRemoteImages {
                remoteContentBanner
            }
            HTMLEmailWebView(
                html: html,
                blockRemoteContent: !loadRemoteImages,
                contentHeight: $contentHeight
            )
            // Clamp so a not-yet-measured or tiny body still has a usable height.
            .frame(height: max(contentHeight, 80))
        }
    }

    /// Privacy notice + opt-in control, mirroring Mail's "Load Remote Images".
    private var remoteContentBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "eye.slash")
                .foregroundStyle(.secondary)
            Text("Remote images aren't loaded automatically to protect your privacy.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Load Images") { loadRemoteImages = true }
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderless)
                .accessibilityIdentifier("load-remote-images-button")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// The platform `WKWebView` bridge backing ``HTMLEmailView``.
private struct HTMLEmailWebView {
    let html: String
    /// When true, remote (http/https) subresources are blocked at the network layer.
    let blockRemoteContent: Bool
    @Binding var contentHeight: CGFloat

    /// Wraps the raw body so it renders responsively with system-like typography.
    private var document: String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <style>
          :root { color-scheme: light dark; }
          body {
            font: -apple-system-body;
            font-family: -apple-system, "Helvetica Neue", sans-serif;
            margin: 0;
            padding: 0;
            word-wrap: break-word;
            -webkit-text-size-adjust: 100%;
          }
          img, table { max-width: 100% !important; height: auto; }
          pre { white-space: pre-wrap; }
          a { color: -apple-system-blue; }
        </style>
        </head>
        <body>\(html)</body>
        </html>
        """
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// Detects http/https references in image/background/url() positions so the
    /// caller knows whether to surface the "Load Images" banner.
    static func containsRemoteContent(_ html: String) -> Bool {
        let patterns = [
            #"(?i)(?:src|srcset|background|poster)\s*=\s*["']?\s*https?://"#,
            #"(?i)url\(\s*["']?\s*https?://"#
        ]
        return patterns.contains { html.range(of: $0, options: .regularExpression) != nil }
    }

    /// Shared web-view construction for both platforms.
    private func makeWebView(_ context: Context) -> WKWebView {
        #if os(macOS)
        let webView = NonScrollingWebView(frame: .zero, configuration: WKWebViewConfiguration())
        #else
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        #endif
        webView.navigationDelegate = context.coordinator
        // The outer SwiftUI ScrollView handles scrolling; the web view sizes to fit.
        #if os(iOS)
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        #else
        configureMacWebViewScrolling(webView)
        #endif
        return webView
    }

    #if os(macOS)
    /// Disables the embedded `NSScrollView` so wheel/trackpad scrolling reaches the
    /// outer SwiftUI `ScrollView`. `enclosingScrollView` is often nil in `makeNSView`,
    /// so this is also called from `updateNSView` once the hierarchy is wired up.
    private func configureMacWebViewScrolling(_ webView: WKWebView) {
        guard let scrollView = webView.enclosingScrollView else { return }
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none
        scrollView.autohidesScrollers = true
    }
    #endif

    /// Reloads only when the HTML or the blocking policy actually changes.
    private func loadIfNeeded(_ webView: WKWebView, _ context: Context) {
        context.coordinator.parent = self
        let key = "\(blockRemoteContent)|\(html.hashValue)"
        guard context.coordinator.loadedKey != key else { return }
        context.coordinator.loadedKey = key
        context.coordinator.load(into: webView, html: document, block: blockRemoteContent)
    }

    /// Bridges `WKNavigationDelegate` callbacks back into SwiftUI state and owns
    /// the compiled remote-content blocking rule list.
    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: HTMLEmailWebView
        var loadedKey: String?
        private var ruleList: WKContentRuleList?

        init(_ parent: HTMLEmailWebView) {
            self.parent = parent
        }

        /// Applies (or removes) the remote-content block, then loads the document.
        func load(into webView: WKWebView, html: String, block: Bool) {
            let controller = webView.configuration.userContentController
            controller.removeAllContentRuleLists()

            guard block else {
                webView.loadHTMLString(html, baseURL: nil)
                return
            }

            if let ruleList {
                controller.add(ruleList)
                webView.loadHTMLString(html, baseURL: nil)
                return
            }

            compileRuleList { [weak webView] list in
                guard let webView else { return }
                self.ruleList = list
                if let list {
                    webView.configuration.userContentController.add(list)
                    webView.loadHTMLString(html, baseURL: nil)
                } else {
                    // Compilation failed: fall back to stripping remote refs from
                    // the markup so nothing remote loads without approval.
                    webView.loadHTMLString(Coordinator.sanitizeRemote(html), baseURL: nil)
                }
            }
        }

        /// Compiles a content rule that blocks remote (http/https) subresources;
        /// inline `data:`/`cid:` content is unaffected.
        private func compileRuleList(_ completion: @escaping (WKContentRuleList?) -> Void) {
            let rules = """
            [{"trigger":{"url-filter":"^https?://","resource-type":["image","style-sheet","media","font","raw","script","svg-document"]},"action":{"type":"block"}}]
            """
            guard let store = WKContentRuleListStore.default() else {
                completion(nil)
                return
            }
            store.compileContentRuleList(
                forIdentifier: "AnAIOdysseyEmailRemoteContentBlock",
                encodedContentRuleList: rules
            ) { list, _ in
                DispatchQueue.main.async { completion(list) }
            }
        }

        /// Regex fallback that neutralizes remote resource references in markup.
        static func sanitizeRemote(_ html: String) -> String {
            var output = html
            output = output.replacingOccurrences(
                of: #"(?i)(src|srcset|background|poster)\s*=\s*(["'])\s*https?://[^"']*\2"#,
                with: "$1=$2$2",
                options: .regularExpression
            )
            output = output.replacingOccurrences(
                of: #"(?i)url\(\s*['"]?\s*https?://[^)]*\)"#,
                with: "url()",
                options: .regularExpression
            )
            return output
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            measureContentHeight(in: webView)
            // Remote images and late layout can change height after the first pass.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self, weak webView] in
                guard let self, let webView else { return }
                self.measureContentHeight(in: webView)
            }
        }

        /// Measures the rendered document height and reports it through the binding.
        private func measureContentHeight(in webView: WKWebView) {
            let script = """
            Math.max(
              document.body.scrollHeight,
              document.documentElement.scrollHeight
            )
            """
            webView.evaluateJavaScript(script) { [weak self] value, _ in
                guard let self, let number = value as? NSNumber else { return }
                let height = CGFloat(truncating: number)
                guard height > 0 else { return }
                DispatchQueue.main.async {
                    self.parent.contentHeight = height
                }
            }
        }

        // Open user-tapped links externally instead of replacing the message body.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                #if os(macOS)
                NSWorkspace.shared.open(url)
                #else
                UIApplication.shared.open(url)
                #endif
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}

#if os(macOS)
/// Forwards scroll-wheel events to the outer SwiftUI `ScrollView` instead of the
/// web view's internal `NSScrollView` (which would swallow them when scrollbars
/// are hidden).
private final class NonScrollingWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}

extension HTMLEmailWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeWebView(context) }
    func updateNSView(_ webView: WKWebView, context: Context) {
        configureMacWebViewScrolling(webView)
        loadIfNeeded(webView, context)
    }
}
#else
extension HTMLEmailWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWebView(context) }
    func updateUIView(_ webView: WKWebView, context: Context) { loadIfNeeded(webView, context) }
}
#endif
