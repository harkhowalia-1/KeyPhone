import UIKit
import WebKit
import PhotosUI
import MessageUI
import SafariServices
import CallKit
import Network
import AudioToolbox
import AVFoundation

/// iPhone side of the bridge: real calls, the Messages sheet, Photos, camera,
/// Safari, vibration, and battery/network status. Contacts, notifications and
/// saving live in BridgeBase.
final class HostBridge: BridgeBase {

    private weak var presenter: UIViewController?
    private let callObserver = CXCallObserver()
    private let pathMonitor = NWPathMonitor()
    private let tap = UIImpactFeedbackGenerator(style: .light)

    private var smsReply: Int?
    private var photoReply: Int?
    private var cameraReply: Int?
    private var dialledFromPhone = false
    private var callStart: Date?
    /// Calls the iPhone receives while the app runs: when each began and connected.
    /// iOS never tells apps the caller's number, so only times are logged.
    private var incoming: [UUID: (start: Date, connected: Date?)] = [:]
    private var overlay: WKWebView?
    private var statusTimer: Timer?
    private lazy var appleMusic = AppleMusic(bridge: self)
    private let silentSwitch = SilentSwitch()

    init(webView: WKWebView, presenter: UIViewController) {
        self.presenter = presenter
        super.init()
        self.webView = webView
        callObserver.setDelegate(self, queue: .main)
        UIDevice.current.isBatteryMonitoringEnabled = true
        NotificationCenter.default.addObserver(self, selector: #selector(pushStatus),
                                               name: UIDevice.batteryLevelDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(pushStatus),
                                               name: UIDevice.batteryStateDidChangeNotification, object: nil)
        pathMonitor.pathUpdateHandler = { [weak self] _ in DispatchQueue.main.async { self?.pushStatus() } }
        pathMonitor.start(queue: DispatchQueue.global(qos: .utility))
        tap.prepare()
        // Phone sounds follow the silent switch until music, radio or an alarm needs to be heard.
        try? AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default)
        // iOS posts battery changes in steps, so the level is also re-read regularly.
        statusTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.pushStatus() }
        silentSwitch.onChange = { [weak self] silent in self?.evaluate("window.LarchSilent&&LarchSilent(\(silent))") }
        silentSwitch.start()
    }

    deinit { statusTimer?.invalidate() }

    // MARK: status

    @objc func pushStatus() {
        let device = UIDevice.current
        let path = pathMonitor.currentPath
        var parts = ["online:\(path.status == .satisfied)", "net:'\(BridgeBase.netType(path))'"]
        if device.batteryLevel >= 0 {
            parts.append("level:\(Double(device.batteryLevel))")
            parts.append("charging:\(device.batteryState == .charging || device.batteryState == .full)")
        }
        // iOS gives apps no signal strength, so no bars are sent.
        evaluate("window.LarchStatus&&LarchStatus({\(parts.joined(separator: ","))})")
        if let silent = silentSwitch.silent { evaluate("window.LarchSilent&&LarchSilent(\(silent))") }
    }

    func appResumed() {
        pushStatus()
        silentSwitch.start()
        evaluate("window.LarchResume&&LarchResume()")
    }

    func appPaused() { silentSwitch.stop() }

    // MARK: commands

    override func handlePlatform(_ cmd: String, _ id: Int, _ args: [String: Any]) -> Bool {
        switch cmd {
        case "call": call(id, args["number"] as? String ?? "")
        case "sms": sms(id, to: args["to"] as? [String] ?? [], text: args["text"] as? String ?? "")
        case "pickPhotos": pickPhotos(id)
        case "camera": camera(id)
        case "openUrl": openUrl(id, args["url"] as? String ?? "")
        case "haptic": haptic(id, args["kind"] as? String ?? "light")
        case "web": web(id, args)
        case "saveFile": saveFile(id, args["name"] as? String ?? "KeyPhone backup.json", args["text"] as? String ?? "")
        case "audioSession": audioSession(id, (args["on"] as? Bool) ?? false)
        case "audioRoute":
            try? AVAudioSession.sharedInstance().overrideOutputAudioPort((args["speaker"] as? Bool) == true ? .speaker : .none)
            reply(id, true)
        case "torch": torch(id, (args["on"] as? Bool) ?? false)
        case "music": DispatchQueue.main.async { self.appleMusic.handle(id, args) }
        default: return false
        }
        return true
    }

    private func call(_ id: Int, _ number: String) {
        let allowed = Set("+0123456789")
        let digits = String(number.filter { allowed.contains($0) })
        guard !digits.isEmpty, let url = URL(string: "tel://" + digits) else {
            return reply(id, "This number can't be dialled from iPhone", ok: false)
        }
        dialledFromPhone = true
        UIApplication.shared.open(url) { success in
            if !success { self.dialledFromPhone = false }
            self.reply(id, success, ok: success)
        }
    }

    private func sms(_ id: Int, to: [String], text: String) {
        guard MFMessageComposeViewController.canSendText() else {
            return reply(id, "This iPhone can't send messages", ok: false)
        }
        let compose = MFMessageComposeViewController()
        compose.recipients = to
        compose.body = text
        compose.messageComposeDelegate = self
        smsReply = id
        presenter?.present(compose, animated: true)
    }

    private func pickPhotos(_ id: Int) {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 0
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        photoReply = id
        presenter?.present(picker, animated: true)
    }

    private func camera(_ id: Int) {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            return reply(id, "No camera", ok: false)
        }
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = self
        cameraReply = id
        presenter?.present(picker, animated: true)
    }

    private func openUrl(_ id: Int, _ string: String) {
        guard let url = URL(string: string), url.scheme == "http" || url.scheme == "https" else {
            return reply(id, "Invalid address", ok: false)
        }
        let safari = SFSafariViewController(url: url)
        safari.dismissButtonStyle = .close
        presenter?.present(safari, animated: true)
        reply(id, true)
    }

    private func haptic(_ id: Int, _ kind: String) {
        if kind == "vibrate" {
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        } else {
            tap.impactOccurred()
            tap.prepare()
        }
        reply(id, true)
    }

    // MARK: files and sound

    /// Saves a file (a phone backup) through the share sheet: Save to Files, AirDrop and so on.
    private func saveFile(_ id: Int, _ name: String, _ text: String) {
        let safe = name.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(safe)
        do { try Data(text.utf8).write(to: url, options: .atomic) } catch {
            return reply(id, error.localizedDescription, ok: false)
        }
        guard let presenter = presenter else { return reply(id, "No window", ok: false) }
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        sheet.completionWithItemsHandler = { [weak self] _, completed, _, _ in self?.reply(id, completed) }
        if let pop = sheet.popoverPresentationController {
            pop.sourceView = presenter.view
            pop.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
        }
        (presenter.presentedViewController ?? presenter).present(sheet, animated: true)
    }

    /// The camera's light as a torch.
    private func torch(_ id: Int, _ on: Bool) {
        guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else { return reply(id, "No torch on this iPhone", ok: false) }
        do {
            try device.lockForConfiguration()
            if on { try device.setTorchModeOn(level: 1.0) } else { device.torchMode = .off }
            device.unlockForConfiguration()
            reply(id, on)
        } catch { reply(id, error.localizedDescription, ok: false) }
    }

    /// While the radio or music player is playing, sound keeps going with the
    /// screen locked or another app open, like a phone's radio.
    private func audioSession(_ id: Int, _ on: Bool) {
        let session = AVAudioSession.sharedInstance()
        if on {
            try? session.setCategory(.playback, mode: .default)
            try? session.setActive(true)
        } else {
            try? session.setCategory(.ambient, mode: .default)
        }
        reply(id, true)
    }

    // MARK: web pages shown on the phone's own screen

    private func makeOverlay() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        let view = WKWebView(frame: .zero, configuration: config)
        view.customUserAgent = BridgeBase.mobileUserAgent
        view.pageZoom = 0.8
        view.allowsBackForwardNavigationGestures = true
        view.backgroundColor = .white
        view.navigationDelegate = self
        view.uiDelegate = self
        webView?.addSubview(view)
        overlay = view
        return view
    }

    private func web(_ id: Int, _ a: [String: Any]) {
        switch a["op"] as? String ?? "" {
        case "show":
            let view = overlay ?? makeOverlay()
            if let r = a["rect"] as? [String: Any] {
                let n = { (k: String) in CGFloat((r[k] as? NSNumber)?.doubleValue ?? 0) }
                view.frame = CGRect(x: n("x"), y: n("y"), width: n("w"), height: n("h"))
            }
            view.isHidden = false
            if let s = a["url"] as? String, let url = URL(string: s) { applyWebPrefs(view, a) { view.load(URLRequest(url: url)) } }
        case "load":
            let view = overlay ?? makeOverlay()
            if let s = a["url"] as? String, let url = URL(string: s) { applyWebPrefs(view, a) { view.load(URLRequest(url: url)) } }
        case "prefs":
            if let view = overlay { applyWebPrefs(view, a) }
        case "clear":
            return clearWebData(id, a["what"] as? String ?? "cache")
        case "hide": overlay?.isHidden = true
        case "close":
            overlay?.stopLoading()
            overlay?.removeFromSuperview()
            overlay = nil
        case "back": overlay?.goBack()
        case "forward": overlay?.goForward()
        case "reload": overlay?.reload()
        case "scroll":
            let dy = (a["dy"] as? NSNumber)?.doubleValue ?? 0
            overlay?.evaluateJavaScript("window.scrollBy({top:\(dy),behavior:'smooth'})")
        default: break
        }
        reply(id, true)
    }

    fileprivate static func dataURL(_ image: UIImage) -> String? {
        let maxSide: CGFloat = 960
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let jpeg = resized.jpegData(compressionQuality: 0.82) else { return nil }
        return "data:image/jpeg;base64," + jpeg.base64EncodedString()
    }

    fileprivate static func photoName() -> String {
        let f = DateFormatter()
        f.dateFormat = "dd-MM-yyyy HH.mm"
        return "Photo " + f.string(from: Date())
    }
}

