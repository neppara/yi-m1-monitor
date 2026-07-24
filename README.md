# YI M1 Camera Control

Reverse-engineered remote control and field monitor for the **Xiaomi YI M1**
mirrorless camera, with two independent apps built on the recovered protocol:

- **macOS** — a desktop monitor app (Python + PySide6)
- **iOS** — an on-camera field monitor (Swift + SwiftUI)

The camera's control protocol (BLE pairing + HTTP/UDP over Wi-Fi) is not
documented anywhere. It was recovered entirely by experiment — disassembling the
firmware, decompiling the official Android app, and live testing on real
hardware. The protocol write-up is arguably the most useful part of this repo
(see [Protocol & findings](#protocol--findings)).

> **Disclaimer.** Unofficial project, not affiliated with, authorized, or
> endorsed by Xiaomi or YI Technology. Built from independent analysis for
> interoperability with a camera the author owns. The camera firmware and the
> official app are **not** included in this repository. Provided "as is",
> without warranty — use at your own risk.

---

## What it does

Both apps turn a laptop/phone into a camera monitor and remote:

- Live view over Wi-Fi (UDP MJPEG stream)
- Remote shutter and video recording
- Full settings panel (ISO, shutter, aperture, EV, WB, exposure/metering/focus
  mode, color profile, quality, aspect, file format, drive mode)
- File browser: thumbnails, multi-select, batch download/delete, preview
- Operator aids: focus peaking, thirds/diagonals guides, real capture-area crop
  outline with dimming, manual rotation for vertical shooting
- Recording timer and **near-continuous recording** (auto-restart around the
  camera's own file-size limit)

The iOS app additionally has a landscape on-camera-monitor layout and a
two-tap inline settings picker; the macOS app additionally restores your
previous Wi-Fi network on disconnect.

---

## Requirements

**This works with a Xiaomi YI M1 only.** Everything was verified against
firmware **`3.2-int`** (OEM: Xacti). Other firmware versions are untested — the
protocol is likely the same but not guaranteed.

The camera serves **one client at a time**, so disconnect the official app
first. The camera's Wi-Fi access point is at a fixed address (`192.168.0.10`).

### macOS app

- macOS 12+, Bluetooth + Wi-Fi
- Python 3.9+

```sh
cd yi-m1-remote-control
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
python3 app/main.py
```

Or build a double-clickable `.app`:

```sh
pip install -r requirements-dev.txt
python3 -m PyInstaller --noconfirm --distpath ~/Applications YiM1Monitor.spec
```

The `.app` is unsigned, so the first launch is **right-click → Open** (Gatekeeper).
Approve the Bluetooth and Local Network prompts. Diagnostics are logged to
`~/Library/Logs/YiM1Monitor.log`. See [`BUILD_MACOS_APP.md`](yi-m1-remote-control/BUILD_MACOS_APP.md).

### iOS app

Requires a **Mac with Xcode** — there is no pre-built `.ipa` (Apple code
signing). A free Apple ID works for sideloading (the build expires after ~7
days and must be rebuilt).

```sh
cd yi-m1-ios
brew install xcodegen        # if not installed
xcodegen generate            # generates the .xcodeproj from project.yml
open YiM1Monitor.xcodeproj    # set your signing team, then build to your iPhone
```

Core protocol logic lives in the `YiM1Core` Swift package and is unit-tested
(`swift test`, 53 tests) — no camera required to run those.

---

## Connecting to the camera

1. Wake the camera. In the app, **Connect (Bluetooth)** — accept the pairing
   prompt on the camera screen. The app reads the (per-session) Wi-Fi password.
2. Join the camera's Wi-Fi network (the app shows the credentials).
3. **Turn Bluetooth OFF during the session.** The phone shares one 2.4 GHz
   antenna between Bluetooth and Wi-Fi; leaving BT on measurably stutters the
   live view (see [findings](#protocol--findings)).
4. The **video format can be set remotely** — including `24p`, which the camera's
   own menu does not offer (see [Protocol & findings](#protocol--findings)).

---

## Limitations

- Tested on one camera / firmware (`3.2-int`).
- Video is recorded as H.264 **Constrained Baseline** (no B-frames, no CABAC) at a
  fixed bitrate, and **this cannot be changed** — not by us, and not by reflashing the
  main firmware. The encoder parameters are not in the main image at all; they live in
  the Xacti subprocessor's own firmware, which `firmware.bin` does not contain. Four
  independent searches establish this (`2160` never appears in `.rodata`, the 4.2 MB
  `ND1` blob is fonts, and the `.ROM.*` sections are just the compressed copies of the
  three sections we already have). See `fable research/firmware-memory-map.md`.
- Recording is capped by a **4 GB file limit** (FAT32): ~7.5 min in 4K. The
  app's auto-restart works around it with a ~2 s gap between clips; the camera
  does **not** split files seamlessly.
- iOS automatic Wi-Fi join needs a **paid** Apple Developer account (the Hotspot
  Configuration capability); the free-tier build uses a manual join sheet.
- The camera serves one client at a time.

---

## Protocol & findings

The recovered protocol and the empirical camera behavior are documented in:

- `fable research/firmware-memory-map.md` — **read this before opening the firmware in
  a disassembler**: the full section map, and the `.data` section everyone (us included)
  forgets to load — without it no string cross-reference resolves.
- `fable research/rcvideoformatset-solved.md` — how the video-format
  command was recovered from the firmware, the full parameter-key pool, and the
  hardware verification.
- `fable research/` — the rest of the reverse-engineering write-ups (BLE handshake,
  HTTP command table, UDP frame format, live-testing log, RAW-video feasibility).
- `yi-m1-remote-control/app/ARCHITECTURE.md` — macOS architecture + a bug-by-bug
  history ("don't step on these rakes again").
- `yi-m1-ios/DEVELOPMENT_PLAN.md` — iOS design decisions and the multi-round
  live-view stability investigation.
- `PROJECT_SUMMARY.md` — a high-level tour of the whole project.

Highlights worth knowing before working with this camera:

- **A hidden 240 fps slow-motion mode.** `VGA_240` records 640×480 at ~240 fps and
  the camera conforms it to a 30 fps file itself — a 3-second take came back as a
  690-frame, 23-second clip, i.e. ~8× slow motion straight off the card. The YI M1
  has no slow-motion mode in any menu.
- **Remote video-format switching, including 24p.** `RCVideoFormatSet` takes the
  parameter key **`Resolution`** (not `VideoFormat`) — recovered by disassembling
  the handler at `0x0015641c`, then confirmed on hardware and verified with
  `ffprobe` on the recorded files. Working values: `4K_30`, `2K_30`, `FHD_60`,
  `FHD_30`, `FHD_24`, `720P_60`, `720P_30`, `720P_24`, `VGA_240`. `4K_24` and
  `4K_30_LOW` are accepted (HTTP 200) but the camera reverts them to `4K_30` on
  record — **4K is locked to 30p** — so they are not offered. **1080p24 and 720p
  appear in no menu on the camera** and were never supported by the official app.
- **Stabilisation, audio, mic noise reduction and mic level are controllable too.**
  `RCEisSwitchSet` / `RCVASwitchSet` / `RCVANoiseReduceSet` take the key `Operate`
  with **uppercase** `ON`/`OFF`; `RCVAVolSet` takes `Vol`. All four were previously
  recorded — by us and by everyone else — as dead commands that return 404.
- Extra shutter speeds the API accepts but the menus don't list: `1/8000s`,
  `1/6400s`, `1/5000s`.
- Command failures are reported as **HTTP 200 with `{"code":<err>}` in the body**
  — and success is `code: 200`, not `code: 0`. Transport status alone lies.
- A command sent **without its required parameter returns the same 404** as a
  command that does not exist. This is why the video setters looked "unrouted"
  for so long — a negative result from live probing is not proof of impossibility.
- The camera **throttles live view to ~7.5 fps while recording** (to feed the
  encoder) — this is normal, and is used as a signal to detect when it stops.
- Measured sensor crops per video mode (2K = full 4:3 frame, FHD = 16:9 photo
  crop, 4K = ~74%×56% near-native readout).
- **RAW video is impossible** on this camera by software alone — see
  `fable research/final-assessment.md` for the evidence (USB is Mass-Storage-only,
  the required write bandwidth is ~700–870 MB/s, the official app sends no
  video-format commands, and the firmware repack tool isn't byte-identical).

---

## Acknowledgements

This project stands on earlier community reverse-engineering work. No third-party
code is included here — the apps were written from scratch — but the following
prior work was invaluable as a starting point for understanding the protocol,
and the findings were independently re-verified against real hardware:

- **[bullbin/xiaoyi_m1_re_liveview](https://github.com/bullbin/xiaoyi_m1_re_liveview)**
  — the key predecessor: BLE pairing, the Wi-Fi HTTP protocol, and the UDP live-view
  decoder.
- **Qgrade/Yi-M1-mirrorless** — a fuller HTTP command table, credited in bullbin's
  work. The repository has since been deleted; it was reconstructed here from live
  testing rather than the original source.
- **[fujihack](https://github.com/fujihack/fujihack)** / Daniel Cook (*petabyt*)
  — firmware reverse-engineering methodology for the same OEM (Xacti) Fujifilm
  X-series lineage; used as an approach, not as code.

See [`fable research/related-projects-and-community.md`](fable%20research/related-projects-and-community.md)
for the full survey of prior art.

## License

[MIT](LICENSE). Covers the code and documentation in this repository. It does
**not** cover — and this repo does not include — the camera firmware, the
official app, or any manufacturer material.
