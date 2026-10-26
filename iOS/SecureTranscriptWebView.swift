import SwiftUI
import WebKit

/// Each presentation has a private ephemeral cookie jar; it never inherits another account.
struct SecureTranscriptWebView: UIViewRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(origin: url) }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: url))
        return view
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.stopLoading()
        uiView.navigationDelegate = nil
    }
    final class Coordinator: NSObject, WKNavigationDelegate {
        let origin: URL
        init(origin: URL) { self.origin = origin }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let target = action.request.url else { decisionHandler(.cancel); return }
            if Self.sameOrigin(target, origin) { decisionHandler(.allow); return }
            decisionHandler(.cancel)
            if action.navigationType == .linkActivated,
               ["https", "http"].contains(target.scheme?.lowercased() ?? "") {
                UIApplication.shared.open(target)
            }
        }
        static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
            a.scheme?.lowercased() == "https" && b.scheme?.lowercased() == "https" &&
            a.host?.lowercased() == b.host?.lowercased() && (a.port ?? 443) == (b.port ?? 443)
        }
    }
}
