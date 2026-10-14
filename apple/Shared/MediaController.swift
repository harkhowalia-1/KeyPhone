import Foundation
import AVFoundation
import Photos
import ImageIO
import WebKit
#if os(iOS)
import UIKit
typealias PlatformImage = UIImage
typealias PlatformView = UIView
#else
import AppKit
typealias PlatformImage = NSImage
typealias PlatformView = NSView
#endif

/// The phone's camera, video player, voice recorder and photo library, on both
/// iPhone and Mac. Pictures and video show in a view placed over the phone's
/// screen; photos and videos it takes go into the device's Photos library, and
/// voice recordings are kept as .m4a files with the phone's data.
final class MediaController: NSObject {

    private weak var bridge: BridgeBase?
    private var overlay: PlatformView?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var playerLayer: AVPlayerLayer?
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    private let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var front = false
    /// Photo mode uses the camera's full-quality still format; video mode adds the movie output and microphone.
    private var photoMode = true
    /// Width ÷ height of the viewfinder on the phone's screen; photos are cropped to match it.
    private var viewAspect: CGFloat = 0
    private let cameraQueue = DispatchQueue(label: "larch.camera")
    private var photoReply: Int?
    private var movieReply: Int?

    private var recorder: AVAudioRecorder?
    private var recorderName = ""

    init(bridge: BridgeBase) {
        self.bridge = bridge
        super.init()
    }

    private func reply(_ id: Int, _ value: Any? = nil, ok: Bool = true) { bridge?.reply(id, value, ok: ok) }
    private func num(_ a: [String: Any], _ k: String, _ d: Double = 0) -> Double { (a[k] as? NSNumber)?.doubleValue ?? d }

    // MARK: entry point from the bridge

    func handle(_ cmd: String, _ id: Int, _ a: [String: Any]) {
        let op = a["op"] as? String ?? ""
        switch (cmd, op) {
        case ("media", "camera"): cameraShow(id, a)
        case ("media", "rect"): DispatchQueue.main.async { self.place(a["rect"] as? [String: Any]); self.reply(id, true) }
        case ("media", "mode"):
            photoMode = (a["mode"] as? String) != "video"
            cameraQueue.async { self.configure(); self.reply(id, true) }
        case ("media", "flip"): front.toggle(); cameraQueue.async { self.configure(); self.reply(id, true) }
        case ("media", "capture"): capture(id)
        case ("media", "recordVideo"): videoStart(id)
        case ("media", "stopVideo"): videoStop(id)
        case ("media", "play"): play(id, a)
        case ("media", "pause"): DispatchQueue.main.async { self.player?.pause(); self.reply(id, true) }
        case ("media", "resume"): DispatchQueue.main.async { self.player?.play(); self.reply(id, true) }
        case ("media", "seek"): seek(id, by: num(a, "by"))
        case ("media", "hide"): DispatchQueue.main.async { self.overlay?.isHidden = true; self.reply(id, true) }
        case ("media", "close"): DispatchQueue.main.async { self.close(); self.reply(id, true) }
        case ("library", "list"): libraryList(id, video: (a["kind"] as? String) == "video",
                                              offset: Int(num(a, "offset")), limit: Int(num(a, "limit", 30)), thumb: Int(num(a, "thumb", 160)))
        case ("library", "get"): libraryGet(id, a["id"] as? String ?? "", max: Int(num(a, "max", 960)))
        case ("library", "delete"): libraryDelete(id, a["id"] as? String ?? "")
        case ("audio", "start"): recStart(id)
        case ("audio", "pause"): recorder?.pause(); reply(id, true)
        case ("audio", "resume"): recorder?.record(); reply(id, true)
        case ("audio", "stop"): recStop(id)
        case ("audio", "level"): recLevel(id)
        case ("audio", "list"): recList(id)
        case ("audio", "get"): recGet(id, a["id"] as? String ?? "")
        case ("audio", "delete"): recDelete(id, a["id"] as? String ?? "")
        default: reply(id, "Not available", ok: false)
        }
    }

    // MARK: the view over the phone's screen

    private func addLayer(_ layer: CALayer, to view: PlatformView) {
        #if os(macOS)
        view.wantsLayer = true
        view.layer?.addSublayer(layer)
        #else
        view.layer.addSublayer(layer)
        #endif
    }

