# Pocket3Bar

A macOS menu bar controller for the **DJI Osmo Pocket 3** while it's plugged in as a USB webcam: gimbal moves, zoom, roll, presets, smooth face tracking, and a panel that pops open when a meeting turns the camera on.

It uses only the camera's standard USB webcam (UVC) controls. No DJI software, no firmware changes, no Bluetooth.

> Not affiliated with or endorsed by DJI. Built by vibe coding with Claude, and tested on one Pocket 3 and one Mac. Treat it as a hobby project.

<!-- TODO: add a screenshot of the menu and a short demo clip -->

## Features

| | |
| --- | --- |
| **Gimbal** | Press-and-hold pan/tilt, Level, and Hold/Release |
| **Lens** | Zoom 1–4× and roll |
| **Presets** | Four saved views: click to recall, ⌥-click to save |
| **Face tracking** | Follows the point between your eyes and glides there smoothly; keeps running with the menu closed |
| **Live preview** | 16:9 preview with the face box and eye line |
| **Meeting auto-open** | When Zoom, Meet, FaceTime or any other app turns the camera on, the menu pops open |
| **Web panel** | The same controls in a browser at `http://localhost:8765` |

## Requirements

- macOS 14 or later (built and tested on macOS 15, Apple silicon)
- Apple's Command Line Tools: `xcode-select --install`
- Python 3 (the Command Line Tools include one; Homebrew's works too). The server uses only the standard library.
- A DJI Osmo Pocket 3 connected over USB-C and switched to webcam mode

## Build and install

```bash
git clone <this repo>
cd pocket3bar
./scripts/make-signing-identity.sh   # optional, once: keeps the camera permission across rebuilds
./build.sh --install                 # builds and copies Pocket3Bar.app to ~/Applications
open ~/Applications/Pocket3Bar.app
```

- The first time you turn on the preview or tracking, macOS asks for camera access. Allow it.
- To start it with your Mac, tick **Open at login** in the menu.
- Without the signing identity the app is signed ad-hoc, which works, but macOS asks for camera access again after every rebuild.

## Using it

- **Before you start:** turn **ActiveTrack off on the camera**, or it will fight the Mac's tracking and any position you hold.
- **Front / selfie:** switched on the camera itself. Moves stay on the side it's facing.
- **Keep the body fairly upright:** if the camera body leans far forward (roughly past 45°), a move can flip it from selfie to front.
- **Holding:** the gimbal only stays where you point it while **Holding** is on. **Release** hands framing back to the camera.
- **Portrait:** if the Pocket 3's screen is turned vertical it sends portrait video, and most apps show only its middle strip. Tracking accounts for that, but turning the screen horizontal gives meetings the full picture.
- **Links you can call from scripts or Shortcuts:** `open pocket3bar://show` · `open pocket3bar://track` · `open pocket3bar://track-off`

## How it works

```
Pocket3Bar (SwiftUI menu bar app)
 ├─ video  ← AVFoundation from the Pocket 3 → Vision face landmarks → eye point
 ├─ HTTP   → panel server (Python, 127.0.0.1:8765, bundled in the app)
 │            └─ runs uvcctl (C, IOKit) → UVC control requests over USB → gimbal / zoom / roll
 └─ meeting watch: AVCaptureDevice.isInUseByAnotherApplication → pop the menu open
```

- **Holding a position:** the Pocket 3 only holds a commanded position while it keeps receiving it, so the server re-sends the target about 6 times a second.
- **Smooth tracking:** the app sends a pan/tilt *speed* about 10 times a second. The server eases between speeds and moves the gimbal in small sub-degree steps about 25 times a second.
- **Data and logs:** presets are saved to `~/Library/Application Support/Pocket3Bar/`. Logs go to `~/Library/Logs/Pocket3Bar.log` and `Pocket3Bar-server.log`.

Notes on what we found about the camera, including what didn't work, are in [docs/FINDINGS.md](docs/FINDINGS.md).

## Repository layout

```
app/        Pocket3Bar.swift (the whole menu bar app), Info.plist
server/     server.py (panel server + API), panel.html (web panel), uvcctl.c (USB helper)
scripts/    make-signing-identity.sh
build.sh    builds build/Pocket3Bar.app (--install copies it to ~/Applications)
```

## License

MIT. See [LICENSE](LICENSE).
