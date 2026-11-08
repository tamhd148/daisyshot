<div align="center">
  <img src="Assets/AppIcons/handles.png" width="128" height="128" alt="Daisyshot app icon" />
  <br />
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="Assets/Logo/logotype-white.svg" />
    <img src="Assets/Logo/logotype-ink.svg" width="260" alt="Daisyshot" />
  </picture>

  <p><strong>Screenshots, screen recordings and polished screen videos for macOS — from the menu bar, offline.</strong></p>

  <p>
    Built with <a href="https://developer.apple.com/xcode/swiftui/">SwiftUI</a>,
    <a href="https://developer.apple.com/documentation/appkit">AppKit</a>,
    <a href="https://developer.apple.com/documentation/screencapturekit">ScreenCaptureKit</a>,
    <a href="https://developer.apple.com/documentation/avfoundation">AVFoundation</a> and
    <a href="https://developer.apple.com/documentation/vision">Vision</a> — no third-party dependencies.
  </p>

  <p>
    <a href="README.md">🇺🇸 English</a> •
    <a href="README.vi.md">🇻🇳 Tiếng Việt</a>
  </p>

  <p>
    <a href="https://github.com/tamhd148/daisyshot/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/tamhd148/daisyshot?style=flat" /></a>
    <a href="https://github.com/tamhd148/daisyshot/releases"><img alt="Downloads" src="https://img.shields.io/github/downloads/tamhd148/daisyshot/total?style=flat&amp;logo=github" /></a>
    <a href="https://github.com/tamhd148/daisyshot/actions/workflows/build.yml"><img alt="Build" src="https://github.com/tamhd148/daisyshot/actions/workflows/build.yml/badge.svg" /></a>
    <img alt="macOS 15 or later" src="https://img.shields.io/badge/macOS-15%2B-blue?style=flat&amp;logo=apple" />
    <a href="LICENSE"><img alt="MIT License" src="https://img.shields.io/github/license/tamhd148/daisyshot?style=flat" /></a>
    <a href="https://ko-fi.com/tamhd"><img alt="Support on Ko-fi" src="https://img.shields.io/badge/Ko--fi-Support-FF5E5B?style=flat&amp;logo=ko-fi&amp;logoColor=white" /></a>
  </p>

  <p>
    <a href="#install">Install</a> •
    <a href="#quick-start">Quick start</a> •
    <a href="#features">Features</a> •
    <a href="#shortcuts">Shortcuts</a> •
    <a href="#automation-url-scheme">Automation</a> •
    <a href="#security-and-privacy">Security and privacy</a> •
    <a href="#uninstall">Uninstall</a> •
    <a href="#build-from-source">Build from source</a> •
    <a href="#contributing">Contributing</a> •
    <a href="#license-and-name">License</a>
  </p>
</div>

![A Studio recording exported by Daisyshot: a gradient background, zooms that follow the cursor, click ripples and a ⌘S keystroke badge](docs/images/demo.gif)

<p align="center"><sub>Exported straight from the Studio editor — background, zooms, cursor and keystrokes are added after recording.</sub></p>

