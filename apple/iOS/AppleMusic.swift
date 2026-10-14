import MediaPlayer
import UIKit
import AVFoundation
import WebKit

/// The iPhone's music library (songs you own and Apple Music songs you've added to it),
/// browsed and played inside KeyPhone with the system music player.
final class AppleMusic: NSObject {
    private weak var bridge: BridgeBase?
    private let player = MPMusicPlayerController.applicationQueuePlayer
    private var observing = false
    /// What KeyPhone last queued, in order, so the phone can show "Up next".
    private var queue: [MPMediaItem] = []
    /// iOS changes the system volume through a volume view; kept off screen so no volume banner appears.
    private lazy var volumeView: MPVolumeView = {
        let view = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 40, height: 40))
        view.alpha = 0.01
        view.isUserInteractionEnabled = false
        return view
    }()
    private static let denied = "Music access is off. Turn it on in Settings › Privacy & Security › Media & Apple Music."

    init(bridge: BridgeBase) {
        self.bridge = bridge
        super.init()
    }

    private func reply(_ id: Int, _ value: Any?, ok: Bool = true) { bridge?.reply(id, value, ok: ok) }
    private func int(_ a: [String: Any], _ k: String, _ d: Int) -> Int { (a[k] as? NSNumber)?.intValue ?? d }

    func handle(_ id: Int, _ a: [String: Any]) {
        let op = a["op"] as? String ?? ""
        switch op {
        case "now": return reply(id, now(art: (a["art"] as? Bool) == true))
        case "pause": player.pause(); return reply(id, now(art: false))
        case "play": player.play(); return reply(id, now(art: false))
        case "next": player.skipToNextItem(); return reply(id, now(art: true))
        case "prev":
            if player.currentPlaybackTime > 3 { player.skipToBeginning() } else { player.skipToPreviousItem() }
            return reply(id, now(art: true))
        case "stop": player.stop(); return reply(id, now(art: false))
        case "shuffle":
            let on = (a["on"] as? Bool) ?? (player.shuffleMode == .off)
            player.shuffleMode = on ? .songs : .off
            return reply(id, now(art: false))
        case "repeat":
            let mode = a["mode"] as? String ?? ""
            switch mode {
            case "off": player.repeatMode = .none
            case "one": player.repeatMode = .one
            case "all": player.repeatMode = .all
            default: player.repeatMode = player.repeatMode == .all ? .one : player.repeatMode == .one ? .none : .all
            }
            return reply(id, now(art: false))
        case "seek":
            if player.nowPlayingItem != nil, let to = (a["to"] as? NSNumber)?.doubleValue {
                let length = player.nowPlayingItem?.playbackDuration ?? 0
                player.currentPlaybackTime = max(0, length > 0 ? min(length - 1, to) : to)
            }
            return reply(id, now(art: false))
        case "volume":
            let current = AVAudioSession.sharedInstance().outputVolume
            var value = current
            if let to = (a["to"] as? NSNumber)?.floatValue { value = to }
            if let delta = (a["delta"] as? NSNumber)?.floatValue { value = current + delta }
            setVolume(max(0, min(1, value)))
            return reply(id, ["vol": Double(max(0, min(1, value)))])
        case "queue":
            let current = player.nowPlayingItem?.persistentID
            let list = queue.isEmpty ? (player.nowPlayingItem.map { [$0] } ?? []) : queue
            let items: [[String: Any]] = list.prefix(500).enumerated().map { i, s in
                ["id": String(s.persistentID), "t": s.title ?? "Song", "s": s.artist ?? "", "i": i, "on": s.persistentID == current]
            }
            return reply(id, ["items": items, "total": list.count])
        case "jump":
            let i = int(a, "i", -1)
            guard i >= 0, i < queue.count else { return reply(id, "Not in the queue", ok: false) }
            player.nowPlayingItem = queue[i]
            player.play()
            return reply(id, now(art: true))
        default: break
        }
        withAccess(id) {
            switch op {
            case "auth": self.reply(id, true)
            case "browse": self.browse(id, a)
            case "tracks": self.tracks(id, a)
            case "start": self.start(id, a)
            case "playNext", "addQueue": self.enqueue(id, a, next: op == "playNext")
            default: self.reply(id, "Not available", ok: false)
            }
        }
    }

    private func withAccess(_ id: Int, _ work: @escaping () -> Void) {
        switch MPMediaLibrary.authorizationStatus() {
        case .authorized: work()
        case .notDetermined:
            MPMediaLibrary.requestAuthorization { status in
                DispatchQueue.main.async { status == .authorized ? work() : self.reply(id, AppleMusic.denied, ok: false) }
            }
        default: reply(id, AppleMusic.denied, ok: false)
        }
    }

    private func browse(_ id: Int, _ a: [String: Any]) {
        let kind = a["kind"] as? String ?? "songs"
        let offset = max(0, int(a, "offset", 0)), limit = max(1, int(a, "limit", 200))
        var out: [[String: Any]] = []
        var total = 0
        switch kind {
        case "playlists":
            let lists = MPMediaQuery.playlists().collections ?? []
            total = lists.count
            for c in lists.dropFirst(offset).prefix(limit) {
                let p = c as? MPMediaPlaylist
                out.append(["id": String(p?.persistentID ?? 0), "t": p?.name ?? "Playlist", "s": "\(c.count) songs"])
            }
        case "albums":
            let albums = MPMediaQuery.albums().collections ?? []
            total = albums.count
            for c in albums.dropFirst(offset).prefix(limit) {
                let r = c.representativeItem
                out.append(["id": String(r?.albumPersistentID ?? 0), "t": r?.albumTitle ?? "Album", "s": r?.albumArtist ?? r?.artist ?? ""])
            }
        case "artists":
            let artists = MPMediaQuery.artists().collections ?? []
            total = artists.count
            for c in artists.dropFirst(offset).prefix(limit) {
                let r = c.representativeItem
                out.append(["id": String(r?.artistPersistentID ?? 0), "t": r?.artist ?? "Artist", "s": "\(c.count) songs"])
            }
        default:
            let songs = MPMediaQuery.songs().items ?? []
            total = songs.count
            for (i, s) in songs.dropFirst(offset).prefix(limit).enumerated() {
                out.append(["id": String(s.persistentID), "t": s.title ?? "Song", "s": s.artist ?? "", "i": offset + i])
            }
        }
        reply(id, ["total": total, "items": out])
    }

    private func items(_ kind: String, _ id: String) -> [MPMediaItem] {
        guard kind != "songs" else { return MPMediaQuery.songs().items ?? [] }
        guard let pid = UInt64(id) else { return [] }
        let value = NSNumber(value: pid)
        let query: MPMediaQuery
        switch kind {
        case "playlists":
            query = MPMediaQuery.playlists()
            query.addFilterPredicate(MPMediaPropertyPredicate(value: value, forProperty: MPMediaPlaylistPropertyPersistentID))
        case "albums":
            query = MPMediaQuery.albums()
            query.addFilterPredicate(MPMediaPropertyPredicate(value: value, forProperty: MPMediaItemPropertyAlbumPersistentID))
        default:
            query = MPMediaQuery.songs()
            query.addFilterPredicate(MPMediaPropertyPredicate(value: value, forProperty: MPMediaItemPropertyArtistPersistentID))
        }
        return query.items ?? []
    }

    private func tracks(_ id: Int, _ a: [String: Any]) {
        let list = items(a["kind"] as? String ?? "", a["id"] as? String ?? "")
        let out: [[String: Any]] = list.prefix(1000).enumerated().map { i, s in
            ["id": String(s.persistentID), "t": s.title ?? "Song", "s": s.artist ?? "", "dur": s.playbackDuration, "i": i]
        }
        reply(id, ["total": list.count, "items": out])
    }

    private func start(_ id: Int, _ a: [String: Any]) {
        let list = items(a["kind"] as? String ?? "songs", a["id"] as? String ?? "")
        guard !list.isEmpty else { return reply(id, "Nothing to play", ok: false) }
        let index = min(max(0, int(a, "index", 0)), list.count - 1)
        queue = list
        player.setQueue(with: MPMediaItemCollection(items: list))
        player.nowPlayingItem = list[index]
        player.prepareToPlay()
        player.play()
        observe()
        reply(id, now(art: true))
    }

    /// Play next / add to the end of the queue, like the Music app.
    private func enqueue(_ id: Int, _ a: [String: Any], next: Bool) {
        var list = items(a["kind"] as? String ?? "songs", a["id"] as? String ?? "")
        if let i = (a["index"] as? NSNumber)?.intValue, i >= 0, i < list.count, (a["one"] as? Bool) == true { list = [list[i]] }
        guard !list.isEmpty else { return reply(id, "Nothing to add", ok: false) }
        guard player.nowPlayingItem != nil else {
            queue = list
            player.setQueue(with: MPMediaItemCollection(items: list))
            player.play()
            observe()
            return reply(id, now(art: true))
        }
        let descriptor = MPMusicPlayerMediaItemQueueDescriptor(itemCollection: MPMediaItemCollection(items: list))
        if next {
            player.prepend(descriptor)
            let at = (queue.firstIndex { $0.persistentID == player.nowPlayingItem?.persistentID } ?? -1) + 1
            queue.insert(contentsOf: list, at: min(max(0, at), queue.count))
        } else {
            player.append(descriptor)
            queue.append(contentsOf: list)
        }
        reply(id, now(art: false))
    }

    private func setVolume(_ value: Float) {
        if volumeView.superview == nil, let host = bridge?.webView { host.addSubview(volumeView) }
        let apply = { [weak self] in
            guard let slider = self?.volumeView.subviews.compactMap({ $0 as? UISlider }).first else { return }
            slider.value = value
        }
        apply()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: apply)
    }

    private func observe() {
        guard !observing else { return }
        observing = true
        player.beginGeneratingPlaybackNotifications()
        let center = NotificationCenter.default
        for name in [Notification.Name.MPMusicPlayerControllerNowPlayingItemDidChange, .MPMusicPlayerControllerPlaybackStateDidChange] {
            center.addObserver(forName: name, object: player, queue: .main) { [weak self] note in
                guard let self = self, let json = try? JSONSerialization.data(withJSONObject: self.now(art: note.name == .MPMusicPlayerControllerNowPlayingItemDidChange)),
                      let text = String(data: json, encoding: .utf8) else { return }
                self.bridge?.evaluate("window.LarchMusic&&LarchMusic(\(text))")
            }
        }
    }

    func now(art: Bool) -> [String: Any] {
        guard let item = player.nowPlayingItem else { return ["none": true] }
        let position = player.currentPlaybackTime
        var out: [String: Any] = ["id": String(item.persistentID), "t": item.title ?? "", "s": item.artist ?? "", "a": item.albumTitle ?? "",
                                  "dur": item.playbackDuration, "pos": position.isFinite ? position : 0,
                                  "playing": player.playbackState == .playing, "shuffle": player.shuffleMode != .off,
                                  "repeat": player.repeatMode == .one ? "one" : player.repeatMode == .all ? "all" : "off",
                                  "vol": Double(AVAudioSession.sharedInstance().outputVolume)]
        if art, let image = item.artwork?.image(at: CGSize(width: 240, height: 240)), let jpeg = image.jpegData(compressionQuality: 0.8) {
            out["art"] = "data:image/jpeg;base64," + jpeg.base64EncodedString()
        }
        return out
    }
}
