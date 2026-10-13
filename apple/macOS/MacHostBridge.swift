import AppKit
import WebKit
import Network
import IOKit.ps
import CoreWLAN
import UniformTypeIdentifiers

/// Mac side of the bridge: calls through FaceTime (or your iPhone), Messages,
/// picking images, the default browser, file panels, and battery/Wi-Fi status.
/// Contacts, notifications and saving live in BridgeBase.
final class MacHostBridge: BridgeBase, WKNavigationDelegate, WKUIDelegate {

    private let pathMonitor = NWPathMonitor()
    private var statusTimer: Timer?

    override init() {
        super.init()
        pathMonitor.pathUpdateHandler = { [weak self] _ in DispatchQueue.main.async { self?.pushStatus() } }
        pathMonitor.start(queue: DispatchQueue.global(qos: .utility))
        statusTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.pushStatus() }
    }

    deinit { statusTimer?.invalidate() }

    // MARK: status

    func pushStatus() {
        let online = pathMonitor.currentPath.status == .satisfied
        var signal = online ? 5 : 0
        if online, pathMonitor.currentPath.usesInterfaceType(.wifi),
           let rssi = CWWiFiClient.shared().interface()?.rssiValue(), rssi != 0 {
            signal = rssi > -55 ? 5 : rssi > -65 ? 4 : rssi > -72 ? 3 : rssi > -80 ? 2 : 1
        }
        var parts = ["sig:\(signal)", "online:\(online)"]
        if let battery = Self.battery() {
            parts.append("level:\(battery.level)")
            parts.append("charging:\(battery.charging)")
        }
        evaluate("window.LarchStatus&&LarchStatus({\(parts.joined(separator: ","))})")
    }

    private static func battery() -> (level: Double, charging: Bool)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let current = d[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = d[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            let charging = (d[kIOPSIsChargingKey] as? Bool) ?? false
            let onPower = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            return (Double(current) / Double(maximum), charging || onPower)
        }
        return nil
    }

    // MARK: commands

    override func handlePlatform(_ cmd: String, _ id: Int, _ args: [String: Any]) -> Bool {
        switch cmd {
        case "call": call(id, args["number"] as? String ?? "")
        case "sms": sms(id, to: args["to"] as? [String] ?? [], text: args["text"] as? String ?? "")
        case "pickPhotos": pickPhotos(id)
        case "camera": reply(id, "No camera on this Mac build", ok: false)
        case "openUrl": openUrl(id, args["url"] as? String ?? "")
        case "haptic":
            if (args["kind"] as? String) == "vibrate" {
                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            }
            reply(id, true)
        default: return false
        }
        return true
    }

    /// FaceTime places the call, through your iPhone when "Calls from iPhone" is on.
    private func call(_ id: Int, _ number: String) {
        let allowed = Set("+0123456789")
        let digits = String(number.filter { allowed.contains($0) })
        guard !digits.isEmpty, let url = URL(string: "tel:" + digits) else {
            return reply(id, "This number can't be dialled", ok: false)
        }
        reply(id, NSWorkspace.shared.open(url))
    }

    /// Opens Messages with the recipients and text filled in.
    private func sms(_ id: Int, to: [String], text: String) {
        let allowed = Set("+0123456789")
        let numbers = to.map { String($0.filter { allowed.contains($0) }) }.filter { !$0.isEmpty }
        var components = URLComponents()
        components.scheme = "sms"
        components.path = numbers.joined(separator: ",")
        components.queryItems = [URLQueryItem(name: "body", value: text)]
        guard let url = components.url, NSWorkspace.shared.open(url) else {
            return reply(id, "failed")
        }
        reply(id, "opened")
    }

    private func pickPhotos(_ id: Int) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.message = "Choose images for the phone's Gallery"
        panel.begin { result in
            guard result == .OK else { return self.reply(id, []) }
            DispatchQueue.global(qos: .userInitiated).async {
                let photos: [[String: Any]] = panel.urls.compactMap { url in
                    guard let image = NSImage(contentsOf: url), let data = Self.dataURL(image) else { return nil }
                    return ["name": url.deletingPathExtension().lastPathComponent, "data": data]
                }
                self.reply(id, photos)
            }
        }
    }

    private static func dataURL(_ image: NSImage) -> String? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let maxSide: CGFloat = 960
        let scale = min(1, maxSide / CGFloat(max(cg.width, cg.height)))
        let width = Int(CGFloat(cg.width) * scale), height = Int(CGFloat(cg.height) * scale)
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = ctx.makeImage(),
              let jpeg = NSBitmapImageRep(cgImage: scaled).representation(using: .jpeg, properties: [.compressionFactor: 0.82])
        else { return nil }
        return "data:image/jpeg;base64," + jpeg.base64EncodedString()
    }

    private func openUrl(_ id: Int, _ string: String) {
        guard let url = URL(string: string), url.scheme == "http" || url.scheme == "https" else {
            return reply(id, "Invalid address", ok: false)
        }
        reply(id, NSWorkspace.shared.open(url))
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pushStatus()
        webView.window?.makeFirstResponder(webView)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.allow) }
        if url.isFileURL || url.scheme == "about" || url.scheme == "data" || url.scheme == "blob" {
            return decisionHandler(.allow)
        }
        if action.navigationType == .linkActivated || action.targetFrame == nil {
            NSWorkspace.shared.open(url)
            return decisionHandler(.cancel)
        }
        decisionHandler(.allow)
    }

    // MARK: WKUIDelegate — "Add files" and other file inputs

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = false
        panel.begin { result in completionHandler(result == .OK ? panel.urls : nil) }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url { NSWorkspace.shared.open(url) }
        return nil
    }
}
