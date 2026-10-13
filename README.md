# Larch K7

A Series 40–style keypad phone that runs on your Mac and iPhone. The phone's
keypad, menus and screen are one HTML file; the Mac and iPhone apps wrap it and
connect it to the system, so calls, messages, contacts, photos and alarms are real.

**Website and downloads:** see the GitHub Pages site for this repository
(Settings › Pages shows the address).

## What's in here

| Folder | What it is |
|---|---|
| `phone/index.html` | The phone itself: keypad, standby, menus, settings, organiser, games. |
| `apple/` | XcodeGen project for the iPhone app (`iOS/`), the Mac app (`macOS/`) and their shared bridge (`Shared/`). |
| `site/` | The download website. The workflow adds a playable copy of the phone at `/play/`. |
| `.github/workflows/build.yml` | Builds `LarchK7.ipa` and `LarchK7.dmg` on macOS and attaches them to a release. |
| `.github/workflows/pages.yml` | Publishes the website to GitHub Pages. |

## Making a release

```sh
git tag v1.0.0
git push origin v1.0.0
```

The **Build apps** workflow builds both apps and publishes them to a release
named after the tag. The website's download buttons always point at the latest release.

The apps are not signed with an Apple Developer ID:

- **Mac:** after dragging Larch K7 to Applications, open it once from
  System Settings › Privacy & Security › Open Anyway, or run
  `xattr -dr com.apple.quarantine "/Applications/Larch K7.app"`.
- **iPhone:** install `LarchK7.ipa` with a sideloading tool such as Sideloadly or
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

## What the system doesn't allow

iOS and macOS don't let apps read your text messages or full call history, and iOS
doesn't expose signal strength, so the Inbox holds messages saved on the phone,
the Log lists calls made from Larch K7, and on iPhone the signal bars show online
or offline. Java `.jar` apps install and list today; a built-in runtime to run
them is planned.

Larch K7 is an original design and is not affiliated with any phone maker.
