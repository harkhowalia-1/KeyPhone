import AudioToolbox
import QuartzCore

/// Reads the iPhone's Ring/Silent switch (or the Action button's Silent mode).
/// iOS has no API for it, so a tiny silent system sound is played now and then:
/// system sounds obey the switch, and a silenced one finishes at once instead of
/// after its length. The phone uses this to mute key, message and ringing tones.
final class SilentSwitch {
    private var sound: SystemSoundID = 0
    private var timer: Timer?
    private var checking = false
    private(set) var silent: Bool?
    var onChange: ((Bool) -> Void)?

    init() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("keyphone-silence.wav")
        try? SilentSwitch.silence(seconds: 0.3).write(to: url, options: .atomic)
        guard AudioServicesCreateSystemSoundID(url as CFURL, &sound) == noErr else { sound = 0; return }
        // Plays whether or not keyboard clicks and other UI sound effects are switched off.
        var no: UInt32 = 0
        AudioServicesSetProperty(kAudioServicesPropertyIsUISound, UInt32(MemoryLayout<SystemSoundID>.size), &sound,
                                 UInt32(MemoryLayout<UInt32>.size), &no)
    }

    deinit {
        timer?.invalidate()
        if sound != 0 { AudioServicesDisposeSystemSoundID(sound) }
    }

    /// Checks now and then every couple of seconds while the app is open.
    func start() {
        timer?.invalidate()
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.check() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func check() {
        guard sound != 0, !checking else { return }
        checking = true
        let began = CACurrentMediaTime()
        AudioServicesPlaySystemSoundWithCompletion(sound) { [weak self] in
            let elapsed = CACurrentMediaTime() - began
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.checking = false
                let now = elapsed < 0.1
                if now != self.silent {
                    self.silent = now
                    self.onChange?(now)
                }
            }
        }
    }

    /// A short mono WAV file of silence.
    private static func silence(seconds: Double) -> Data {
        let rate = 22050, samples = Int(Double(rate) * seconds), bytes = samples * 2
        var d = Data()
        func put32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func put16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append(contentsOf: Array("RIFF".utf8)); put32(UInt32(36 + bytes))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); put32(16); put16(1); put16(1)
        put32(UInt32(rate)); put32(UInt32(rate * 2)); put16(2); put16(16)
        d.append(contentsOf: Array("data".utf8)); put32(UInt32(bytes))
        d.append(Data(count: bytes))
        return d
    }
}