// MARK: - Delegates

extension HostBridge: CXCallObserverDelegate {
    func callObserver(_ observer: CXCallObserver, callChanged call: CXCall) {
        if !call.isOutgoing { return incomingChanged(call) }
        guard dialledFromPhone else { return }
        if call.hasConnected && !call.hasEnded && callStart == nil { callStart = Date() }
        if call.hasEnded {
            let seconds = callStart.map { Int(Date().timeIntervalSince($0)) } ?? 0
            callStart = nil
            dialledFromPhone = false
            evaluate("window.LarchCallEnded&&LarchCallEnded({duration:\(seconds)})")
        }
    }

    private func incomingChanged(_ call: CXCall) {
        var entry = incoming[call.uuid] ?? (start: Date(), connected: nil)
        if call.hasConnected && entry.connected == nil { entry.connected = Date() }
        guard call.hasEnded else { incoming[call.uuid] = entry; return }
        incoming[call.uuid] = nil
        let t = Int(entry.start.timeIntervalSince1970 * 1000)
        if let connected = entry.connected {
            let seconds = Int(Date().timeIntervalSince(connected))
            evaluate("window.LarchCallIn&&LarchCallIn({t:\(t),duration:\(seconds)})")
        } else {
            evaluate("window.LarchCallMissed&&LarchCallMissed({t:\(t)})")
        }
    }
}