    @discardableResult
    private func place(_ rect: [String: Any]?) -> PlatformView? {
        guard let host = bridge?.webView else { return nil }
        let view: PlatformView
        if let existing = overlay {
            view = existing
        } else {
            view = PlatformView()
            #if os(macOS)
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.black.cgColor
            #else
            view.backgroundColor = .black
            view.isUserInteractionEnabled = false
            #endif
            host.addSubview(view)
            overlay = view
        }
        if let r = rect {
            let x = CGFloat(num(r, "x")), y = CGFloat(num(r, "y")), w = CGFloat(num(r, "w")), h = CGFloat(num(r, "h"))
            #if os(macOS)
            view.frame = CGRect(x: x, y: host.isFlipped ? y : host.bounds.height - y - h, width: w, height: h)
            #else
            view.frame = CGRect(x: x, y: y, width: w, height: h)
            #endif
        }
        view.isHidden = false
        if view.bounds.width > 0, view.bounds.height > 0 { viewAspect = view.bounds.width / view.bounds.height }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer?.frame = view.bounds
        playerLayer?.frame = view.bounds
        CATransaction.commit()
        return view
    }

    private func close() {
        stopPlayer()
        cameraQueue.async { if self.session.isRunning { self.session.stopRunning() } }
        previewLayer?.removeFromSuperlayer(); previewLayer = nil
        playerLayer?.removeFromSuperlayer(); playerLayer = nil
        overlay?.removeFromSuperview(); overlay = nil
    }

    // MARK: permissions

