# KeyPhone

A Series 40–style keypad phone that runs on your Mac and iPhone. The phone's
keypad, menus and screen are one HTML file; the Mac and iPhone apps wrap it and
connect it to the system, so calls, messages, contacts, photos and alarms are real.

**Website:** https://harkhowalia-1.github.io/KeyPhone/  
**Play in your browser:** https://harkhowalia-1.github.io/KeyPhone/play/  
**Downloads:** [Mac (KeyPhone.dmg)](https://github.com/harkhowalia-1/KeyPhone/releases/latest/download/KeyPhone.dmg) ·
[iPhone (KeyPhone.ipa)](https://github.com/harkhowalia-1/KeyPhone/releases/latest/download/KeyPhone.ipa) ·
[all releases](https://github.com/harkhowalia-1/KeyPhone/releases)

## Features

- **Calls and VoIP:** dial through the iPhone, or make real calls over your own SIP/VoIP account (WebRTC), with hold, mute, keypad tones and a call log.
- **Messages and contacts:** multi-tap, predictive text, the Messenger's keyboard or the iPhone keyboard; Names is your device's address book.
- **Camera, Gallery and Recorder:** a live viewfinder, photos saved exactly as framed, your Photos library, voice memos.
- **Music:** your Apple Music library by default, plus your own files and Spotify, with seek, shuffle, repeat, volume, Up next and a sleep timer. Internet radio too.
- **Seven phone models:** original designs from different eras, including the Messenger, a wide QWERTY phone with a landscape screen in five colours (Midnight black among them). Each model has its own menus, fonts, themes and wallpapers.
- **Organiser:** alarms, reminders and timers that ring with the app closed, calendar, notes, to-do, calculator, stopwatch, weather, world clock, converter, ringtone composer, torch.
- **Java:** .jar games run offline in the built-in engine, which stays ready in the background so games open at once; the full engine runs more online.
- **Silent mode:** key, message and ringing tones follow the iPhone's Ring/Silent switch.
- **Touch screen and keys:** press the phone's keys, or tap, drag, hold and swipe on its screen. Whole-screen layout by default on iPhone.

## What's in here

| Folder | What it is |
|---|---|
| `phone/index.html` | The phone itself: keypad, standby, menus, settings, organiser, games. |
| `apple/` | XcodeGen project for the iPhone app (`iOS/`), the Mac app (`macOS/`) and their shared bridge (`Shared/`). |
| `site/` | The download website. The workflow adds a playable copy of the phone at `/play/`. |
| `.github/workflows/build.yml` | Builds `KeyPhone.ipa` and `KeyPhone.dmg` on macOS and attaches them to a release. |
| `.github/workflows/pages.yml` | Publishes the website to GitHub Pages. |

## Making a release

Every push to `main` that changes the phone or the apps runs **Build apps**,
which builds both apps on macOS and publishes them to the release named in
`VERSION` (for example `v1.0.0`). Raise the number in `VERSION` to start a new
release. The website's download buttons always point at the latest release.

The apps are not signed with an Apple Developer ID:

- **Mac:** after dragging KeyPhone to Applications, open it once from
  System Settings › Privacy & Security › Open Anyway, or run
  `xattr -dr com.apple.quarantine "/Applications/KeyPhone.app"`.
- **iPhone:** install `KeyPhone.ipa` with a sideloading tool such as Sideloadly or
  AltStore, which signs it with your Apple ID. A free Apple ID needs a reinstall every 7 days.

## Building on your Mac

```sh
brew install xcodegen
cd apple
./make_web.sh && xcodegen generate
open Larch.xcodeproj
```

Pick the **Larch** target for iPhone or **LarchMac** for Mac, set your Team under
Signing & Capabilities, and press Run. After editing `phone/index.html`, run
`./make_web.sh` again.

## Bundled components

| Folder | What | Licence |
|---|---|---|
| `site/j2me/lite/` | [JS2ME](https://github.com/szatkus/js2me), the built-in Java ME engine (works offline) | MIT |
| `site/j2me/` | [freej2me-web](https://github.com/zb3/freej2me-web), the full Java engine; it runs on CheerpJ, which is loaded from the internet because its free licence doesn't allow bundling | GPL-3.0 |
| `site/voip/` | [JsSIP](https://github.com/versatica/JsSIP) with sdp-transform and events, for VoIP calls | MIT |
| `phone/fonts/` | Jersey 10, Nunito, Inter and Titillium Web, embedded in the phone | SIL OFL 1.1 |

`apple/make_web.sh` copies the Java engine and the VoIP library next to the phone in
the apps, and the website workflow does the same for the playable copy.

## What the system doesn't allow

iOS and macOS don't let apps read your text messages or full call history, and iOS
doesn't expose signal strength or the caller's number, so there is no Inbox, the Log
lists calls made from KeyPhone (and VoIP calls with their numbers), and on iPhone the
status icon shows the connection type. VoIP needs a provider that supports SIP over
secure WebSocket (WebRTC), and calls ring only while KeyPhone is open. Spotify needs
your own Spotify developer app's Client ID, and playback control needs Premium.
iOS has no API for the Ring/Silent switch, so the iPhone app checks it every two
seconds while open (by timing a silent system sound) and mutes key, message and
ringing tones while it is set to silent. On a Mac the music player drives the Music
app, which can't have songs added to Up next from outside.

KeyPhone is an original design and is not affiliated with any phone maker.