extension HostBridge: MFMessageComposeViewControllerDelegate {
    func messageComposeViewController(_ controller: MFMessageComposeViewController,
                                      didFinishWith result: MessageComposeResult) {
        controller.dismiss(animated: true)
        guard let id = smsReply else { return }
        smsReply = nil
        switch result {
        case .sent: reply(id, "sent")
        case .cancelled: reply(id, "cancelled")
        default: reply(id, "failed")
        }
    }
}

extension HostBridge: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let id = photoReply else { return }
        photoReply = nil
        let group = DispatchGroup()
        let lock = NSLock()
        var photos: [(Int, [String: Any])] = []
        for (index, result) in results.enumerated() {
            let provider = result.itemProvider
            guard provider.canLoadObject(ofClass: UIImage.self) else { continue }
            group.enter()
            provider.loadObject(ofClass: UIImage.self) { object, _ in
                defer { group.leave() }
                guard let image = object as? UIImage, let url = HostBridge.dataURL(image) else { return }
                let name = provider.suggestedName ?? HostBridge.photoName()
                lock.lock(); photos.append((index, ["name": name, "data": url])); lock.unlock()
            }
        }
        group.notify(queue: .main) {
            self.reply(id, photos.sorted { $0.0 < $1.0 }.map { $0.1 })
        }
    }
}

extension HostBridge: UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    func imagePickerController(_ picker: UIImagePickerController,
                               didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        picker.dismiss(animated: true)
        guard let id = cameraReply else { return }
        cameraReply = nil
        if let image = info[.originalImage] as? UIImage, let url = HostBridge.dataURL(image) {
            reply(id, ["name": HostBridge.photoName(), "data": url])
        } else {
            reply(id, nil)
        }
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
        if let id = cameraReply { cameraReply = nil; reply(id, nil) }
    }
}

extension HostBridge: WKNavigationDelegate, WKUIDelegate {
    func webView(_ view: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { webState(view) }
    func webView(_ view: WKWebView, didCommit navigation: WKNavigation!) { webState(view) }
    func webView(_ view: WKWebView, didFinish navigation: WKNavigation!) { webState(view) }
    func webView(_ view: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { webState(view) }
    func webView(_ view: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { webState(view) }

    func webView(_ view: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = action.request.url, let scheme = url.scheme?.lowercased(),
           !["http", "https", "about", "data", "blob"].contains(scheme) {
            UIApplication.shared.open(url)   // tel:, mailto:, maps and so on
            return decisionHandler(.cancel)
        }
        if let url = action.request.url, BridgeBase.isJavaApp(url: url) {
            offerInstall(url)
            return decisionHandler(.cancel)
        }
        decisionHandler(.allow)
    }

    func webView(_ view: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let url = response.response.url, BridgeBase.isJavaApp(url: url, mimeType: response.response.mimeType) {
            offerInstall(url)
            return decisionHandler(.cancel)
        }
        decisionHandler(.allow)
    }

    func webView(_ view: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil { view.load(action.request) }
        return nil
    }
}
