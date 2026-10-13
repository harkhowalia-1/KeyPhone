import SwiftUI
import UIKit
import WebKit

/// Hosts the phone shell (Web/index.html) full screen.
struct PhoneView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> PhoneViewController { PhoneViewController() }
    func updateUIViewController(_ vc: PhoneViewController, context: Context) {}
}

final class PhoneViewController: UIViewController, WKNavigationDelegate {
    private var webView: WKWebView!
    private var bridge: HostBridge!

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let content = WKUserContentController()
        // Saved phone state is handed to the page before its script runs.
        if let state = BridgeBase.savedStateScript() {
            content.addUserScript(WKUserScript(source: state, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        content.addUserScript(WKUserScript(source: BridgeBase.shim(platform: "ios"), injectionTime: .atDocumentStart, forMainFrameOnly: true))

        let config = WKWebViewConfiguration()
        config.userContentController = content
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        webView = WKWebView(frame: view.bounds, configuration: config)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.allowsLinkPreview = false
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.navigationDelegate = self
        view.addSubview(webView)

        bridge = HostBridge(webView: webView, presenter: self)
        content.add(bridge, name: "host")

        if let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Web") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }

        NotificationCenter.default.addObserver(self, selector: #selector(resumed),
                                               name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    @objc private func resumed() { bridge.appResumed() }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        bridge.pushStatus()
    }

    // Links the page opens (tel:, sms:, http) go to iOS rather than replacing the phone.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.allow) }
        if url.isFileURL || url.scheme == "about" || url.scheme == "data" || url.scheme == "blob" {
            return decisionHandler(.allow)
        }
        if action.navigationType == .linkActivated || action.targetFrame == nil {
            UIApplication.shared.open(url)
            return decisionHandler(.cancel)
        }
        decisionHandler(.allow)
    }
}