    private func access(_ type: AVMediaType, _ done: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized: done(true)
        case .notDetermined: AVCaptureDevice.requestAccess(for: type) { done($0) }
        default: done(false)
        }
    }

    private func withLibrary(_ done: @escaping (Bool) -> Void) {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .authorized || status == .limited { return done(true) }
        if status != .notDetermined { return done(false) }
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { s in done(s == .authorized || s == .limited) }
    }

    // MARK: camera

    private func configure() {
        session.beginConfiguration()
        let preset: AVCaptureSession.Preset = photoMode ? .photo : .high
        if session.canSetSessionPreset(preset) { session.sessionPreset = preset }
        if let old = videoInput { session.removeInput(old); videoInput = nil }
        #if os(iOS)
        let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: front ? .front : .back)
            ?? AVCaptureDevice.default(for: .video)
        #else
        let device = AVCaptureDevice.default(for: .video)
        #endif
        if let d = device, let input = try? AVCaptureDeviceInput(device: d), session.canAddInput(input) {
            session.addInput(input)
            videoInput = input
        }
        if photoMode {
            if let mic = audioInput { session.removeInput(mic); audioInput = nil }
            if session.outputs.contains(movieOutput), !movieOutput.isRecording { session.removeOutput(movieOutput) }
        }
        if !photoMode, audioInput == nil, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
           let mic = AVCaptureDevice.default(for: .audio), let input = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(input) {
            session.addInput(input)
            audioInput = input
        }
        if !session.outputs.contains(photoOutput), session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        if !photoMode, !session.outputs.contains(movieOutput), session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }
        #if os(iOS)
        // The phone is held upright, so pictures and video are recorded upright too.
        for output in [photoOutput, movieOutput] as [AVCaptureOutput] {
            if let connection = output.connection(with: .video) { Self.upright(connection) }
        }
        #endif
        session.commitConfiguration()
    }

    #if os(iOS)
    private static func upright(_ connection: AVCaptureConnection) {
        if #available(iOS 17.0, *) {
            if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
        } else if connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }
    }
    #endif

    private func cameraShow(_ id: Int, _ a: [String: Any]) {
        access(.video) { granted in
            guard granted else { return self.reply(id, "Camera access is off. Turn it on in Settings › Privacy › Camera.", ok: false) }
            DispatchQueue.main.async {
                self.stopPlayer()
                guard let view = self.place(a["rect"] as? [String: Any]) else { return self.reply(id, "No screen", ok: false) }
                if self.previewLayer == nil {
                    let layer = AVCaptureVideoPreviewLayer(session: self.session)
                    layer.videoGravity = .resizeAspectFill
                    layer.frame = view.bounds
                    self.addLayer(layer, to: view)
                    self.previewLayer = layer
                }
                self.photoMode = (a["mode"] as? String) != "video"
                self.cameraQueue.async {
                    self.configure()
                    if !self.session.isRunning { self.session.startRunning() }
                    self.reply(id, true)
                }
            }
        }
    }

    private func capture(_ id: Int) {
        cameraQueue.async {
            guard self.session.isRunning, self.session.outputs.contains(self.photoOutput) else {
                return self.reply(id, "Camera not ready", ok: false)
            }
            self.photoReply = id
            self.photoOutput.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
        }
    }

    private func videoStart(_ id: Int) {
        access(.audio) { _ in
            self.cameraQueue.async {
                self.photoMode = false
                self.configure()
                guard self.session.isRunning, !self.movieOutput.isRecording else { return self.reply(id, "Camera not ready", ok: false) }
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("larch-\(UUID().uuidString).mov")
                self.movieOutput.startRecording(to: url, recordingDelegate: self)
                self.reply(id, true)
            }
        }
    }

    private func videoStop(_ id: Int) {
        cameraQueue.async {
            guard self.movieOutput.isRecording else { return self.reply(id, ["id": ""]) }
            self.movieReply = id
            self.movieOutput.stopRecording()
        }
    }

    // MARK: saving to Photos

    private func savePhoto(_ data: Data, _ done: @escaping (String?) -> Void) {
        withLibrary { ok in
            guard ok else { return done(nil) }
            var placeholder: PHObjectPlaceholder?
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
                placeholder = request.placeholderForCreatedAsset
            }) { success, _ in done(success ? placeholder?.localIdentifier : nil) }
        }
    }

    private func saveVideo(_ url: URL, _ done: @escaping (String?) -> Void) {
        withLibrary { ok in
            guard ok else { return done(nil) }
            var placeholder: PHObjectPlaceholder?
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                placeholder = request?.placeholderForCreatedAsset
            }) { success, _ in done(success ? placeholder?.localIdentifier : nil) }
        }
    }

    // MARK: images as JPEG data URLs (ImageIO works the same on iPhone and Mac)

    static func jpegDataURL(_ image: CGImage, quality: Double = 0.82) -> String? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return "data:image/jpeg;base64," + (out as Data).base64EncodedString()
    }

    /// Crops a photo to the viewfinder's shape (centred, as the viewfinder shows it),
    /// keeping its full resolution and camera details.
    static func cropped(_ data: Data, aspect: CGFloat) -> Data? {
        guard aspect > 0.2, aspect < 5,
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let pw = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let ph = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(pw, ph)
        ]
        guard let upright = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        let w = CGFloat(upright.width), h = CGFloat(upright.height)
        var rect = CGRect(x: 0, y: 0, width: w, height: h)
        if w / h > aspect {
            rect.size.width = (h * aspect).rounded()
            rect.origin.x = ((w - rect.width) / 2).rounded()
        } else {
            rect.size.height = (w / aspect).rounded()
            rect.origin.y = ((h - rect.height) / 2).rounded()
        }
        guard let crop = upright.cropping(to: rect) else { return nil }
        var meta = props
        meta[kCGImagePropertyOrientation] = 1
        meta.removeValue(forKey: kCGImagePropertyPixelWidth)
        meta.removeValue(forKey: kCGImagePropertyPixelHeight)
        if var tiff = meta[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            meta[kCGImagePropertyTIFFDictionary] = tiff
        }
        if var exif = meta[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = crop.width
            exif[kCGImagePropertyExifPixelYDimension] = crop.height
            meta[kCGImagePropertyExifDictionary] = exif
        }
        meta[kCGImageDestinationLossyCompressionQuality] = 0.92
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, crop, meta as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    static func jpegDataURL(imageData data: Data, max: Int) -> String? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        return jpegDataURL(image)
    }

    private static func cgImage(_ image: PlatformImage) -> CGImage? {
        #if os(macOS)
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #else
        return image.cgImage
        #endif
    }

    private func picture(_ asset: PHAsset, max: Int, _ done: @escaping (String?) -> Void) {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: max, height: max),
                                              contentMode: .aspectFit, options: options) { image, _ in
            guard let image = image, let cg = Self.cgImage(image) else { return done(nil) }
            done(Self.jpegDataURL(cg, quality: 0.8))
        }
    }

    // MARK: Photos library

    private func libraryList(_ id: Int, video: Bool, offset: Int, limit: Int, thumb: Int) {
        withLibrary { ok in
            guard ok else { return self.reply(id, "Photos access is off. Turn it on in Settings › Privacy › Photos.", ok: false) }
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            let result = PHAsset.fetchAssets(with: video ? .video : .image, options: options)
            let total = result.count
            let end = min(total, max(0, offset) + max(1, limit))
            guard offset < end else { return self.reply(id, ["total": total, "items": [Any]()]) }
            var items = [[String: Any]](repeating: [:], count: end - offset)
            let group = DispatchGroup()
            let lock = NSLock()
            for index in offset..<end {
                let asset = result.object(at: index)
                group.enter()
                DispatchQueue.main.async {
                    self.picture(asset, max: thumb) { url in
                        var item: [String: Any] = ["id": asset.localIdentifier, "w": asset.pixelWidth,
                                                   "h": asset.pixelHeight, "thumb": url ?? ""]
                        if let date = asset.creationDate { item["date"] = date.timeIntervalSince1970 * 1000 }
                        if video { item["dur"] = asset.duration }
                        lock.lock(); items[index - offset] = item; lock.unlock()
                        group.leave()
                    }
                }
            }
            group.notify(queue: .global()) { self.reply(id, ["total": total, "items": items]) }
        }
    }

    private func asset(_ id: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
    }

    private func libraryGet(_ id: Int, _ assetId: String, max: Int) {
        withLibrary { ok in
            guard ok, let asset = self.asset(assetId) else { return self.reply(id, "Not found", ok: false) }
            DispatchQueue.main.async {
                self.picture(asset, max: max) { url in
                    guard let url = url else { return self.reply(id, "Could not open the picture", ok: false) }
                    self.reply(id, ["data": url, "w": asset.pixelWidth, "h": asset.pixelHeight,
                                    "date": (asset.creationDate?.timeIntervalSince1970 ?? 0) * 1000])
                }
            }
        }
    }

    private func libraryDelete(_ id: Int, _ assetId: String) {
        withLibrary { ok in
            guard ok, let asset = self.asset(assetId) else { return self.reply(id, false) }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.deleteAssets([asset] as NSArray)
            }) { success, _ in self.reply(id, success) }
        }
    }

    // MARK: video playback

    private func play(_ id: Int, _ a: [String: Any]) {
        withLibrary { ok in
            guard ok, let asset = self.asset(a["id"] as? String ?? "") else { return self.reply(id, "Not found", ok: false) }
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { item, _ in
                DispatchQueue.main.async {
                    guard let item = item else { return self.reply(id, "Could not open the video", ok: false) }
                    self.cameraQueue.async { if self.session.isRunning { self.session.stopRunning() } }
                    self.previewLayer?.removeFromSuperlayer(); self.previewLayer = nil
                    self.stopPlayer()
                    guard let view = self.place(a["rect"] as? [String: Any]) else { return self.reply(id, "No screen", ok: false) }
                    let player = AVPlayer(playerItem: item)
                    let layer = AVPlayerLayer(player: player)
                    layer.videoGravity = .resizeAspect
                    layer.frame = view.bounds
                    self.addLayer(layer, to: view)
                    self.playerLayer = layer
                    self.player = player
                    self.timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
                                                                       queue: .main) { [weak self] time in
                        guard let self = self, let p = self.player else { return }
                        let total = p.currentItem?.duration.seconds ?? 0
                        self.bridge?.evaluate("window.LarchMedia&&LarchMedia({t:\(time.seconds.isFinite ? time.seconds : 0),d:\(total.isFinite ? total : 0),playing:\(p.rate != 0)})")
                    }
                    self.endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                        self?.bridge?.evaluate("window.LarchMedia&&LarchMedia({ended:true,playing:false})")
                    }
                    player.play()
                    self.reply(id, true)
                }
            }
        }
    }

    private func seek(_ id: Int, by seconds: Double) {
        DispatchQueue.main.async {
            guard let p = self.player else { return self.reply(id, false) }
            let target = max(0, p.currentTime().seconds + seconds)
            p.seek(to: CMTime(seconds: target, preferredTimescale: 600))
            self.reply(id, true)
        }
    }

    private func stopPlayer() {
        if let o = timeObserver { player?.removeTimeObserver(o); timeObserver = nil }
        if let o = endObserver { NotificationCenter.default.removeObserver(o); endObserver = nil }
        player?.pause()
        player = nil
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
    }

    // MARK: voice recorder

    private var recordingsDir: URL {
        let dir = BridgeBase.stateURL.deletingLastPathComponent().appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func recordingURL(_ name: String) -> URL? {
        guard !name.isEmpty, !name.contains("/"), !name.contains("..") else { return nil }
        return recordingsDir.appendingPathComponent(name + ".m4a")
    }

    private func recStart(_ id: Int) {
        access(.audio) { granted in
            guard granted else { return self.reply(id, "Microphone access is off. Turn it on in Settings › Privacy › Microphone.", ok: false) }
            DispatchQueue.main.async {
                #if os(iOS)
                let audio = AVAudioSession.sharedInstance()
                try? audio.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
                try? audio.setActive(true)
                #endif
                let f = DateFormatter()
                f.dateFormat = "dd-MM-yyyy HH.mm.ss"
                let name = "Recording " + f.string(from: Date())
                guard let url = self.recordingURL(name) else { return self.reply(id, "Could not record", ok: false) }
                let settings: [String: Any] = [
                    AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: 44100,
                    AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
                ]
                do {
                    let recorder = try AVAudioRecorder(url: url, settings: settings)
                    recorder.isMeteringEnabled = true
                    guard recorder.record() else { return self.reply(id, "Could not record", ok: false) }
                    self.recorder = recorder
                    self.recorderName = name
                    self.reply(id, ["name": name])
                } catch {
                    self.reply(id, error.localizedDescription, ok: false)
                }
            }
        }
    }

    private func recStop(_ id: Int) {
        guard let recorder = recorder else { return reply(id, ["name": ""]) }
        let seconds = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        reply(id, ["name": recorderName, "dur": seconds])
    }

    private func recLevel(_ id: Int) {
        guard let recorder = recorder else { return reply(id, 0) }
        recorder.updateMeters()
        let db = Double(recorder.averagePower(forChannel: 0))   // -160…0
        reply(id, max(0, min(1, (db + 50) / 50)))
    }

    private func recList(_ id: Int) {
        let files = (try? FileManager.default.contentsOfDirectory(at: recordingsDir,
                                                                   includingPropertiesForKeys: [.fileSizeKey, .creationDateKey])) ?? []
        let items: [[String: Any]] = files.filter { $0.pathExtension == "m4a" }.map { url in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey])
            let player = try? AVAudioPlayer(contentsOf: url)
            return ["id": url.deletingPathExtension().lastPathComponent,
                    "size": values?.fileSize ?? 0,
                    "date": (values?.creationDate?.timeIntervalSince1970 ?? 0) * 1000,
                    "dur": player?.duration ?? 0]
        }.sorted { ($0["date"] as? Double ?? 0) > ($1["date"] as? Double ?? 0) }
        reply(id, items)
    }

    private func recGet(_ id: Int, _ name: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let url = self.recordingURL(name), let data = try? Data(contentsOf: url) else { return self.reply(id, nil) }
            self.reply(id, data.base64EncodedString())
        }
    }

    private func recDelete(_ id: Int, _ name: String) {
        if let url = recordingURL(name) { try? FileManager.default.removeItem(at: url) }
        reply(id, true)
    }
}

// MARK: - capture delegates

extension MediaController: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard let id = photoReply else { return }
        photoReply = nil
        guard let raw = photo.fileDataRepresentation() else { return reply(id, "The photo could not be taken", ok: false) }
        let data = Self.cropped(raw, aspect: viewAspect) ?? raw
        let preview = Self.jpegDataURL(imageData: data, max: 960) ?? ""
        savePhoto(data) { assetId in self.reply(id, ["id": assetId ?? "", "data": preview]) }
    }
}

extension MediaController: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo url: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        let id = movieReply
        movieReply = nil
        saveVideo(url) { assetId in
            try? FileManager.default.removeItem(at: url)
            if let id = id { self.reply(id, ["id": assetId ?? ""]) }
        }
    }
}