Daisyshot is free and open source under the [MIT License](LICENSE). If it saves you time, you can support its
development on [Ko-fi](https://ko-fi.com/tamhd).

## Install

1. Download `Daisyshot-<version>.dmg` from the [latest release](https://github.com/tamhd148/daisyshot/releases/latest) and
   drag Daisyshot into Applications.
2. Builds aren't notarized by Apple yet, so macOS blocks the first launch. Click **Done**, then open
   **System Settings › Privacy & Security**, click **Open Anyway** next to Daisyshot and confirm.
   (Or in Terminal: `xattr -dr com.apple.quarantine /Applications/Daisyshot.app`.)
3. Allow Screen & System Audio Recording when asked, then reopen Daisyshot. It lives in the menu bar.

Later versions install from inside the app (**Check for Updates…** in the menu bar menu, or automatically once a day).
Updates are signed, and Daisyshot only installs archives that carry its release signature.

Requires macOS 15 Sequoia or later, Apple silicon or Intel.

## Quick start

1. Press **⌥⇧⌘4** and drag over part of the screen (or **⌥⇧⌘5** for the all-in-one bar).
2. The shot appears in a Quick Access card: hover it and press **⌘C** to copy, **⌘S** to save, **⌘E** to annotate or
   **⌘P** to pin it on screen — or drag it straight into another app.
3. Press **⌥⇧⌘6** to record: pick a display, a window, an area or a connected iPhone / iPad, then **Start Recording**.
   Stop from the menu bar; the recording opens in the Studio editor, ready to export.

## Features

**Screenshots**
- Area, window, full screen, previous area, self-timer and scrolling capture
- Annotate: arrows, shapes, text, pen and highlighter, blur and pixelate, spotlight, numbered steps, crop,
  backgrounds and padding
- Auto Redact: finds emails, phone numbers, API keys, passwords and more in the image and blurs just those words
- Copy text (OCR) and QR codes from anything on screen
- Pin screenshots on top of other windows; Quick Access overlay; searchable capture history

![Annotate: numbered steps, a highlight, a blurred line and an arrow over a screenshot with a gradient background](docs/images/annotate.png)

**Recording**
- Record a display, a window, an area or a connected iPhone / iPad (USB)
- Camera bubble, microphone and system audio (per app), keystrokes and click highlights, speaker notes / teleprompter
- GIF export, MP4 export, crash recovery for interrupted recordings

**Studio editor** (for "Studio" recordings)
- Smooth cursor (styles, size, motion blur, click effects and sounds), automatic zooms that follow the cursor
- Typing detection with one-click speed-up; cut, trim, split and speed up clips
- Backgrounds (macOS wallpapers, gradients, images), padding, rounded corners, shadows, any aspect ratio
- Camera layouts (camera only, screen only, custom position), blur and highlight masks that find sensitive text
- Background music, noise reduction, loudness normalization
- "Fill the frame and follow the cursor" for vertical or square video, and several formats in one export
- Presets, Quick Export right after recording, keyboard shortcuts for everything

![The Studio editor: preview, cursor settings, and a timeline with typing, keystroke, clip and zoom tracks](docs/images/studio-editor.png)

Interface languages: English, Tiếng Việt, 한국어, 日本語, 简体中文.

## Shortcuts

Global shortcuts, out of the box (change or add more in **Settings › Shortcuts**; Pause / Resume, Restart, markers,
speaker notes and more are available there without a default):

| Action | Shortcut |
|---|---|
| All-in-one capture bar | `⌥⇧⌘5` |
| Capture area | `⌥⇧⌘4` |
| Capture full screen | `⌥⇧⌘3` |
| Capture window | `⌥⇧⌘W` |
| Capture previous area | `⌥⇧⌘7` |
| Scrolling capture | `⌥⇧⌘8` |
| Capture text (OCR) | `⌥⇧⌘2` |
| Record screen / stop recording | `⌥⇧⌘6` |
| Hide / show desktop icons | `⌥⇧⌘D` |
| Restore recently closed | `⌥⇧⌘Z` |

**Quick Access cards** — hover a card, then press:

| Action | Key |
|---|---|
| Copy | `⌘C` |
| Save (hold `⌥` for the other save mode) | `⌘S` |
| Annotate / edit | `⌘E` |
| Pin to the screen | `⌘P` |
| Quick Look | `Space` |
| Move to Trash | `⌘⌫` |
| Close | `⌘W` or `Esc` |

The Studio editor has its own shortcuts (all remappable): press `⌘/` in the editor to see them.

## Automation (URL scheme)

Launchers, scripts and the Shortcuts app can drive Daisyshot through `daisyshot://` URLs, for example
`open "daisyshot://capture-area?action=copy"`. The first time another app sends a command, Daisyshot asks before
running it; turn the API off in **Settings › Advanced**.

| Command | What it does |
|---|---|
| `capture-area` | Capture an area (`x`, `y`, `width`, `height` in points and `display` capture it without selecting) |
| `capture-previous-area` | Capture the last area again |
| `capture-fullscreen` | Capture a whole display (`display`: 1, 2…) |
| `capture-window` | Capture a window |
| `all-in-one` | Open the all-in-one bar |
| `self-timer` | Capture after a countdown |
| `scrolling-capture` | Scrolling capture (`start`, `autoscroll`: true / false) |
| `capture-text` | Copy text (OCR) from the screen or from `filepath`; `linebreaks`: true / false |
| `record-screen` | Start a recording, or stop the running one |
| `stop-recording` | Stop the running recording |
| `pin` | Pin `filepath` (or choose an image) on screen |
| `open-annotate` | Annotate `filepath` (or choose a file) |
| `open-from-clipboard` | Annotate the image on the clipboard |
| `add-quick-access-overlay` | Show `filepath` in a Quick Access card |
| `open-history` | Open the capture history |
| `restore-recently-closed` | Bring back the last closed Quick Access card |
| `close-all-overlays` | Close every Quick Access card |
| `toggle-desktop-icons`, `hide-desktop-icons`, `show-desktop-icons` | Desktop icons |
| `open-settings` | Open Settings (`tab`: general, shortcuts, quickAccess, wallpaper, screenshots, screenRecording, annotate, advanced, about) |

The capture commands also take `action` = `copy`, `save`, `annotate` or `pin` to override the After Capture settings.

## Security and privacy

Daisyshot works offline: no accounts, no analytics, no cloud. Screenshots and recordings stay on your Mac, in the folders
you choose and in `~/Library/Application Support/Daisyshot`.

- **Network:** its only request is the update check — once a day it asks GitHub for the latest release (turn it off in
  **Settings › General**); nothing about you or your files is sent. An update is downloaded only when you install it, and
  it's installed only if it carries Daisyshot's Ed25519 release signature and is the expected app and version.
- **Code:** the app runs with the macOS Hardened Runtime and isn't sandboxed (screen capture, global shortcuts and
  keystroke logging need that). Releases are ad-hoc signed and not yet notarized by Apple.
- **Automation:** `daisyshot://` commands from other apps need your OK the first time and can be turned off.

It asks for these macOS permissions, each only for the features that need it:

| Permission | Used for |
|---|---|
| Screen & System Audio Recording | Taking screenshots and recording the screen |
| Accessibility | Keystrokes in recordings, typing detection, hiding the cursor while typing, bringing windows to the front |
| Camera / Microphone | The camera bubble and voice in recordings |

Found a security problem? Please report it privately — see [SECURITY.md](SECURITY.md).

## Uninstall

Quit Daisyshot, then:

```bash
rm -rf /Applications/Daisyshot.app
```

To also remove its settings and permissions:

```bash
defaults delete app.daisyshot.mac; tccutil reset All app.daisyshot.mac
```

`~/Library/Application Support/Daisyshot` holds your capture history, recordings and presets — delete it only if you no
longer need them. To reset permissions without uninstalling, run just `tccutil reset All app.daisyshot.mac`.

## Build from source

Requirements: Xcode 26 (Swift 6, macOS 26 SDK). No third-party dependencies.

```bash
swift build                      # debug build
./scripts/build-app.sh           # signed app bundle in build/Daisyshot.app (ad-hoc unless SIGN_ID is set)
./scripts/make-dmg.sh            # disk image for distribution
```

Releases: `swift scripts/update-key.swift generate` once (creates the signing key outside the repository and prints
the public key to put in `Updater.publicKey`), then bump `VERSION`, write the notes and run
`./scripts/release.sh notes.md` — it builds the disk image and the signed update archive and publishes the GitHub release.

Built-in checks run with `DAISYSHOT_SELFTEST=1 .build/debug/Daisyshot` (it prints PASS / FAIL per area and quits).
Translations are checked with `python3 scripts/loc-check.py`.

Code layout (`Sources/Daisyshot`):

| Folder | What's in it |
|---|---|
| `App` | App delegate, global shortcuts, preferences, URL scheme API, permissions, updates |
| `Capture` | Screenshot capture, selection overlay, scrolling capture, OCR |
| `Annotate` | The annotation editor, backgrounds, Auto Redact |
| `Recording` | Recorder, recording setup, Studio editor (model, renderer, timeline, export) |
| `UI` | Quick Access, pins, history, shared UI |
| `Settings` | Settings window and panes |

## Contributing

Bug reports, fixes and translations are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).

## License and name

The source code is licensed under the [MIT License](LICENSE), © 2026 Tam Hoang.

The name **Daisyshot** and the Daisyshot logo and app icon are not covered by the MIT License. You're welcome to fork
and redistribute the code, but please give your version a different name and icon so people don't mistake it for the
official app.
