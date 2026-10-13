import SwiftUI
import WebKit

/// Hosts the phone shell (Web/index.html) in the Mac window.
struct MacPhoneView: NSViewRepresentable {
    func makeCoordinator() -> MacHostBridge { MacHostBridge() }

    func makeNSView(context: Context) -> WKWebView {
        let bridge = context.coordinator
        let content = WKUserContentController()
        if let state = BridgeBase.savedStateScript() {
            content.addUserScript(WKUserScript(source: state, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        content.addUserScript(WKUserScript(source: BridgeBase.shim(platform: "mac"),
                                           injectionTime: .atDocumentStart, forMainFrameOnly: true))
        content.add(bridge, name: "host")

        let config = WKWebViewConfiguration()
        config.userContentController = content
        config.mediaTypesRequiringUserActionForPlayback = []

        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = bridge
        web.uiDelegate = bridge
        web.allowsMagnification = false
        bridge.webView = web

        if let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Web") {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return web
    }

    func updateNSView(_ view: WKWebView, context: Context) {}
}
