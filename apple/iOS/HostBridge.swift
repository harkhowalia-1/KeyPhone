import UIKit
import WebKit
import PhotosUI
import MessageUI
import SafariServices
import CallKit
import Network
import AudioToolbox

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
    }

    // MARK: status

    @objc func pushStatus() {
        let device = UIDevice.current
        let level = device.batteryLevel < 0 ? 1.0 : Double(device.batteryLevel)
        let charging = device.batteryState == .charging || device.batteryState == .full
        let online = pathMonitor.currentPath.status == .satisfied
        evaluate("window.LarchStatus&&LarchStatus({level:\(level),charging:\(charging),sig:\(online ? 5 : 0),online:\(online)})")
    }

    func appResumed() {
        pushStatus()
        evaluate("window.LarchResume&&LarchResume()")
    }

    // MARK: commands

    override func handlePlatform(_ cmd: String, _ id: Int, _ args: [String: Any]) -> Bool {
        switch cmd {
        case "call": call(id, args["number"] as? String ?? "")
        case "sms": sms(id, to: args["to"] as? [String] ?? [], text: args["text"] as? String ?? "")
        case "pickPhotos": pickPhotos(id)
        case "camera": camera(id)
        case "openUrl": openUrl(id, args["url"] as? String ?? "")
        case "haptic": haptic(id, args["kind"] as? String ?? "light")
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
        guard call.isOutgoing, dialledFromPhone else { return }
        if call.hasConnected && !call.hasEnded && callStart == nil { callStart = Date() }
        if call.hasEnded {
            let seconds = callStart.map { Int(Date().timeIntervalSince($0)) } ?? 0
            callStart = nil
            dialledFromPhone = false
            evaluate("window.LarchCallEnded&&LarchCallEnded({duration:\(seconds)})")
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
