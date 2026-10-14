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
    private var overlay: WKWebView?

    override init() {
        super.init()
        pathMonitor.pathUpdateHandler = { [weak self] _ in DispatchQueue.main.async { self?.pushStatus() } }
        pathMonitor.start(queue: DispatchQueue.global(qos: .utility))
        statusTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.pushStatus() }
        // Battery and power changes arrive the moment macOS reports them.
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context = context else { return }
            let bridge = Unmanaged<MacHostBridge>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { bridge.pushStatus() }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }
    }

    deinit { statusTimer?.invalidate() }

    // MARK: status

    func pushStatus() {
        let path = pathMonitor.currentPath
        let online = path.status == .satisfied
        var parts = ["online:\(online)", "net:'\(BridgeBase.netType(path))'"]
        if online, path.usesInterfaceType(.wifi),
           let rssi = CWWiFiClient.shared().interface()?.rssiValue(), rssi != 0 {
            parts.append("sig:\(rssi > -55 ? 5 : rssi > -65 ? 4 : rssi > -72 ? 3 : rssi > -80 ? 2 : 1)")
        }
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
        case "web": web(id, args)
        case "saveFile": saveFile(id, args["name"] as? String ?? "KeyPhone backup.json", args["text"] as? String ?? "")
        case "music": DispatchQueue.main.async { self.music(id, args) }
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

    // MARK: music: the Music app and the Spotify app, through AppleScript

    private func script(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil ? result : nil
    }

    private func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private func number(_ s: String) -> Double { Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0 }

    private func music(_ id: Int, _ a: [String: Any]) {
        let spotify = (a["src"] as? String) == "spotify"
        let app = spotify ? "Spotify" : "Music"
        let op = a["op"] as? String ?? ""
        let int = { (k: String, d: Int) in (a[k] as? NSNumber)?.intValue ?? d }
        switch op {
        case "now": reply(id, now(app, art: (a["art"] as? Bool) == true))
        case "pause", "play", "next", "prev", "stop":
            let verb = ["pause": "pause", "play": "play", "next": "next track", "prev": "previous track", "stop": spotify ? "pause" : "stop"][op] ?? "pause"
            _ = script("tell application \(quoted(app)) to \(verb)")
            reply(id, now(app, art: op == "next" || op == "prev"))
        case "shuffle":
            let prop = spotify ? "shuffling" : "shuffle enabled"
            let on = (a["on"] as? Bool).map { $0 ? "true" : "false" } ?? "not \(prop)"
            _ = script("tell application \(quoted(app)) to set \(prop) to \(on)")
            reply(id, now(app, art: false))
        case "repeat":
            let mode = a["mode"] as? String ?? ""
            if spotify {
                let on = mode == "" ? "not repeating" : (mode == "off" ? "false" : "true")
                _ = script("tell application \"Spotify\" to set repeating to \(on)")
            } else if ["off", "all", "one"].contains(mode) {
                _ = script("tell application \"Music\" to set song repeat to \(mode)")
            } else {
                _ = script("""
                tell application "Music"
                  if song repeat is off then
                    set song repeat to all
                  else if song repeat is all then
                    set song repeat to one
                  else
                    set song repeat to off
                  end if
                end tell
                """)
            }
            reply(id, now(app, art: false))
        case "seek":
            let to = max(0, (a["to"] as? NSNumber)?.doubleValue ?? 0)
            _ = script("tell application \(quoted(app)) to set player position to \(String(format: "%.1f", to))")
            reply(id, now(app, art: false))
        case "volume":
            let current = Double(script("tell application \(quoted(app)) to get sound volume")?.int32Value ?? 50) / 100
            var value = current
            if let to = (a["to"] as? NSNumber)?.doubleValue { value = to }
            if let delta = (a["delta"] as? NSNumber)?.doubleValue { value = current + delta }
            value = max(0, min(1, value))
            _ = script("tell application \(quoted(app)) to set sound volume to \(Int((value * 100).rounded()))")
            reply(id, ["vol": value])
        case "queue":
            guard !spotify else { return reply(id, "Up next isn't available for the Spotify app", ok: false) }
            let text = script("""
            tell application "Music"
              if player state is stopped then return ""
              set p to current playlist
              set ci to index of current track
              set total to count of tracks of p
              set lastOne to ci + 100
              if lastOne > total then set lastOne to total
              set ns to name of tracks ci thru lastOne of p
              set ars to artist of tracks ci thru lastOne of p
            end tell
            set out to {(ci as string)}
            repeat with k from 1 to count of ns
              set end of out to (item k of ns) & tab & (item k of ars)
            end repeat
            set AppleScript's text item delimiters to linefeed
            return out as text
            """)?.stringValue ?? ""
            var lines = text.components(separatedBy: "\n")
            let first = (Int(lines.first ?? "") ?? 1) - 1
            if !lines.isEmpty { lines.removeFirst() }
            let items: [[String: Any]] = lines.enumerated().map { k, line in
                let parts = line.components(separatedBy: "\t")
                return ["t": parts[0], "s": parts.count > 1 ? parts[1] : "", "i": first + k, "on": k == 0]
            }
            reply(id, ["items": items, "total": items.count])
        case "jump":
            guard !spotify else { return reply(id, "Not available", ok: false) }
            _ = script("tell application \"Music\" to play track \(int("i", 0) + 1) of current playlist")
            reply(id, now(app, art: true))
        case "playNext", "addQueue":
            reply(id, "Up next can only be changed in the Music app on a Mac", ok: false)
        case "auth":
            if script("tell application \(quoted(app)) to get name") != nil { reply(id, true) }
            else { reply(id, "Allow KeyPhone to control \(app) in System Settings › Privacy & Security › Automation.", ok: false) }
        case "uri":
            _ = script("tell application \"Spotify\" to play track \(quoted(a["uri"] as? String ?? ""))")
            reply(id, now("Spotify", art: true))
        case "browse":
            if (a["kind"] as? String) == "playlists" {
                let text = script("""
                tell application "Music" to set out to name of user playlists
                set AppleScript's text item delimiters to linefeed
                return out as text
                """)?.stringValue ?? ""
                let items: [[String: Any]] = text.split(separator: "\n").map { line in
                    let parts = line.components(separatedBy: "\t")
                    return ["id": parts[0], "t": parts[0], "s": "Playlist"]
                }
                reply(id, ["total": items.count, "items": items])
            } else {
                reply(id, trackList("library playlist 1", offset: int("offset", 0), limit: int("limit", 200)))
            }
        case "tracks":
            reply(id, trackList("user playlist \(quoted(a["id"] as? String ?? ""))", offset: 0, limit: 500))
        case "start":
            let index = int("index", 0) + 1
            let kind = a["kind"] as? String ?? "songs"
            let list = kind == "playlists" ? "user playlist \(quoted(a["id"] as? String ?? ""))" : "library playlist 1"
            _ = script("tell application \"Music\" to play track \(index) of \(list)")
            reply(id, now("Music", art: true))
        default: reply(id, "Not available", ok: false)
        }
    }

    private func trackList(_ list: String, offset: Int, limit: Int) -> [String: Any] {
        let total = Int(script("tell application \"Music\" to count of tracks of \(list)")?.int32Value ?? 0)
        guard total > offset else { return ["total": total, "items": []] }
        let last = min(total, offset + limit)
        let text = script("""
        tell application "Music"
          set ns to name of tracks \(offset + 1) thru \(last) of \(list)
          set ars to artist of tracks \(offset + 1) thru \(last) of \(list)
        end tell
        set out to {}
        repeat with k from 1 to count of ns
          set end of out to (item k of ns) & tab & (item k of ars)
        end repeat
        set AppleScript's text item delimiters to linefeed
        return out as text
        """)?.stringValue ?? ""
        let items: [[String: Any]] = text.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { i, line in
            let parts = line.components(separatedBy: "\t")
            return ["id": String(offset + i), "t": parts[0], "s": parts.count > 1 ? parts[1] : "", "i": offset + i]
        }
        return ["total": total, "items": items]
    }

    private func now(_ app: String, art: Bool) -> [String: Any] {
        let durationUnit = app == "Spotify" ? " / 1000" : ""
        let text = script("""
        if application \(quoted(app)) is running then
          tell application \(quoted(app))
            if player state is stopped then return "stopped"
            set t to current track
            return (name of t) & linefeed & (artist of t) & linefeed & (album of t) & linefeed & (((duration of t)\(durationUnit)) as string) & linefeed & (player position as string) & linefeed & (player state as string) & linefeed & (\(app == "Spotify" ? "shuffling" : "shuffle enabled") as string) & linefeed & (\(app == "Spotify" ? "repeating" : "song repeat") as string) & linefeed & (sound volume as string)
          end tell
        end if
        return "off"
        """)?.stringValue ?? "off"
        let parts = text.components(separatedBy: "\n")
        guard parts.count >= 6 else { return ["none": true, "app": text] }
        var out: [String: Any] = ["id": parts[0] + "|" + parts[1], "t": parts[0], "s": parts[1], "a": parts[2],
                                  "dur": number(parts[3]), "pos": number(parts[4]), "playing": parts[5] == "playing"]
        if parts.count >= 9 {
            out["shuffle"] = parts[6] == "true"
            out["repeat"] = parts[7] == "true" ? "all" : parts[7] == "false" ? "off" : parts[7]
            out["vol"] = number(parts[8]) / 100
        }
        if art {
            if app == "Spotify", let url = script("tell application \"Spotify\" to artwork url of current track")?.stringValue {
                out["art"] = url
            } else if let data = script("tell application \"Music\" to get data of artwork 1 of current track")?.data,
                      let image = NSImage(data: data), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                      let url = MediaController.jpegDataURL(cg, quality: 0.8) {
                out["art"] = url
            }
        }
        return out
    }

    // MARK: files

    /// Saves a file (a phone backup) where the user chooses.
    private func saveFile(_ id: Int, _ name: String, _ text: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        let done: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return self.reply(id, false) }
            do { try Data(text.utf8).write(to: url, options: .atomic); self.reply(id, true) }
            catch { self.reply(id, error.localizedDescription, ok: false) }
        }
        if let window = webView?.window { panel.beginSheetModal(for: window, completionHandler: done) }
        else { panel.begin(completionHandler: done) }
    }

    // MARK: web pages shown on the phone's own screen

    private func makeOverlay() -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        view.customUserAgent = BridgeBase.mobileUserAgent
        view.pageZoom = 0.8
        view.allowsBackForwardNavigationGestures = true
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
            if let r = a["rect"] as? [String: Any], let host = webView {
                let n = { (k: String) in CGFloat((r[k] as? NSNumber)?.doubleValue ?? 0) }
                let y = host.isFlipped ? n("y") : host.bounds.height - n("y") - n("h")
                view.frame = NSRect(x: n("x"), y: y, width: n("w"), height: n("h"))
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
            webView?.window?.makeFirstResponder(webView)
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

    // MARK: WKNavigationDelegate

    func webView(_ view: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if view === overlay { webState(view) }
    }

    func webView(_ view: WKWebView, didCommit navigation: WKNavigation!) {
        if view === overlay { webState(view) }
    }

    func webView(_ view: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if view === overlay { webState(view) }
    }

    func webView(_ view: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if view === overlay { webState(view) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView === overlay { return webState(webView) }
        pushStatus()
        webView.window?.makeFirstResponder(webView)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.allow) }
        if webView === overlay {
            if let scheme = url.scheme?.lowercased(), !["http", "https", "about", "data", "blob"].contains(scheme) {
                NSWorkspace.shared.open(url)   // tel:, mailto: and so on
                return decisionHandler(.cancel)
            }
            if BridgeBase.isJavaApp(url: url) {
                offerInstall(url)
                return decisionHandler(.cancel)
            }
            return decisionHandler(.allow)
        }
        if url.isFileURL || url.scheme == "about" || url.scheme == "data" || url.scheme == "blob" {
            return decisionHandler(.allow)
        }
        if action.targetFrame == nil || (action.navigationType == .linkActivated && action.targetFrame?.isMainFrame == true) {
            NSWorkspace.shared.open(url)
            return decisionHandler(.cancel)
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if webView === overlay, let url = response.response.url,
           BridgeBase.isJavaApp(url: url, mimeType: response.response.mimeType) {
            offerInstall(url)
            return decisionHandler(.cancel)
        }
        decisionHandler(.allow)
    }

    // MARK: WKUIDelegate — "Add files" and other file inputs

    // VoIP calls use the microphone from the phone's own page; macOS still asks the user once.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(type == .microphone ? .grant : .prompt)
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = false
        panel.begin { result in completionHandler(result == .OK ? panel.urls : nil) }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if webView === overlay {
            if action.targetFrame == nil { webView.load(action.request) }
        } else if let url = action.request.url {
            NSWorkspace.shared.open(url)
        }
        return nil
    }
}
