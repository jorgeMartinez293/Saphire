import SwiftUI
import WebKit
import AppKit

/// WKWebView that renders a list of chat messages as Markdown + LaTeX.
/// Rendering happens in chat.html (marked.js + MathJax SVG).
struct ChatWebView: NSViewRepresentable {
    var messages: [ChatMessage]
    var compact: Bool = false
    /// Per-bubble actions wired from the HTML back into AppState. nil hides the
    /// buttons (e.g. the compact overlay).
    var onRegenerate: ((String) -> Void)? = nil
    var onEdit: ((String) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "saphire")
        let web = WKWebView(frame: .zero, configuration: config)
        web.setValue(false, forKey: "drawsBackground") // transparent
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        context.coordinator.web = web

        if let url = Bundle.main.url(forResource: "chat", withExtension: "html", subdirectory: "web")
            ?? Bundle.main.url(forResource: "chat", withExtension: "html") {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        context.coordinator.onRegenerate = onRegenerate
        context.coordinator.onEdit = onEdit
        context.coordinator.actionsEnabled = onRegenerate != nil || onEdit != nil
        context.coordinator.pending = (messages, compact)
        context.coordinator.flush()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        weak var web: WKWebView?
        var loaded = false
        var pending: ([ChatMessage], Bool)?
        var onRegenerate: ((String) -> Void)?
        var onEdit: ((String) -> Void)?
        var actionsEnabled = false
        /// Signature of the last payload pushed to JS. updateNSView fires on
        /// every @Published change in AppState (each input keystroke, voice
        /// levels at audio rate, tool activity…), and each flush re-serializes
        /// the whole transcript — base64 images included — and runs JS. Skip it
        /// when the messages haven't actually changed.
        private var renderedSig: Int? = nil

        // JS -> Swift: a per-bubble Repetir / Editar button was clicked.
        func userContentController(_ uc: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let action = body["action"] as? String,
                  let id = body["id"] as? String else { return }
            switch action {
            case "regenerate": onRegenerate?(id)
            case "edit": onEdit?(id)
            default: break
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            flush()
        }

        // Link clicks must NOT navigate the chat webview (would replace chat
        // with an in-app browser, no way back). Open externally instead.
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        // target="_blank" / window.open links request a new webview; open in the
        // system browser and refuse the new view.
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
            }
            return nil
        }

        func flush() {
            guard loaded, let web, let (messages, compact) = pending else { return }
            // Cheap change detection: content/thinking only ever grow in place
            // during streaming (utf8.count is O(1) on native strings); any other
            // edit replaces messages, changing ids or the count.
            var hasher = Hasher()
            hasher.combine(compact)
            hasher.combine(actionsEnabled)
            hasher.combine(messages.count)
            for m in messages {
                hasher.combine(m.id)
                hasher.combine(m.content.utf8.count)
                hasher.combine(m.thinking?.utf8.count ?? -1)
                hasher.combine(m.attachments.count)
            }
            let sig = hasher.finalize()
            if sig == renderedSig { return }
            let payload = messages.map { m -> [String: Any] in
                [
                    "id": m.id.uuidString,
                    "role": m.role.rawValue,
                    "content": m.content,
                    "thinking": m.thinking ?? "",
                    "images": m.attachments.map(\.dataURL)
                ]
            }
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let json = String(data: data, encoding: .utf8) else { return }
            web.evaluateJavaScript("window.renderMessages(\(json), \(compact), \(actionsEnabled));",
                                   completionHandler: nil)
            renderedSig = sig
        }
    }
}
