# YI M1 Monitor — iOS app development plan

Status: not started (written 2026-07-07). This is the authoritative build spec. Agents
starting cold should read Parts 0–4 in full before writing code, then pick up tasks from
Part 5. The protocol is **fully reverse-engineered and confirmed working** — this is a port,
not research.

The reference implementation is the working macOS app at
`../yi-m1-remote-control/` (Python/PySide6). When this doc says "port from X", read that file —
it is the source of truth for behavior. Do not re-derive protocol details; they are all here
or there.

---

## Part 0 — Non-negotiable facts (read first, do not re-litigate)

These are all confirmed live against the real camera (a Xiaomi YI M1, firmware 3.2-int). Full
evidence is in `../fable research/live-testing-findings.md` and `../yi-m1-remote-control/app/ARCHITECTURE.md`.

1. **Connection path**: BLE pairing (get Wi-Fi credentials) → join the camera's Wi-Fi AP →
   HTTP JSON control at `http://192.168.0.10` + UDP live-view stream on port `54321`.
2. **The camera accepts exactly ONE client at a time** (BLE and Wi-Fi). Consequence: you
   **cannot run the iOS app and the macOS app against the camera simultaneously** — testing
   is one device at a time. Also: BLE stops answering pairing once a Wi-Fi client is already
   attached (hence the macOS app's "direct connect" path; replicate it).
3. **The camera's touchscreen locks during a Wi-Fi session** ("Wi-Fi connected" screen, all
   buttons dead). So the physical camera cannot be adjusted while the app is connected.
4. **Video format/resolution cannot be changed remotely by any means** (`RCVideoFormatSet` and
   a format param on `VideoRecordingStart` both proven dead). Video mode/resolution must be set
   on the camera *before* connecting. In-app, video format is **read-only display**.
5. **Exposure/look settings are shared between photo and video** (ISO/WB/shutter/aperture/EV/
   exposure-mode/metering/focus-mode/color-style all apply to both — proven via a NaturalBW
   video test). Photo-only settings (quality/aspect/format/drive) concern the still file.
6. **The Photo/Video toggle is a real free switch**: both `RCDoShooting` (photo) and
   `VideoRecordingStart` (video) work in a single connected session regardless of the camera's
   physical mode.
7. **The Wi-Fi password is randomized every session** (SSID is stable, `YI_M1_xxxxxx`). You get
   fresh credentials from BLE each time.
8. **`ImageAspect` metadata lies**: the live-view metadata's `ImageAspect` field appears to
   always report `4:3` regardless of the real setting. `RCImageAspect` genuinely works (proven
   by the crop measurements), so trust the user's last request for that field indefinitely
   rather than reverting to metadata (macOS `NEVER_EXPIRE_METADATA_KEYS`).
9. **`GetFileList` needs a non-zero id range** or the camera returns `{"code":1502,"data":"get
   filelist err"}`. Always send `range_start=0, range_end=9999`. `filetype` and RC-session
   state don't matter.
10. **Measured crop rectangles exist** (empirically, via tripod + template matching) for the
    overlays — values in Part 4.

### iOS-specific advantages / differences vs macOS
- **Wi-Fi join: manual by default, no paid developer account needed (DECIDED 2026-07-07).**
  `NEHotspotConfiguration` (true programmatic auto-join) requires the Hotspot Configuration
  entitlement, which needs a paid Apple Developer Program membership. Since the user does not
  have one, the default/v1 implementation is a **manual join flow** instead — see Part 4.2 for
  the exact design. This needs zero special entitlements: CoreBluetooth, local networking, and
  `UIApplication.openSettingsURLString` all work on a free Apple ID / personal team. **If a
  paid account becomes available later, auto-join is a small isolated swap** behind the same
  `WiFiConnector` role in `CameraSessionProtocol` — nothing else in the app changes.
- An iPhone with cellular keeps internet over LTE/5G while locally on the camera Wi-Fi — the
  "you lose internet when you connect" problem largely disappears. (iOS routes local-subnet
  traffic to Wi-Fi, everything else to cellular.) This holds regardless of which join method is used.
- **Local Network privacy** (iOS 14+): reaching `192.168.0.10` and receiving UDP triggers the
  Local Network permission prompt. Must be handled; without it, both HTTP and UDP silently
  fail. This is the #1 iOS gotcha — validate it first (see Part 8).

---

## Part 1 — Platform & project decisions

- **Language/UI**: Swift + SwiftUI. Concurrency via `async/await` + actors.
- **Min deployment**: iOS 16.0 (modern SwiftUI; CoreBluetooth, `Network.framework`, and
  `UIApplication.openSettingsURLString` are all available well below this floor).
- **Frameworks**: SwiftUI, CoreBluetooth (BLE), Network (UDP via `NWConnection`/`NWListener` or
  a raw `UDP` socket), Foundation `URLSession` (HTTP), UIKit only where SwiftUI can't reach
  (`UIApplication.openSettingsURLString`, `UIPasteboard`). NetworkExtension is **not** part of
  the v1 build (see Wi-Fi join decision above) — keep `WiFiConnector`'s public interface
  hospitable to adding it later without touching callers.
- **Project layout**: create a real Xcode project `YiM1Monitor` in this `yi-m1-ios/` directory
  (`YiM1Monitor.xcodeproj` + a Swift-package-style folder structure inside, or an SPM local
  package for the protocol layer — see Part 2).
- **Entitlements**: **none required for v1.** No paid Apple Developer Program membership
  needed — a free Apple ID (personal team in Xcode) is sufficient to build and run on your own
  device (standard 7-day signing renewal applies, just re-run from Xcode periodically). If
  auto-join is added later (paid account), add `com.apple.developer.networking.HotspotConfiguration`
  then — not before.
- **Info.plist keys**:
  - `NSBluetoothAlwaysUsageDescription` — BLE pairing.
  - `NSLocalNetworkUsageDescription` — HTTP + UDP to the camera on the local subnet.
  - `NSBonjourServices` — likely **not** needed (we talk to a fixed IP, not Bonjour), but the
    Local Network prompt is still triggered by the traffic; validate.
  - App Transport Security: add an ATS exception so plain-HTTP to `192.168.0.10` is allowed —
    `NSAppTransportSecurity` → `NSAllowsLocalNetworking = true` (preferred) or an
    `NSExceptionDomains` entry.
- **Testing reality**: Local Network permission **does not work in the iOS Simulator** for
  real local traffic, and CoreBluetooth pairing needs real hardware regardless. On-device
  testing is mandatory for anything past the protocol-parsing unit tests. And per fact #2, the
  camera serves one client — coordinate so the Mac app is disconnected during iOS testing.

---

## Part 2 — Architecture & module map

Mirror the macOS separation: a UI-agnostic protocol/session core, a design system, and the
SwiftUI layer. Recommended: put the core in a **local Swift package** `YiM1Core` so it builds
and unit-tests without the app/UI.

```
YiM1Core (local SPM package, no UIKit/SwiftUI)
├── Commands.swift        # command builders + setting enums (port of prot_http/*)
├── CameraMetadata.swift  # parse the 2048-byte live-view JSON header
├── HTTPClient.swift      # send commands, parse JSON, raw+streaming download
├── BLEPairing.swift      # CoreBluetooth: scan → pair → read Wi-Fi creds
├── WiFiConnector.swift   # v1: manual-join sheet + reachability poll (no entitlement needed)
├── LiveViewReceiver.swift# UDP 54321 reassembly → (metadata, jpegData) stream
└── CameraSession.swift   # actor/ObservableObject orchestrating all of the above

YiM1Monitor (the app target, SwiftUI)
├── Design/
│   ├── Theme.swift       # tokens ported from ../yi-m1-remote-control/app/theme.py
│   └── Icons.swift       # SF Symbols map (+ any custom Canvas shapes)
├── Views/
│   ├── RootView.swift        # shell: status bar, mode toggle, live view, controls
│   ├── LiveViewCanvas.swift  # live JPEG + overlays (crop/thirds/diagonals) + tap-to-focus
│   ├── ShutterButton.swift   # photo shutter / video record circle
│   ├── ModeToggle.swift      # Photo/Video segmented
│   ├── GuideToggles.swift    # Crop / Thirds / Diagonals
│   ├── SettingsStrip.swift   # mode-aware settings, bottom sheet or strip
│   ├── FileBrowserView.swift # list/download/delete with progress
│   └── ConnectionMenu.swift  # connect (BLE) / connect (on Wi-Fi) / disconnect / reset
├── ViewModels/ (if not using CameraSession directly as the ObservableObject)
└── App.swift + Info.plist + entitlements
```

### Dependency graph (what must exist before what)
- `Commands`, `CameraMetadata` — **leaf**, no deps. Build first.
- `HTTPClient`, `BLEPairing`, `WiFiConnector`, `LiveViewReceiver` — depend on leaves; mutually
  independent, **parallelizable**.
- `CameraSession` — depends on all core modules.
- `Theme`, `Icons` — **fully independent**, parallelizable with everything.
- Views — depend on `Theme`/`Icons` + a **`CameraSessionProtocol`** (Part 3). Can be built
  against a mock conforming to that protocol before `CameraSession` is done.

### Suggested parallel agent split
- **Agent A — Core protocol**: `Commands`, `CameraMetadata`, `HTTPClient`, `LiveViewReceiver`
  (+ their unit tests). Self-contained, high value, no UI.
- **Agent B — Connectivity**: `BLEPairing` (CoreBluetooth) + `WiFiConnector` (v1 manual-join
  flow, no entitlement) + the Local Network / Info.plist plumbing. This is the riskiest
  iOS-specific area — give it to whoever validates permissions on-device early.
- **Agent C — Design + UI**: `Theme`, `Icons`, and all `Views/` built against the
  `CameraSessionProtocol` mock. Delivers a fully clickable UI with fake data.
- **Agent D — Integration**: `CameraSession` (the orchestrator) once A/B land, then wire the
  real session into C's views, then on-device end-to-end. Also owns the Xcode project setup.

Coordination anchor: **all four agents must agree on Part 3's contracts before starting.**
Freeze those types first (one short task), then parallelize.

---

## Part 3 — Interface contracts (freeze these FIRST)

These are the seams that let agents work in parallel. Define them as the very first task; do
not change signatures unilaterally afterward.

### 3.1 `CameraSessionProtocol` (what the UI binds to)
An `ObservableObject` (or an actor fronted by one) exposing published state + intent methods.
UI (Agent C) codes against this; Agent D provides the real impl and a mock for previews/tests.

```swift
enum ConnectionState { case disconnected, pairing, switchingWiFi, connecting, connected, error(String) }
enum CaptureMode { case photo, video }

protocol CameraSessionProtocol: ObservableObject {
    // Published state
    var connectionState: ConnectionState { get }
    var latestFrame: CGImage? { get }              // decoded live-view JPEG
    var metadata: CameraMetadata? { get }          // latest parsed header
    var status: CameraStatus? { get }              // battery, shots left
    var isRecording: Bool { get }
    var mode: CaptureMode { get set }              // free switch (fact #6)

    // Connection
    func connectViaBLE()
    func connectDirect()      // already on camera Wi-Fi (skip BLE)
    func disconnect()
    func reset()              // abandon a stuck attempt, start clean

    // Capture
    func shootPhoto()         // RCDoShooting + fetch preview for review
    func toggleRecording()    // VideoRecordingStart/Stop
    func focus(atImagePoint: CGPoint)  // RCDoFocus Manual, image-pixel coords

    // Settings (generic - one path for every dropdown)
    func setSetting(_ key: SettingKey, value: String)   // value = enum RAW api value

    // Photo review (chimp view) + file ops report via published state or callbacks
    var photoReview: PhotoReviewState { get }     // .idle / .downloading(progress) / .ready(CGImage)

    // Files
    func listFiles() async -> [CameraFile]
    func downloadFile(_ path: String, to url: URL, progress: (Double) -> Void) async throws
    func deleteFile(_ path: String) async
}
```

### 3.2 Core value types
```swift
struct WiFiCredentials { let ssid: String; let password: String }
struct CameraStatus { let batteryLevel: String; let shotsLeft: String; let lensVer: String }
struct CameraFile { let path: String; let date: Date; let filetype: String; let isProtected: Bool }
enum SettingKey: String { case exposureMode="ExposureMode", iso="ISOSetting", shutter="ShutterSpeed",
    aperture="Fnumber", ev="EV", wb="WB", metering="MeteringMode", focus="FocusMode",
    color="ColorMode", quality="ImageQuality", aspect="ImageAspect", format="FileFormat",
    drive="DriveMode" }   // raw = the metadata field name (also used to read current value)
```
`SettingKey.rawValue` intentionally equals the metadata field name so the same key reads the
current value and identifies the command (see the macOS `_setting_defs`).

### 3.3 Design tokens (`Theme`)
Port the values from `../yi-m1-remote-control/app/theme.py` verbatim (single source — if these
ever change, change both). See Part 4.4 for the literal values.

---

## Part 4 — Protocol reference (implement exactly)

### 4.1 BLE pairing (CoreBluetooth) — port of `../yi-m1-remote-control/prot_ble/ble_keyhack.py`
Service UUID: `41106dd9-25ad-477b-a884-5038b6de4649`. Characteristics (128-bit):
| Name | UUID | Use |
| --- | --- | --- |
| PAIRING_INIT | `41106da0-...` | write pairing request |
| RESPONSE_TOKEN | `41106da1-...` | (unused in flow) |
| FIRMWARE_INFO | `41106da2-...` | read: `"proto,body,variant[,lens]"` |
| START_SESSION | `41106da4-...` | write session-start params |
| WIFI_SWITCH | `41106da5-...` | write `"ON"` to enable AP |
| WIFI_AP_KEYSHARE | `41106da6-...` | read: `"SSID,password"` |
| PAIRING_NOTIF | `41106da7-...` | notify: pairing token (or empty = denied) |
| RESUME_RELATED | `41106dad-...` | write `"3"` (only if `daf` present) |
| UNK_NOTIFY_0 | `41106dae-...` | notify (lens info) |
| UNK_NOTIFY_F | `41106daf-...` | notify; if present, do the `dad`/`dae`/`daf` extra step |

(All share the `...25ad-477b-a884-5038b6de4649` suffix.) Standard GATT Device-Name char is NOT
exposed on 3.2-int — tolerate read failures for name/manufacturer/model (informational only).

Exact sequence:
1. Scan for peripherals advertising the service UUID. Pick strongest RSSI. **Verify the service
   UUID is actually in the advertisement** (don't trust CoreBluetooth's scan filter alone —
   false positives observed).
2. Connect, discover services + characteristics.
3. Read FIRMWARE_INFO → ASCII, split on `,`. `proto = int(parts[0])`, `body = parts[1]`. Detect
   whether UNK_NOTIFY_F (`daf`) exists → `requiresFUuid`.
4. Pairing: `key = String(Int.random(in: 0...99998))`. `params = "\(proto),\(key),android"`.
   Subscribe to PAIRING_NOTIF, then write `params` (ASCII) to PAIRING_INIT (with response).
   **Camera shows an on-screen Accept prompt — user must tap it.** Wait for the notify: a
   non-empty ASCII string is the `token` (success); empty = denied. **Timeout 30s** on this
   wait; **90s overall ceiling** on the whole handshake.
5. Session start: `payload = "1" + key + token` (ASCII). `checksum = CRC32(payload)`.
   `params2 = "\(proto),\(key),\(checksum)"`. Write to START_SESSION (with response). If
   `requiresFUuid`: subscribe to `daf` and `dae`, then write `"3"` to RESUME_RELATED (`dad`).
6. Wi-Fi: read WIFI_AP_KEYSHARE → ASCII, split `,` → `[ssid, password]`. Write `"ON"` to
   WIFI_SWITCH. Sleep ~1s. Return `WiFiCredentials`.
CRC32 = standard zlib/IEEE CRC-32 (match Python `zlib.crc32`). Use a small Swift CRC32 (or
zlib via `import Compression`/manual table). Verify against a known vector.

### 4.2 Wi-Fi join — manual flow (v1, no entitlement needed) — DECIDED 2026-07-07
No `NEHotspotConfiguration` in v1 (no paid developer account — see Part 1). Instead:

1. After BLE pairing returns `WiFiCredentials(ssid, password)`, present a **"Connect to camera
   Wi-Fi" sheet**: show the SSID and password as large, legible text (this is a fresh random
   password every session — the user cannot know it in advance, so it must be readable/
   copyable, not just implied).
2. Sheet actions:
   - **"Copy password"** → `UIPasteboard.general.string = password` (so the user can paste it
     into the Wi-Fi password field instead of retyping a random string).
   - **"Open Wi-Fi Settings"** → `UIApplication.shared.open(URL(string:
     UIApplication.openSettingsURLString)!)`. This is the official, entitlement-free API; it
     opens *this app's* page in Settings, not the Wi-Fi pane directly (iOS doesn't allow
     deep-linking straight into Wi-Fi without an entitlement) — the user taps "Wi-Fi" from
     there themselves. One extra tap, fully sanctioned, no private API risk.
   - **"I've connected"** (or auto-triggered — see below) → start the reachability poll.
3. **Reachability poll** (mirrors the macOS fix of never trusting the join mechanism's own
   success signal, just checking the actual thing needed): while the sheet is open, poll
   `GetCameraStatus` on `192.168.0.10` every ~1.5s in the background. The moment it returns
   200, auto-dismiss the sheet and proceed to `RCStartRemoteCtl` — the user doesn't need to
   tap "I've connected" if the poll already succeeded, but keep the button as a manual nudge
   in case the poll is paused (e.g. app backgrounded while the user is in Settings.app).
4. **Direct-connect path** (fact #2, mirrors the macOS "already on camera Wi-Fi" button): if
   the phone is already joined to a `YI_M1_*` network (check via `NEHotspotNetwork` read access
   or simply attempt the reachability poll immediately on app launch/a "Connect directly"
   button), skip BLE and the sheet entirely — go straight to `GetCameraStatus` →
   `RCStartRemoteCtl`.
5. **Disconnect**: nothing to programmatically "leave" (we never joined programmatically) —
   just call `RCStopRemoteCtl` and stop the UDP listener. Optionally show a one-line reminder
   ("Rejoin your regular Wi-Fi in Settings") since the phone is still on the camera's network.

**Upgrade path (not v1)**: if a paid account is added later, add an `NEHotspotConfiguration`
implementation behind the same `WiFiConnector` role — `connectViaBLE()`/`connectDirect()` in
`CameraSessionProtocol` don't change at all, only what happens internally between "got
credentials" and "reachable" does. Keep that seam clean now so it's a drop-in later:
```swift
protocol WiFiJoining {
    func join(ssid: String, password: String) async  // manual v1: shows the sheet, awaits the poll
                                                        // auto v2: NEHotspotConfiguration.apply, awaits the poll
}
```

### 4.3 HTTP control — port of `../yi-m1-remote-control/prot_http/`
- Endpoint: `GET http://192.168.0.10/?data=<urlencoded-json>`, json = `{"command":"...", ...}`.
- Response: JSON `{"code":200,"data":...}` on success; a `404` HTML page for unknown commands;
  `{"code":1502,...}` etc. for camera-side errors.
- **`GetFile` returns raw binary in the body** — do NOT decode as text (would corrupt it). Use
  a separate download path; stream it for a progress bar.
- Confirmed-working commands (implement these; ignore the dead ones below):
  - `GetCameraStatus` → `{data:{batteryLevel, SurplusPhotoCnts, lenVer, lenType}}`
  - `RCStartRemoteCtl`, `RCStopRemoteCtl`
  - Settings (one param each, param name in braces): `RCSwitchDialMode {DialMode}`,
    `RCMeteringModeSet {MeteringMode}`, `RCFocusModeSet {FocusMode}`, `RCImageQualitySet
    {ImageQuality}`, `RCImageAspect {ImageAspect}`, `RCFileFormatSet {FileFormat}`,
    `RCDriveModeSet {DriveMode}`, `RCFNSet {Fnumber}`, `RCShutterSpeedSet {ShutterSpeed}`,
    `RCEVSet {EV}`, `RCISOSet {ISO}`, `RCWBSet {WB}`, `RCChooseColorMode {ColorMode}`
  - `RCDoFocus {Mode}` (Mode=`Auto`) or `{Mode:"Manual", Posx, Posy}` (image-pixel strings)
  - `RCDoShooting` (take photo), `VideoRecordingStart`, `VideoRecordingStop`
  - `GetFileList {range_start, range_end, filetype}` — filetype `all`/`DNG`/`JPG`; ALWAYS
    range_end≥1 (use 0..9999). Response `data` = array of `{path, date, filetype, protectStatus}`.
  - `GetFile {path, resulotion}` — **NOTE the API misspells it `resulotion`** (not
    "resolution"); replicate exactly. Values: `Original` / `MidThumb` / `Thumbnail`. Use
    `MidThumb` for the fast post-shot preview (~228KB vs ~32MB), `Original` for real downloads.
  - `DeleteFile {file_list:[paths]}`
- **Dead commands — do not use** (proven inert): `RCVideoFormatSet`, `RCVASwitchSet`,
  `RCVAVolSet`, `RCVANoiseReduceSet`, `RCEisSwitchSet`, `StartMovieStream`/`Pause`/`Resume`/
  `StopMovieStream`.
- Port every setting **enum** verbatim from `../yi-m1-remote-control/prot_http/const_http_cmd_rc_params.py`
  (RcIso, RcShutterSpeed, RcFStop, RcEvOffset, RcExposureMode, RcMeteringMode, RcFocusMode,
  RcImageQuality, RcImageAspect, RcFileFormat, RcDriveMode, RcColorStyle, RcWhiteBalance — the
  last has ~60 kelvin values). The enum **value** is the API string; the display label is
  separate (Part 4.5).

### 4.4 UDP live view (port of the loop in `../yi-m1-remote-control/app/camera_session.py`)
Bind UDP `0.0.0.0:54321`. Each datagram: bytes `[0:4]` = frame index (big-endian UInt32),
`[4:8]` = total packet count in this frame, `[8:12]` = this packet's index in the frame,
`[12:]` = payload chunk. Reassembly:
- When the incoming frame index differs from the current one, start a fresh buffer.
- Only append if `packetIndex == lastPacket + 1` (else mark frame invalid, skip until next).
- When `lastPacket == totalPackets - 1` AND assembled length > 2048: the **first 2048 bytes are
  a null-padded JSON metadata header**, the **rest is the JPEG**. Split there, parse the header
  (Part 4.6), decode the JPEG → frame.
`RCStartRemoteCtl` starts the stream; poll `GetCameraStatus` every ~5s alongside.

### 4.5 Measured crop rectangles + display labels (port verbatim)
Crop overlays, fractions `(x0, y0, w, h)` of the full 4:3 frame:
```
VIDEO (key = VideoFormat prefix):  "2K":(0,0,1,1)  "FHD":(0.0004,0.1268,0.9961,0.7472)  "4K":(0.1294,0.2230,0.7409,0.5558)
PHOTO (key = exact ImageAspect):   "4:3":(0,0,1,1) "3:2":(0,0.0556,1,0.8889) "16:9":(0,0.1247,1,0.7510) "1:1":(0.1250,0,0.7500,1)
```
Video match by prefix (`hasPrefix`), fall back to a centered ~16:9 approximation. Thirds &
diagonals draw **inside** the crop rect when Crop is on, else full frame.
Display-label mapping (display only — API value unchanged): port `_PRETTY_LABELS` +
`_display_label` from `../yi-m1-remote-control/app/main_window.py` (e.g. `I200`→`200`,
`SF100`→`1/100s`, `F1p4`→`f/1.4`, `N5p0`→`-5.0`, `MP50_Int`→`50 MP`, `CenterWeighted`→`Center`,
kelvin `5000`→`5000K`).

### 4.6 Live-view metadata header fields (JSON)
Keys seen (port the ones the UI needs): `ExposureMode, ISOSetting, WB, ColorMode, ShutterSpeed,
Fnumber, EV, FocusMode, MeteringMode, ImageQuality, ImageAspect, FileFormat, DriveMode,
VideoFormat, VASwitch, VAVol, VANR, VideoEis, BatteryLevel, SurplusPhotoCnts`. Used to: sync
settings dropdowns to the camera's real state, drive crop overlays, and show video read-only
chips (Format/Audio/EIS). **Remember `ImageAspect` is unreliable (fact #8).**

### 4.7 Design tokens (port from `../yi-m1-remote-control/app/theme.py`)
```
BG #0c0d0f · SURFACE #16181b · SURFACE_2 #1e2124 · LIVE_BG #141517
HAIRLINE #2a2d31 · HAIRLINE_SOFT #1c1f22
TEXT #f3f4f6 · TEXT_2 #9ba1a8 · TEXT_3 #63696f
ACCENT (amber) #f5a623 · RECORD #ff3b30 · OK (connected dot) #34c759
Radius sm/md/lg = 8/11/14 · Space xs/sm/md/lg/xl = 4/8/12/16/20 · Type 11/12/13/14/16
```
Dark, monochrome + single amber accent; red for recording only.

---

## Part 5 — Task breakdown (ordered, with parallel markers)

Each task: goal, files, acceptance criteria. `[Pn]` = parallel workstream (see Part 2 split).
`[SEQ]` = must be sequenced.

**Phase 0 — foundation [SEQ, do first, ~1 short task]**
- T0.1 Create the Xcode project `YiM1Monitor` + local package `YiM1Core`; add entitlements
  placeholders + Info.plist usage strings + ATS local-networking exception. **Freeze Part 3
  contracts** as real Swift files (empty impls / a `MockCameraSession`). AC: project builds,
  `MockCameraSession` drives a placeholder view, unit-test target runs.

**Phase 1 — core protocol (parallel)**
- T1.1 [P-A] `Commands.swift` + setting enums (port `prot_http/*`). AC: unit test asserts each
  command builds the exact JSON string (compare to the Python `to_json()` output); `GetFile`
  uses the misspelled `resulotion`; `GetFileList` defaults to range 0..9999.
- T1.2 [P-A] `CameraMetadata.swift`. AC: unit test parses a captured 2048-byte header sample
  (grab one via the macOS app or `../fable research/wifi-experiment-results/`) into typed fields.
- T1.3 [P-A] `HTTPClient.swift` (send/parse + raw streaming download w/ progress). AC: unit
  tests against a local stub server: JSON success, 404, 1502; binary download integrity;
  progress callbacks fire. Round every displayed byte/percent.
- T1.4 [P-A] `LiveViewReceiver.swift` (UDP reassembly). AC: unit test feeds a scripted sequence
  of datagrams (including an out-of-order drop that invalidates a frame) and asserts exactly
  one correct (metadata, jpeg) pair emerges; header/JPEG split at 2048.
- T1.5 [P-B] `BLEPairing.swift` (CoreBluetooth port of 4.1) incl. 30s/90s timeouts, service-UUID
  verification, tolerant info reads, CRC32. AC: CRC32 matches a known vector; state machine
  unit-tested with a mock peripheral; **on-device**: pairs and returns credentials.
- T1.6 [P-B] `WiFiConnector.swift` — v1 manual-join flow per Part 4.2: a `WiFiJoining` protocol
  + the manual implementation (present SSID/password, copy button, Settings deep-link via
  `openSettingsURLString`, reachability poll via `GetCameraStatus`). AC: **on-device** — after
  manually joining the camera Wi-Fi in Settings, the poll detects reachability and the sheet
  auto-dismisses; direct-connect path works if already joined. (Validate the Local Network
  prompt here — see Part 8 — this is the first place HTTP traffic to the camera happens.)
- T1.6b [P-B, optional/stretch, only if a paid developer account becomes available] Add an
  `NEHotspotConfiguration`-based `WiFiJoining` implementation as a drop-in alternative behind
  the same protocol. Not required for v1 — do not block on this.

**Phase 2 — design + UI against the mock (parallel with Phase 1)**
- T2.1 [P-C] `Theme.swift` + `Icons.swift` (SF Symbols: `folder`, `crop`, `grid`/`grid.circle`,
  `camera`, `video`; amber tint when active). AC: a token gallery preview renders.
- T2.2 [P-C] `LiveViewCanvas.swift` — draw `CGImage` + overlays (crop/thirds/diagonals via
  SwiftUI `Canvas`), tap-to-focus emitting image-pixel coords, review/download-progress
  takeover, "recording" note. AC: SwiftUI previews with a sample image show each overlay state.
- T2.3 [P-C] `ShutterButton.swift`, `ModeToggle.swift`, `GuideToggles.swift`. AC: previews show
  photo shutter, video record + recording square, mode switch, amber-active toggles.
- T2.4 [P-C] `SettingsStrip.swift` — mode-aware (shared always; photo-only in photo; video
  read-only chips in video). **Touch adaptation**: prefer tap-to-open pickers / a bottom sheet
  over tiny dropdowns; 2 rows or a horizontally-paged strip — decide with the user (Part 8 Q).
  AC: previews for both modes; picking a value calls `setSetting`.
- T2.5 [P-C] `FileBrowserView.swift` (list w/ type+date, download w/ progress, delete w/
  confirm) + `ConnectionMenu.swift` + `RootView.swift` shell. AC: full clickable app on the
  `MockCameraSession` with fake data; the pending-value sync behavior (facts #8) is respected
  in the mock.

**Phase 3 — integration [SEQ, after 1 + 2]**
- T3.1 [P-D] `CameraSession.swift` — orchestrate BLE→WiFi→RCStart→liveview+status; implement
  the settings pending-value logic (port `_on_setting_changed`/`_on_live_metadata`, incl.
  `ImageAspect` never-expire + optimistic overlay update); shoot-with-review (find newest file
  via `GetFileList` by max `date`, download `MidThumb`, show ~2s); recording state; direct
  connect; reset. AC: unit tests for the pending-value state machine (stale metadata doesn't
  revert a fresh pick; `ImageAspect` held indefinitely).
- T3.2 [P-D] Swap the mock for the real `CameraSession` in the views. AC: builds, previews use
  the mock, app target uses the real one.
- T3.3 [P-D] **On-device end-to-end**: pair → join → live view → change a setting → shoot (see
  review) → switch to video → record → browse/download a file → disconnect. AC: all work
  against the real camera; capture a metadata sample for T1.2 if not already done.

**Phase 4 — polish**
- T4.1 Handle all permission-denied paths (Bluetooth off, Local Network denied, user backs out
  of the manual-join sheet without joining) with clear in-app guidance. T4.2 Empty/error states, connection-stuck
  reset UX. T4.3 Match the macOS quirks copy (video format read-only w/ lock, "screen locked on
  camera", one-client note).

---

## Part 6 — UI spec (touch-native, same information architecture as macOS)

Same layout language as the shipped macOS app (`../yi-m1-remote-control/app/main_window.py`),
adapted for touch. Three previously-open choices are now DECIDED (2026-07-07):

- **Settings input: pull-up sheet.** Tapping a settings chip in the bottom strip (or a single
  "Settings" affordance) presents a sheet with the mode-aware list of pickers — touch-friendlier
  than shrinking desktop-style dropdowns onto a phone screen.
- **Orientation: portrait-first (v1 scope).** Matches the user's own reference point for this
  design (the iOS Camera app is portrait-primary). Landscape support is a stretch goal, not
  required for v1 — don't spend budget on it unless portrait-first is solid and there's time left.
  **Post-v1 (added 2026-07-08, real motivation, not just "nice to have"):** the user's actual
  end goal for this app is to use the iPhone as a replacement for an on-camera/hot-shoe monitor
  while filming — that use case is inherently landscape (phone mounted sideways on/near the
  camera, pointed at the same thing the lens is). So landscape support isn't a cosmetic stretch
  goal, it's closer to the real target form factor; just not in v1's scope. When picked up: the
  `RootView` layout (status bar → mode toggle → live view → control row → settings strip, all
  vertically stacked) will need a landscape-specific arrangement (likely live view filling most
  of the frame with controls as a thinner overlay/sidebar, similar to real on-camera monitors),
  not just letting the existing vertical stack rotate as-is.
- **Icons: SF Symbols, with one custom exception.** Use native symbols — `camera`/`camera.fill`,
  `video`/`video.fill`, `folder`/`folder.fill`, `crop`, `squareshape.split.3x3` (thirds) — all
  have exact or close matches, are free, vector, and accessible out of the box. **Diagonals has
  no good SF Symbol match** — draw that one icon by hand (a small `Canvas`/`Path`, same
  technique as the macOS `icons.py` but just for this glyph) rather than forcing a wrong symbol.

Layout:
- **Top**: status chip (green dot · battery · shots) + a Connection control (menu or a sheet):
  Connect (Bluetooth) / Connect (already on camera Wi-Fi) / Disconnect / Reset.
- **Below**: Photo/Video segmented toggle (free switch, fact #6).
- **Center**: live view, dominant; tap to focus; overlays drawn in a `Canvas`.
- **Bottom cluster**: Files (left) · shutter/record circle (center, large touch target ≥64pt) ·
  guide toggles Crop/Thirds/Diagonals (right).
- **Settings**: pull-up sheet (see above), mode-aware content (Part 2.4).
- Overlays: Crop is mode-aware (photo crop vs video crop); thirds/diagonals inside crop when on.
  Hide crop overlays while recording (live view already shows the real crop then, fact from
  macOS §12); show the exposure caveat note where relevant.

---

## Part 7 — Testing & verification

- **Unit-testable without a camera** (do these thoroughly): command JSON building, metadata
  parsing, UDP reassembly, CRC32, pending-value state machine, crop-rect math, display labels.
  Capture real fixtures (a metadata header, a `GetFileList` JSON, a UDP packet capture) from the
  macOS app / `../fable research/wifi-experiment-results/` to test against real bytes.
- **Requires the device + camera** (on-device only, one client at a time — Mac app OFF):
  BLE pairing, Wi-Fi join, Local Network permission, live view, every command end-to-end.
- **Simulator caveat**: CoreBluetooth pairing and Local Network permission/traffic don't work
  in the Simulator; gate those behind on-device runs.

---

## Part 8 — Risks & open questions (raise with the user early)

Load-bearing unknowns to validate before building far on top of them:
1. **Manually-joined Wi-Fi behavior**: after the user manually joins the camera network in
   Settings (no entitlement, no `joinOnce` control), does iOS keep serving the app's local
   traffic reliably while the network has no internet, and does returning to the app (from
   Settings) resume the reachability poll promptly? Validate a bare manual-join→
   `GetCameraStatus` on-device in T1.6 before anything else.
2. **Local Network permission**: confirm the prompt appears and, once granted, both HTTP and UDP
   to `192.168.0.10` work. If denied, the app is dead — needs a clear re-enable flow. This is
   also the very first moment the manual join flow's reachability poll can succeed, so it's
   naturally tested together with risk 1.
3. **One-client limit**: iOS testing requires the Mac app disconnected. Bake into the workflow.
4. **UDP on iOS**: `NWListener`/`NWConnection` vs a BSD socket for inbound UDP on a fixed port —
   pick during T1.4; ensure it survives the Local Network permission gate.
5. **Detecting "already on the camera Wi-Fi"** for the direct-connect path without the
   `com.apple.developer.networking.wifi-info` entitlement (also paid-account-gated) —
   `NEHotspotNetwork.fetchCurrent` reading the real SSID likely also needs that entitlement.
   Fallback: just attempt the reachability poll immediately (a "Connect directly" button that
   tries `GetCameraStatus` right away) — works regardless of whether the SSID can be read, since
   we only care about reachability, not the network's name. No entitlement needed either way.

Previously-open UI/scope questions are now DECIDED — see Part 6 (settings sheet, portrait-first,
SF Symbols + one custom icon) and Part 4.2 (manual Wi-Fi join, no paid account required).

---

## Part 9 — Definition of done (v1)

Pair over BLE → manually join the camera Wi-Fi via the credentials sheet (with the Local
Network permission handled gracefully, no paid developer account required) → reachability poll
confirms connection → live view with the three overlays → free Photo/Video switch → change any
shared/photo setting and see it reflected → shoot a photo with the ~2s review → record video →
browse/download/delete files with progress → disconnect cleanly. Visuals match the macOS design
system (dark, amber accent, portrait-first). All camera quirks from Part 0 respected (video
format read-only, ImageAspect trusted-not-reverted, GetFileList range, one-client). On-device
verified end-to-end.

---

## РЕАЛИЗОВАНО (2026-07-08) — Phases 0–2 + T3.1/T3.2 complete

Everything **not** requiring the physical iPhone + camera is implemented and verified:

- **`YiM1Core`** (Sources/YiM1Core/): all of Phase 1 — `CameraSettings.swift`, `PrettyLabel.swift`,
  `Commands.swift`, `CameraMetadata.swift`, `MeasuredCrops.swift`, `CameraFile.swift`,
  `HTTPClient.swift`, `LiveViewReceiver.swift`, `CRC32.swift`, `BLEUUIDs.swift`,
  `BLEPairing.swift`, `WiFiConnector.swift`, `SettingCatalog.swift`, `CameraSessionProtocol.swift`
  (the frozen Part 3 contract), and **`CameraSession.swift`** (T3.1) — the real orchestrator:
  BLE → manual-join reachability poll → `RCStartRemoteCtl` → live view + status polling, the
  pending-value settings sync (exact port of the macOS bug #10/#12 fix, `.imageAspect` held
  indefinitely via `Date.distantFuture`), shoot-with-review (poll `GetFileList` by max `date`,
  download `MidThumb`, ~2s review), recording toggle, direct connect, reset. 26 unit tests pass,
  including genuine end-to-end UDP socket reassembly tests.
- **`YiM1Monitor`** (the SwiftUI app target, Phase 2 + T3.2): `Theme.swift`/`Icons.swift` (+ the
  one hand-drawn Diagonals icon), `LiveViewCanvas.swift` (Canvas overlays, tap-to-focus,
  review/download takeover), `ShutterButton.swift`, `ModeToggle.swift`, `GuideToggles.swift`,
  `SettingsStrip.swift` (pull-up sheet per the Part 6 decision), `FileBrowserView.swift`
  (swipe-to-delete/download, share-sheet export), `ConnectionMenu.swift`, `WiFiJoinSheet.swift`,
  `RootView.swift` shell, `MockCameraSession.swift` (simulates the pending-value protection with
  fake timing, for preview/dev use), `App.swift` (wired to the **real** `CameraSession` — T3.2 is
  done, not just scaffolded). Every view is generic over `CameraSessionProtocol`.
- **Project generation**: `project.yml` (xcodegen) + generated `YiM1Monitor.xcodeproj`. Info.plist
  properties (Bluetooth/Local Network usage strings, ATS local-networking exception,
  portrait-only) are defined declaratively in `project.yml`'s `info.properties` — xcodegen
  regenerates the actual Info.plist file from there on every `xcodegen generate`, so edit the
  YAML, not the plist directly.
- **Verification performed**: `YiM1Core` builds and its 26 tests pass both natively (macOS host)
  and cross-compiled against the real `iphonesimulator` SDK (`swift build --sdk $(xcrun --sdk
  iphonesimulator --show-sdk-path) -Xswiftc -target -Xswiftc arm64-apple-ios16.0-simulator`).
  Every `YiM1Monitor` SwiftUI/UIKit source file was also verified against the real iphonesimulator
  SDK the same way, via a temporary throwaway SwiftPM target (deleted after use — not part of the
  shipped project) — this caught one real bug (`LiveViewCanvas.swift` used the iOS 17-only
  `onChange(of:initial:_:)` two-parameter form; fixed to the iOS 16-compatible single-parameter
  `onChange(of:perform:)`).
- **Known environment limitation (not a code issue)**: this sandbox's Xcode install has the iOS
  SDK but no installed Simulator *runtime* (`xcrun simctl list runtimes` is empty) and headless
  `xcodebuild -scheme ... -destination ...` can't resolve a destination as a result; a raw
  `xcodebuild -target` build also fails to wire the local SPM package product's search path
  correctly outside of Xcode's own GUI-driven derived-data flow. Opening `YiM1Monitor.xcodeproj`
  directly in Xcode.app (which has a real derived-data build and can prompt to install a Simulator
  runtime) should build and run normally — this hasn't been re-verified there yet.

**Not done (needs the physical iPhone + camera, one-client-at-a-time with the Mac app OFF)**:
T1.5/T1.6's on-device BLE pairing + manual Wi-Fi join acceptance criteria, T3.3's full on-device
end-to-end pass, and Phase 4 polish (which is best tuned against real device behavior). Also
worth a real Xcode.app open + build before the first device run, per the limitation above.

---

## First on-device run (2026-07-08) — 3 real bugs found and fixed

User installed a Simulator runtime, built+ran in Xcode, confirmed the UI renders correctly, then
did a real on-device test against the camera: first connect worked, but **reconnecting to the
same camera Wi-Fi after a disconnect froze live view on the last frame with no further update,
files stopped listing in the file browser, and the camera returned an "1515 rc only one" error**.
Root-caused and fixed without needing another device round (all three are logic bugs, not
protocol misunderstandings):

1. **`LiveViewReceiver` self-deadlock (the primary cause of "live view doesn't react after
   reconnect").** `runLoop()` was dispatched onto a *serial* `DispatchQueue` via `queue.async`,
   but `runLoop()` is a `while` loop that never returns for the connection's entire lifetime -
   meaning `stop()`'s own `queue.async` block (which sets `isRunning = false` and closes the
   socket) could never actually execute, since a serial queue never starts a second block while
   the first is still running. So `stop()` was a no-op against an active receiver, and the
   *next* `start()`'s `runLoop()` invocation queued up forever behind the immortal first one -
   it would never even attempt to rebind the socket. Fixed: `runLoop()` now runs on a dedicated
   `Thread`, with `isRunning`/`socketFD` guarded by an `NSLock` so `stop()` can mutate them
   immediately from any thread. Added a genuine regression test,
   `testReceiverWorksAfterStopThenRestart` (stop a receiver, `start()` it again on the same port,
   assert the second connection's frames actually arrive) - this would hang against the old code.
2. **`LiveViewCanvas` stale frame retention.** `onChange(of: frameData) { newValue in guard let
   newValue ... else { return } ... }` silently no-opped when `frameData` became `nil` (e.g. on
   disconnect), so the `@State liveImage` was never cleared - the last live-view frame stayed
   frozen on screen indefinitely. Fixed to explicitly clear `liveImage = nil` when the source
   goes `nil`.
3. **Disconnect/reconnect race causing the camera's "rc only one" rejection.** `disconnect()`
   fired `RCStopRemoteCtl` in a detached, un-awaited `Task` and reset `connectionState =
   .disconnected` (re-enabling Connect) immediately, before that request had actually reached/been
   processed by the camera. A fast reconnect could send `RCStartRemoteCtl` while the camera still
   considered the previous session active, and get rejected. Fixed: added a `.disconnecting`
   transient `ConnectionState` - `disconnect()` now only flips to `.disconnected` (and thus
   re-enables reconnecting) *after* `RCStopRemoteCtl` completes. Also made `reset()` fire a
   best-effort (un-awaited, matching its "abandon and start clean" philosophy) `RCStopRemoteCtl`
   too, since it previously never attempted to tell the camera anything - useless as a recovery
   path for exactly this kind of stuck one-client-slot state.

All 27 `YiM1Core` tests pass (26 + the new regression test); the full `YiM1Monitor` SwiftUI
source was re-verified compiling against the real iphonesimulator SDK via the same disposable
verification-package technique as before. Not yet re-tested on-device after this fix round.

**Also fixed (same session, user-reported): the app stayed "Connected" forever if the camera
itself dropped the connection** (powered off, out of Wi-Fi range, screen-locked, etc.) - there
was no notification path for that, and `startStatusPolling()`'s `GetCameraStatus` poll silently
ignored failures instead of ever surfacing them. Fixed: the poll now tracks consecutive failures
and, after `maxConsecutiveStatusFailures` (3, ~15s at the 5s poll interval) in a row, tears down
local state via a new `handleConnectionLost(reason:)` and sets `connectionState = .error(...)`
- distinct from user-initiated `disconnect()`/`reset()` since there's no live connection left to
send `RCStopRemoteCtl` to.

**Also fixed (same session, user-reported): file browser could list files but never
download/delete them - root-caused to two independent bugs in `HTTPClient.buildURL`, both about
forward slashes in camera file paths, found via an empirical Swift URL/JSON test rather than
guesswork:**
1. `JSONSerialization.data(withJSONObject:)` escapes `/` as `\/` in its JSON output by default (a
   legacy behavior Foundation carries for safe `<script>` embedding; Python's `json.dumps`, used
   by the reference, does NOT do this) - so a path like `/DCIM/100YICAM/P1.DNG` was actually being
   sent as `\/DCIM\/100YICAM\/P1.DNG`. Technically valid JSON, but the camera's minimal embedded
   parser almost certainly doesn't unescape `\/`, so the path it read never matched a real file.
   `GetFileList`/`GetCameraStatus` have no slashes in their params, so they were unaffected -
   explaining exactly the reported "list works, download/delete don't" split. Fixed by stripping
   the `\/` escape back to `/` post-serialization (safe here - nothing in this app's command
   vocabulary ever contains a literal backslash).
2. This file *also* independently percent-encoded the resulting JSON before building the URL
   (conservatively, RFC 3986 "unreserved" characters only), turning `/` into `%2F` on top of the
   above - based on an assumption, stated in the original file header, that Foundation's
   `URL(string:)` couldn't accept the raw unescaped JSON. Verified empirically that assumption was
   wrong: `URL(string:)` accepts `{`, `}`, `"`, `:`, `,`, `/` all raw, only forcing its own
   encoding for `[`/`]` (-> `%5B`/`%5D`) - much closer to what the Python reference actually sends
   (raw `json.dumps()` output straight into the URL). Removed the manual percent-encoding.

Added `HTTPClientTests.swift` (3 tests, `buildURL` made internal instead of private specifically
so they can call it directly) asserting file paths appear literal in the built URL's query and
`%2F` never appears. All 30 `YiM1Core` tests pass; re-verified against the real iphonesimulator
SDK. Not yet re-tested on-device.

---

## Full audit pass (2026-07-08, user-requested) — 5 more iOS fixes

1. **HTTP requests must be strictly serialized - the camera cannot handle concurrency (the
   remaining "1515 on first opening the file browser" root cause).** The macOS reference runs ALL
   HTTP on one thread through a request queue (naturally sequential, one keep-alive connection via
   urllib3). The iOS port's callers are concurrent Tasks - the 5s status poll, GetFileList,
   downloads, setting sends can all fire at once - and `URLSession` additionally opens parallel
   TCP connections per host by default. The camera rejects the overlap with
   `{"code":1515,"rc only one"}`: first file-browser open collided with an in-flight status poll,
   the second try landed between polls. Fixed twofold in `HTTPClient`: (a) every `send`/`download`
   is chained through a `chainTail` task so exactly one request is in flight at a time (an actor
   alone is NOT enough - isolation releases during the network await); (b) the default session is
   now `ephemeral` with `httpMaximumConnectionsPerHost = 1`. Regression-tested with a
   `URLProtocol` stub that records max concurrent open requests (5 parallel sends -> peak must
   be 1; fails against the old code).
2. **Abandoned connect tasks could clobber state after Reset.** `reset()` cancels `connectTask`,
   but cancellation is cooperative - an in-flight BLE pairing / reachability poll lands in its
   `catch` (Task.sleep throws CancellationError) or falls through, then wrote
   `connectionState = .error(...)` (or even `.connected`) over whatever the user had moved on to.
   Added `Task.isCancelled` checks after every await/catch in `connectViaBLE`/
   `confirmWiFiJoinInProgress`/`connectDirect` + `try Task.checkCancellation()` in
   `startRemoteControlSession`.
3. **`disconnect()`'s completion could reset a newer session.** The task that awaits
   `RCStopRemoteCtl` called `resetPublishedState()` unconditionally - if the user hit Reset (or
   reconnected) while the stop was in flight, the late completion clobbered the new state. Now
   guarded on `connectionState == .disconnecting`.
4. **WiFiJoinSheet dead-ends.** (a) On reachability timeout the state went to `.error` with
   `pendingWiFiCredentials` still set -> sheet stayed up with a permanently dead "I've connected"
   button (its guard only accepts `.awaitingWiFiJoin`). Now a timeout with the sheet still up
   returns to `.awaitingWiFiJoin`, making the button a working retry. (b) No cancel path existed
   at all (the presentation binding's setter was a no-op, so swipe-down just re-presented). Added
   a Cancel button (calls `reset()`, which clears the credentials the sheet is bound to) and made
   the binding's setter call `reset()` on user-initiated dismissal - with a credentials nil-check
   so the *programmatic* dismissal on successful connect doesn't tear down the fresh connection.
5. **Capture races.** `shootPhoto`'s detached task could repaint review state after a
   disconnect/reset (now routed through a `setPhotoReview` helper that no-ops unless still
   `.connected`); `toggleRecording` had a double-tap race (two quick taps both read the same
   `isRecording`, sent Start twice, toggled twice -> UI showing "not recording" while the camera
   records) - now guarded by a `recordingCommandInFlight` flag, and the result is only applied if
   still connected.

All 31 tests pass; SwiftUI re-verified against the real iphonesimulator SDK. Not yet re-tested
on-device.

**macOS findings from the same audit (NOT fixed - listed for a future session):**
- The macOS app has the same "stays Connected forever if the camera vanishes" gap the user
  reported on iOS: its `GetCameraStatus` poll in `run()` ignores failures entirely. Live view
  just silently freezes on the last frame. Porting the iOS consecutive-failures fix
  (3 misses -> disconnect + error) is straightforward if wanted.
- During a photo review download / file download, the single-thread design means live view
  freezes briefly (the UDP loop and HTTP share one thread). By design, cosmetic, ~seconds.
- Both apps' shoot-with-review assumes the camera's clock roughly matches the host clock
  (`newest.date >= shoot_time - 5s`). Confirmed working live on macOS (clocks matched), but if
  the camera's clock ever drifts badly, review will break the same way on both - worth
  remembering when debugging "review can't find the new photo".
- The known-broken Wi-Fi-restore-on-disconnect (roadmap item 3) remains the only other open
  macOS issue.

---

## 2026-07-09 — Wi-Fi settings deep-link + manual live-view rotation

**Wi-Fi settings button now deep-links into the actual Wi-Fi pane.** User confirmed the
documented limitation on-device: `openSettingsURLString` lands on the app's own Settings page,
not Wi-Fi. Since this app is sideloaded via Xcode (personal team - no App Store review), the
private `App-Prefs:root=WIFI` scheme is acceptable and now tried first, with the official
app-settings URL kept as fallback (in case a future iOS kills the private scheme). NOTE: private
scheme behavior varies by iOS version - verify on-device; if it silently opens the main Settings
page instead of Wi-Fi specifically, that's still an improvement over the app-page.

**CONFIRMED ON-DEVICE (2026-07-09, user): everything above works against the real camera** -
reconnect to the same network after disconnect, file browser working on the FIRST open
(download + delete included - both the slash-encoding and the request-serialization fixes hold),
Wi-Fi join sheet cancel paths, the `App-Prefs:root=WIFI` deep-link landing in the actual Wi-Fi
pane, auto-detection of the camera vanishing, and the live-view rotation button. T3.3's
on-device end-to-end pass is effectively complete; remaining work is Phase 4 polish + the
landscape/on-camera-monitor layout (post-v1).

> **2026-07-11: detailed executor work orders for the next two features (focus peaking + file
> browser rework incl. thumbnails/multi-select/save-to-Photos) live in
> `TASKS_FOCUS_PEAKING_AND_FILE_BROWSER.md`** - written for a Sonnet-class executing model,
> self-contained (env recipes, protocol invariants, per-task specs, acceptance criteria).
> **Both tasks (file browser rework AND focus peaking) are DONE - see the dated notes below.**
>
> **2026-07-11 (end of day): the NEXT full work order is `../TASKS_V2_IOS_THEN_MACOS.md`** (in
> the parent folder, since it spans both apps): finish the iOS app completely (I1
> NEHotspotConfiguration spike → I2 top-bar rework → I3 weak-link indicator → I4 recording
> auto-restart → I5 Phase-4 polish batch → I6 landscape/on-camera-monitor layout), THEN bring
> macOS to parity (M1 body-code checking → M2 camera-vanished detection → M3 guide semantics →
> M4 receiver hardening → M5 Wi-Fi restore → M6 auto-restart parity). Punch-in zoom and exposure
> scopes are explicitly excluded by the user.

## 2026-07-11 — Task B: File browser rework (executed per TASKS_FOCUS_PEAKING_AND_FILE_BROWSER.md)

Reworked `FileBrowserView` per user feedback that swipe-to-reveal actions were unintuitive.
Swipe actions kept as a shortcut; the primary interaction is now tap-to-detail + a selection mode
for batch ops. Subsumed three previously-separate backlog items (thumbnails, multi-select,
save-to-Photos) into one coherent change.

**Core/protocol (`YiM1Core`):**
- `CameraSessionProtocol`/`CameraSession`/`MockCameraSession` gained
  `fetchFileData(_:quality:) async throws -> Data` (bytes, not a file - for thumbnails/detail
  previews) and `deleteFiles(_ paths: [String]) async -> Bool` (batch; `DeleteFile`'s wire format
  already takes an array, so this is one command regardless of count).
- Removed the old single-path `deleteFile(_:)` - `deleteFiles([path])` replaces it; the only
  caller (`FileBrowserView`) was being rewritten in this same change anyway.
- `CameraFile` gained `isVideo` (checks `filetype` then falls back to the `.mp4`/`.mov`
  extension) - used to pick the Photos resource type and the type-icon fallback.
- All 32 `YiM1Core` tests still pass (untouched otherwise).

**New app-target files:**
- `Views/ThumbnailStore.swift` - `@MainActor ObservableObject` cache (`[path: UIImage]` +
  failed-path set + in-flight set). `load(_:session:)` is a generic method (not a generic type)
  so one instance works regardless of the concrete `Session`. Driven by `.task(id: file.path)`
  per row so scrolling a row out cancels its fetch; also checks `Task.isCancelled` right before
  the HTTP call, since a request already enqueued in `HTTPClient`'s one-at-a-time chain WILL run
  to completion once started. Uses `FileQuality.fast` ("Thumbnail") - **on-device unverified**
  whether the camera actually serves a smaller image for this vs MidThumb; harmless either way.
  Decode failures (expected for video files) are cached as permanent failures, falling back to a
  type icon - no retry storms.
- `Views/FileDetailView.swift` - large MidThumb preview (`ProgressView` while loading, type-icon
  fallback on failure/videos), metadata rows (type/date/protected), three explicit buttons: Save
  to Photos (primary), Share/Download (existing share-sheet flow), Delete (destructive,
  confirmation alert, pops back + calls `onDeleted` on success).
- `Views/PhotoLibrarySaver.swift` - `PHPhotoLibrary.requestAuthorization(for: .addOnly)` (add-only
  is correct here - the app only ever adds, never reads, the user's library) +
  `downloadAndSave(_:session:onProgress:)`: downloads Original quality to a temp file via the
  existing `downloadFile(to:onProgress:)` (progress-reporting, handles large videos without
  holding them fully in memory) then `PHAssetCreationRequest` with `.photo` or `.video` resource
  per `CameraFile.isVideo`. Shared between the detail screen (single file) and the browser's
  batch action.
- `Views/ShareSheet.swift` - `ShareItem`/`ActivityView` extracted out of `FileBrowserView` (now
  shared with `FileDetailView`, which also has a Share button).

**`FileBrowserView` rework:**
- Rows now show a 56pt thumbnail (via `ThumbnailStore`) before the filename/type/date stack.
- Rows are `NavigationLink`s to `FileDetailView`; swipe actions (Delete/Download) remain.
- "Select" toolbar button -> `EditMode.active` with `List(selection: $selectedPaths)` (a
  `Set<String>`, matching `CameraFile.id`); a bottom toolbar shows "Delete (N)" / "Save to
  Photos (N)". Batch delete is one `deleteFiles` call; batch save is a **sequential** loop (the
  camera only handles one request at a time regardless, so parallelizing would just queue
  anyway) with a "Saving N of M…" progress label, stopping on the first failure with a message
  saying how far it got.
- `MockCameraSession`'s fake file list extended from 3 to 8 entries (mixed types incl. a
  protected video) so thumbnails/selection/detail are all visually exercisable in the Simulator;
  its `fetchFileData`/`downloadFile` now return a small deterministically-colored placeholder
  JPEG (`UIGraphicsImageRenderer`, keyed by path hash) instead of nothing.

**Project config:** added `NSPhotoLibraryAddUsageDescription` to `project.yml`'s
`info.properties` (required or the app crashes on the first Photos write) and regenerated
`YiM1Monitor.xcodeproj` - confirmed the key landed in the generated `Info.plist`.

**Verification performed:** all 32 `YiM1Core` tests pass; the full `YiM1Monitor` SwiftUI target
(including all the new files) compiles cleanly against the real iphonesimulator SDK via the
disposable verification-package technique (built clean on the first attempt).

**On-device-unverified (user's next step):** `Thumbnail` quality actually being smaller/faster
than MidThumb; video files' behavior in `GetFile` (does it 404, return something undecodable, or
something unexpected?) - the code assumes failure and falls back gracefully either way; the
Photos authorization prompt/flow on a real device; batch save/delete against the real camera
under the one-request-at-a-time constraint (should just be slower than the Mock, not broken).

## 2026-07-11 — Task A: Focus peaking (executed per TASKS_FOCUS_PEAKING_AND_FILE_BROWSER.md)

Manual-focus assist for the user's manual lens - highlights high-contrast (in-focus) edges over
live view in the accent color. Unlike exposure tools (histogram/zebras, still backlog), peaking
isn't invalidated by the live-view preview's known auto-exposure-ish quirk (edges don't depend on
brightness), so it's enabled pre-record too.

**`Views/FocusPeaking.swift` (new):**
- `FocusPeakingRenderer` - a plain enum of static functions (no captured state, no actor
  isolation) holding the actual Core Image pipeline: `CIImage(data:)` -> `CIFilter.edges()`
  (intensity 3.0) -> `CIFilter.colorThreshold()` (threshold 0.2) -> blend a constant amber
  (`#f5a623`, matching `AppColor.accent`) image with a constant fully-transparent image using the
  threshold output as the mask (`CIFilter.blendWithMask()`) -> `CIContext.createCGImage` ->
  `UIImage`. Kept as a plain enum (not a method on the processor class) specifically so it can
  run on a background `DispatchQueue` without Swift concurrency fighting over `CIContext`'s
  Sendability across an actor boundary.
  - Implementation note: `CIFilter.constantColorGenerator()` doesn't exist under this name/API
    shape in the SDK actually used (compile error) - switched to `CIImage(color:).cropped(to:)`,
    which is simpler anyway.
- `FocusPeakingProcessor` (`@MainActor ObservableObject`, `@Published var overlay: UIImage?`) -
  owns one `CIContext` for its whole lifetime (per the task's requirement) and a dedicated
  background `DispatchQueue`. `process(_:)` implements mandatory frame-dropping: if a render is
  already in flight, the new frame data just overwrites a single `pendingData` slot (keep-latest,
  never a growing backlog) rather than queuing. A `generation` counter invalidates any in-flight
  render when `clear()` is called (peaking toggled off / disconnect), so a late-arriving
  background result can't paint a stale overlay back onto the now-disabled state.

**Wiring:**
- `Design/Icons.swift`: `AppIcon.peaking = "scope"`.
- `RootView.swift`: `@StateObject private var peakingProcessor`, `@State private var
  showPeaking`; a toggle button in the **top bar** (not the bottom guide cluster, which is
  already full with three toggles across its third of the width) next to the rotate button, same
  visual treatment (amber when active). `.onChange(of: session.latestFrameData)` feeds new frames
  into the processor while `showPeaking && isConnected`; `.onChange(of:
  session.connectionState)` calls `peakingProcessor.clear()` on any non-`.connected` transition.
- `LiveViewCanvas.swift`: new `peakingOverlay: UIImage?` parameter, rendered through the exact
  same `rotatedImage(_:fitted:)` path as the live image itself (same pixel dimensions as the
  frame it was derived from, so the existing fitting/rotation math applies verbatim - it rotates
  together with the live image when `ViewRotation` is active) - positioned between the live image
  and the guide-overlay layer, `.allowsHitTesting(false)`. Hidden while `photoReview` is
  `.ready`/`.downloading` via a new `shouldShowPeaking` computed property (those states already
  take over the frame with different content).

**Verification performed:**
- `YiM1Core` untouched by this task - all 32 tests still pass.
- `YiM1Monitor` (including the new file) compiles cleanly against the real iphonesimulator SDK
  via the disposable verification-package technique.
- **Pipeline correctness verified empirically** (no app test target exists to host a proper unit
  test): wrote a standalone Swift script exercising the identical Core Image filter graph against
  a generated 200x100 test image (sharp black/white checkerboard on the left half, flat mid-gray
  on the right) and inspected the output pixel bytes directly. Result: alpha/color channels are
  255 (fully opaque amber) near a checkerboard edge and 0 (fully transparent) in the flat region
  - the pipeline behaves exactly as intended. Script was scratch-only, not committed.

**On-device-unverified (user's next step, per the task file):** actual CPU/GPU performance
impact on live-view framerate at the real ~10-15fps feed rate (the frame-dropping design should
keep it from ever backing up, but the per-frame Core Image cost on a real device is unmeasured);
whether the edge/threshold constants (intensity 3.0, threshold 0.2) read as useful peaking on
real out-of-camera JPEGs vs the synthetic test image; visual check that the overlay follows
`ViewRotation` correctly; clean toggle on/off with no stuck overlay.

**Fixed same day, first real on-device build (2026-07-11):** two build errors turned out to be
one cause - `xcodegen generate` had been run once at the end of Task B, but `FocusPeaking.swift`
was created afterward during Task A, so the regenerated `.xcodeproj` didn't know about it yet
("Cannot find 'FocusPeakingProcessor' in scope" + a cascading phantom error on an unrelated
`.onChange` line from the broken type-check breaking overload resolution for the rest of that
modifier chain). Fixed by re-running `xcodegen generate`; added a rule to the task file itself
(regenerate after every new file, not just once at the end) since this cost a review cycle.

After that, the user ran a real build successfully (peaking + file browser both confirmed
working) but the Console log showed a genuine SwiftUI runtime **Fault** (not routine log noise):
`onChange(of: Optional<Data>) action tried to update multiple times per frame`. Root cause: TWO
separate `.onChange` modifiers were independently observing the same underlying `@Published
Data?` (`session.latestFrameData`) - one inside `LiveViewCanvas` (decodes `liveImage`, pre-
existing) and a second one added in `RootView` for Task A (feeds `FocusPeakingProcessor`). When
live-view frames arrive in a burst (plausible if the AsyncStream had buffered several before the
main thread got a chance to render), the value can change more than once before SwiftUI finishes
diffing, and having two independent observers on the exact same source doubled the chance of
tripping this diagnostic. Fixed by consolidating to a single observation point: `LiveViewCanvas`
gained an `onNewFrame: ((Data) -> Void)?` callback fired from inside its *existing*
`onChange(of: frameData)` handler (right after decoding `liveImage`), and `RootView`'s separate
`.onChange(of: session.latestFrameData)` was removed in favor of passing this callback (still
gated on `showPeaking && isConnected`). All 32 `YiM1Core` tests still pass (untouched); the app
target re-verified compiling against the real iphonesimulator SDK. Not yet re-tested on-device
whether this fully eliminates the fault - it removes the specific duplicate-observer cause found,
but if it recurs the next place to look is whether `CameraSession.startLiveView()`'s frame loop
can process multiple buffered `AsyncStream` frames per MainActor runloop turn without yielding
(i.e. whether the live-view receiver itself needs backpressure/coalescing upstream, not just one
fewer observer downstream).

**Update: the fault recurred once more even after that fix (user, 2026-07-11 second build)** -
so it wasn't purely a duplicate-observer problem. Found the actual systemic cause: `LiveViewReceiver.start()`'s
`AsyncStream` used the default `.unbounded` buffering policy. If the MainActor consumer falls
behind for even a moment (decoding a thumbnail, running focus-peaking's Core Image pipeline,
etc.), an unbounded buffer lets frames pile up, then delivers them all in one tight back-to-back
loop once the consumer catches up - each iteration synchronously reassigning `latestFrameData`
with no chance for SwiftUI to render in between. Fixed at the source: switched to
`AsyncStream(bufferingPolicy: .bufferingNewest(1))` - a slow consumer now just skips stale frames
(matching the same "keep-latest" philosophy `FocusPeakingProcessor` already uses for its own
consumption) instead of ever building a backlog to dump all at once. All 32 tests still pass.

## 2026-07-11 — Live-view fps/dropped-frame debug overlay (approved backlog item, now built)

Implements the diagnostic from the 2026-07-09 "live view seemed slower away from home" backlog
item - lets a slow feed (crowded 2.4GHz RF vs an app-side problem) actually be measured instead
of just eyeballed.

- `LiveViewReceiver` gained `validFrameCount`/`droppedFrameCount` (guarded by the existing lock)
  and a `statsSnapshot() -> LiveViewStats` accessor. Counting logic: a frame is "dropped" if it's
  abandoned before ever being yielded - counted *lazily*, at the moment the NEXT frame's first
  packet arrives (not the instant a problem is detected), so it catches both failure modes with a
  single check: an out-of-order packet mid-frame (`frameValid` flips false, never recovers) AND a
  frame that simply never received its remaining packets before the next frame index started
  (`frameValid` stays true the whole time - nothing else would ever notice that one). A
  `frameCompleted` flag tracks whether the in-progress frame ever reached a yield; checking it
  only at the frame-index transition avoids double-counting a frame that's already been flagged
  invalid. Added `testDroppedPacketInvalidatesFrameButNextFrameRecovers`'s stats assertions
  (1 valid, 1 dropped) to `LiveViewReceiverTests.swift`.
- `CameraSessionProtocol`/`CameraSession`/`MockCameraSession` gained `liveViewFPS: Double` (2s
  rolling window of frame-arrival timestamps, recomputed on every frame rather than on a timer)
  and `liveViewDroppedFrameCount: Int` (mirrors the receiver's snapshot). Mock returns 0/0 - it
  has no real frame feed to measure.
- `RootView.swift`: a small monospaced chip ("12.3 fps · 2 dropped") floating in the top-right of
  the live view, **`#if DEBUG` only** - this is a developer diagnostic, not a user-facing
  feature, and shows whenever connected.

All 32 `YiM1Core` tests pass; the app target (including the new chip) compiles cleanly against
the real iphonesimulator SDK. On-device-unverified: actual fps/drop numbers in a real crowded-RF
environment (the whole point of building this - next time the "away from home" slowness happens,
check the chip and report what it shows).

## 2026-07-11 — Live-view stream stability (user-reported: stutter + half-second hangs + fps
## dropping to 7 while panning the camera; the fps chip above is what surfaced this concretely)

User confirmed the chip works (19.5 fps / 485 dropped in well under 30s) and reported the drop
count is real, not just an alarming number - panning visibly stutters and occasionally hangs
~0.5s. Diagnosed three compounding, independent causes and fixed all three:

1. **Reorder-tolerant packet reassembly (the biggest fix) - `LiveViewReceiver.swift` rewritten.**
   The old reassembly required each frame's UDP packets to arrive in strict ascending order and
   discarded the ENTIRE frame the instant one was out of sequence - but UDP guarantees delivery,
   not order, so a merely-*reordered* packet (routine on real Wi-Fi, not a loss) was
   indistinguishable from a genuinely lost one and treated identically. Worse during camera
   motion because bigger/more-detailed JPEGs need more packets, and more packets means a higher
   chance any single one arrives out of sequence. Rewritten to buffer packets by index in a
   `[UInt32: Data]` regardless of arrival order and reassemble once every index 0..<totalPackets
   has actually shown up; a frame now only counts as dropped if a packet is genuinely still
   missing when the next frame index starts (a real loss, not a race). Added
   `testOutOfOrderPacketsWithinAFrameStillReassemble` (packets sent 0, 2, 1 - must still
   reassemble correctly with zero drops recorded) alongside the existing dropped-packet test,
   which still passes unchanged.
2. **Bigger UDP receive buffer.** Added `setsockopt(..., SO_RCVBUF, ...)` requesting 1MB (best-
   effort - the OS may clamp it lower) so a brief stall on our end doesn't make the *kernel*
   start silently discarding datagrans before our thread even reads them. Three lines, pure
   insurance.
3. **Live-view JPEG decode moved off the MainActor - `LiveViewCanvas.swift`.** `UIImage(data:)`
   defers the actual pixel decode until first drawn, so the earlier code was paying the real
   decode cost on the MainActor the moment SwiftUI rendered each frame. This mattered a lot given
   fix from the previous section: `LiveViewReceiver`'s `.bufferingNewest(1)` policy makes the
   live-view `AsyncStream` itself drop frames whenever the MainActor consumer falls behind - so
   MainActor contention (decode cost, thumbnail loads, focus peaking) was directly causing *more*
   of the drops it was supposed to prevent runaway backlogs from. New `LiveFrameDecoding` (a
   plain enum, no captured state/actor isolation - same pattern as `FocusPeakingRenderer`, to
   avoid a compiler warning about implicitly-async cross-actor calls) forces an immediate, fully-
   decoded bitmap via `CGImageSourceCreateImageAtIndex` + `kCGImageSourceShouldCacheImmediately`
   on a background queue; `LiveFrameDecoder` (`@MainActor ObservableObject`) wraps it with the
   same keep-latest frame-dropping shape `FocusPeakingProcessor` already uses. `LiveViewCanvas`'s
   `@State liveImage` became `@StateObject private var frameDecoder`.

All 33 `YiM1Core` tests pass (32 + the new reorder test); the app target re-verified compiling
cleanly (no warnings) against the real iphonesimulator SDK. On-device-unverified: whether panning
now actually feels smooth and whether the fps/dropped-frame numbers improve in the field - that's
the real test of whether these three combined were sufficient, or whether further work (e.g. a
short grace-period/timeout before giving up on a frame instead of only the next-frame-arrival
trigger) is still needed.

## 2026-07-11 — Stream stability got WORSE after the above (regression) - root-caused with new
## instrumentation instead of more guessing, plus a real perf fix

User reported the opposite of an improvement: fps chip now showed 3.0fps/700 dropped (worse than
the pre-fix 19.5fps/485), sometimes dipping to 1-2fps, with visible stutters and ~0.5s hangs while
panning - confirming this is a genuine, felt problem, not just an alarming number. Rather than
guess again, added the diagnostic the user explicitly asked for:

**Split the single "dropped" count into two, because they indict completely different layers:**
- `droppedFrameCount` (renamed conceptually, same field): a frame's packets genuinely never all
  arrived - real network/reassembly loss, on the receiver thread.
- **New: `bufferDroppedFrameCount`**: the frame WAS fully and correctly reassembled by
  `LiveViewReceiver`, but `AsyncStream`'s `.bufferingNewest(1)` policy (added in the prior
  session's fix for the SwiftUI "multiple updates per frame" fault) discarded it before the
  MainActor consumer ever got to it, because the consumer hadn't finished with the previous frame
  yet. Captured via `continuation.yield(...)`'s own return value (`.dropped` vs `.enqueued`/
  `.terminated`) - Swift's AsyncStream already knows exactly when it discards something, this just
  reads that signal instead of leaving it unexamined. Threaded through
  `LiveViewStats`/`CameraSessionProtocol`/`CameraSession`/`MockCameraSession`, and the debug chip
  now reads "X.X fps · N net · M buf". Added
  `testBufferDroppedCountsFramesDiscardedByConsumerLag` (sends 5 complete frames back-to-back
  with no one reading the stream, then consumes once - asserts all 5 reassembled correctly but
  several show up as buffer-dropped) - this test **directly confirms** the mechanism is real: a
  perfectly good frame can vanish purely because the UI consumer is momentarily behind, and it was
  previously invisible in the stats.

**Also fixed a real efficiency regression in the reorder-tolerant reassembly itself**, since the
dictionary-based version added earlier this session runs on the hot per-packet path of the
dedicated receiver thread: replaced `[UInt32: Data]` (hashing on every packet, plus a full second
pass over all values to sum bytes for `reserveCapacity`) with a fixed-size `[Data?]` array
indexed directly by packet number, tracking a running `receivedByteCount` instead of summing
after the fact. Same reorder-tolerant behavior, meaningfully cheaper per packet - and packet count
per frame scales with camera motion (more detail -> bigger JPEG -> more packets), so this
overhead was worst exactly when the user was seeing the worst stutters.

All 34 tests pass (33 + the new buffer-drop test); app target re-verified compiling clean. **This
is diagnostic-first, not a guaranteed fix**: the real next step is the user testing again and
reporting the new split numbers - if "net" (real loss) is high, the reassembly/RF side still
needs work; if "buf" (self-inflicted) is high, `.bufferingNewest(1)` itself (or what's keeping
the MainActor busy - decode cost, focus peaking, thumbnail loads) is the thing to address next,
possibly by loosening the buffer to `.bufferingNewest(2-3)` as a cushion, or by profiling what's
actually occupying the MainActor during a stutter.

**Field data came back (user, same day): 11.5 fps · 599 net · 11 buf.** Conclusion: the MainActor/
decode side is now fine (buf ≈ 0 - the off-main decode fix worked), and essentially ALL loss is
"net" - frames whose packets never fully arrived at the reassembly layer. Three responses, all
implemented:

1. **Two-frame reassembly window (v3 of the reassembly).** The v2 reorder-tolerant logic still
   abandoned frame N the instant frame N+1's first packet arrived - but with Wi-Fi MAC-layer
   retransmissions, frame N's last packet routinely lands AFTER N+1 has started (an INTER-frame
   straggler; v2 only tolerated INTRA-frame reordering). Now up to two frames assemble
   simultaneously (`PendingFrame` struct, arrival-ordered array of ≤2): a straggler can still
   complete its frame while the next one streams in. A frame is dropped only when (a) a third
   frame index arrives while it's still incomplete (its packets are genuinely gone), or (b) a
   newer frame completes first (the older one would be stale on screen anyway - evicting on
   newer-completion also keeps yields monotonically newer with zero extra bookkeeping). Sanity
   cap on the wire-declared packet count (≤1024) so a corrupt header can't drive a huge
   allocation. New test: `testInterFrameStragglerStillCompletesPreviousFrame` (frame 1 missing a
   packet, frame 2 starts, frame 1's straggler arrives, both frames must complete with ZERO
   drops). The existing dropped-packet test still passes unchanged - its scenario (frame 2
   completing while frame 1 is incomplete) now trips eviction rule (b).
2. **Receiver thread QoS raised to `.userInteractive`** (was default): at ~600 packets/s, a
   default-priority thread competing with UI work can fall behind recv(), and a full kernel
   socket buffer silently discards datagrams - indistinguishable from RF loss in our stats.
3. **One copy per packet instead of two**: header fields now parse directly out of the receive
   buffer and the payload is copied out exactly once - the old code wrapped the entire packet in
   a `Data` first and then copied the payload out of that.

All 35 tests pass (34 + straggler test); YiM1Core cross-compiles clean for iOS. **Field-test
hypothesis to try alongside (user action, no code): the status bar shows 4G active while on the
camera's internet-less Wi-Fi - iOS periodically probes/prefers other networks in that state,
which can duty-cycle the Wi-Fi radio away from the camera's channel in bursts. Worth one test
run with Airplane Mode ON + Wi-Fi re-enabled (kills cellular and background network evaluation)
to see whether "net" drops fall significantly - if they do, that's a documentation-worthy field
tip, not a code fix.**

**Field results (user, same day): cellular-off did NOT help** - 3.5fps/1333net/3buf (cellular
disabled mid-session) and 7.0fps/1234net/0buf (cellular off from the start). Conclusions: the
network-probing hypothesis is weakened; buf≈0 consistently (our processing side is fine); net
losses persist at close range, which makes pure RF loss an unsatisfying sole explanation.

**New leading hypothesis: iOS Wi-Fi power-save + the camera AP's tiny buffer.** iPhones
aggressively sleep the Wi-Fi radio between AP beacons when traffic looks inbound-only/idle; in
power-save the AP (the camera's embedded, small-buffered AP) must buffer pending packets - at
~1MB/s of live view it plausibly overflows and drops them BEFORE they're ever transmitted. This
would also explain why the Mac (less aggressive PS, bigger antennas) never showed this. Response
(2026-07-11 evening, all implemented):

1. **Wi-Fi keep-alive uplink**: the receiver loop now sends a 1-byte datagram to the camera every
   250ms (from the same socket; fires on both packet arrivals and recv timeouts, so it keeps
   transmitting during exactly the dead-air stretches it's meant to prevent). Outbound traffic
   forces the radio awake - the classic countermeasure for this failure mode in local-streaming
   apps. Content/destination port don't matter, only the radio activity. Configurable via
   `LiveViewReceiver(port:keepAliveHost:)` (default camera IP; `nil` in unit tests).
2. **Loss forensics in `LiveViewStats`**: `framesStartedCount` (first packet seen - camera's real
   send rate), `droppedFramesMissingPackets`/`droppedFramesExpectedPackets` (dropped frames
   missing few packets = tail loss/AP buffer bursts; missing most = radio away for whole
   stretches), and `socketReceiveBufferBytes` (getsockopt readback of what the kernel ACTUALLY
   granted for our 1MB SO_RCVBUF request - verifying instead of assuming).
3. **`liveViewIncomingFPS`** on the session/protocol (computed every 5s from framesStarted
   deltas, piggybacked on the status poll): the chip now reads
   `in 18 · out 7.0 · 1234 net · 0 buf` - the in→out gap IS the loss, and "in" being low would
   instead indict the camera's own send rate.
4. **Periodic DEBUG console log** (every 5s, from the status poll): full forensic line - in/out
   fps, started/ok/net/buf counts, "dropped frames missing N% of their packets", actual rcvbuf KB.
   The user explicitly asked for richer logs to analyze with.

All tests pass; UI cross-compiles clean. **What the next field numbers will decide:** keep-alive
helping = power-save confirmed (keep it, document it); "missing N%" low (frames died missing a
packet or two) = tail loss, a 3-frame window or per-frame grace timeout might squeeze more out;
"missing N%" high = radio-away stretches, software can't fix that beyond the keep-alive; "in"
fps itself low = the camera simply doesn't send more under these conditions and the app is
already delivering nearly everything it gets.

**Field forensics round 2 (user, 2026-07-11 18:27, WITH the 250ms keep-alive active):**
`in` oscillating 8.7→26.2→14.2→19.0→15.6→30.2→30.2 while `out` tracked it at roughly half to
three-quarters; dropped frames consistently missing 18-21% of their packets; buf frozen at 7;
rcvbuf=1024KB (kernel granted the full request - socket buffer definitively cleared as a
suspect). Reading: the camera sends a steady ~30fps (the "in" peaks show it), so "in" dipping to
8-15 means whole frames vanish trace-free (first packet included) - combined with edge frames
dying with ~20% (≈6-7 consecutive) packets missing, this is the signature of the radio being
away in 50-100ms+ windows: frames fully inside a window disappear entirely, frames straddling
its edges lose a burst. Delivered fps did improve vs pre-keep-alive (peaks of 23 vs 3.5), but
the 250ms cadence evidently still leaves room for dozing between our transmissions.

**Response (same evening):**
1. **Keep-alive tightened 250ms → 100ms** - matched to the typical AP beacon interval, the
   natural rhythm of power-save wake/sleep decisions.
2. **Direct radio-away measurement**: `LiveViewStats.maxRecvGapMs` (longest gap between two
   consecutively received datagrams since the last snapshot - mid-stream the normal gap is ~1ms,
   so 50-300ms readings ARE the radio-away windows, measured rather than inferred) +
   `recvGapsOver50msCount` (how often). Only gaps >5ms take the stats lock, so the hot path
   stays cheap. The 5s `[liveview]` DEBUG log line now includes `maxgap=NNNms gaps>50ms=N`.
3. Unit tests now construct receivers with `keepAliveHost: nil` - the default camera IP made
   test runs 5x slower (sendto to an unreachable LAN address stalls on macOS) and would have
   sprayed packets at whatever real device sits at 192.168.0.10 on the test machine's LAN.

All 35 tests pass (2.5s again); UI cross-compiles clean. **Next field read:** if maxgap
regularly shows 50-300ms despite the 100ms keep-alive, the dozing isn't traffic-triggered and
software has hit its ceiling (remaining options would be documentation: charging the phone
helps, Low Power Mode hurts, etc.); if maxgap collapses to <20ms and fps stabilizes near "in",
the keep-alive cadence was the missing piece.

**Field forensics round 3 (user, 2026-07-11 18:37-18:39, 100ms keep-alive active): the picture
is strictly BIMODAL.** Good stretches: in=30, out=22-27 (!), maxgap 5-19ms, gaps>50ms counter
nearly flat - the entire pipeline sustains ~25fps delivered when the radio is listening. Bad
stretches of 15-25s: in collapses to 6-9, gaps>50ms grows +25-30 per 5s window - the radio goes
away 5-6 TIMES PER SECOND (a ~25-30% listen duty cycle). Multi-second episodes of repeated
~100-200ms off-channel excursions are the classic signature of **background Wi-Fi scans and
AWDL** (AirDrop/Handoff/AirPlay's channel-hopping protocol - a notorious cause of periodic
streaming/gaming stutter) rather than idle dozing - which also explains why the keep-alive
didn't prevent them (they're not inactivity-triggered).

Also found via the same logs: an instrumentation bug - "maxgap=0ms" printed alongside dozens of
>50ms gaps, because `statsSnapshot()` reset the peak on EVERY call and it has two callers
(per-frame stats refresh + the 5s sampler), so the per-frame calls constantly cleared the peak
before the 5s log could see it. Fixed with `statsSnapshot(resetPeakGap:)` - only the 5s sampler
resets; the cumulative gaps>50ms counter was unaffected (which is exactly why the two numbers
disagreed and exposed the bug).

**Response (same evening):**
1. `SO_NET_SERVICE_TYPE = NET_SERVICE_TYPE_VI` (interactive video) set on the UDP socket - a
   public, documented lever mapping to the WMM VI access category that hints iOS's Wi-Fi power
   management to keep the radio serviced for this flow. Best-effort.
2. The maxgap instrumentation fix above.

**Field tips for the user to test alongside (no code - these target AWDL/scan triggers):**
turn OFF AirDrop (Control Center → AirDrop → Off), disable Handoff (Settings → General →
AirPlay & Handoff), ensure Low Power Mode is off, and re-run. If bad stretches vanish with
AirDrop/Handoff off, AWDL was the culprit and this becomes a documented usage requirement for
monitor sessions - same class of advice as "one client at a time".

**Field forensics round 4 (user, 2026-07-11 18:45, Handoff + AirDrop OFF): NO improvement -
AWDL/Handoff ruled out.** Bimodal pattern persists; the now-honest maxgap (instrumentation fixed
last round) shows the true magnitude: radio-away excursions of 300-630ms, 6-7 per second during
bad stretches, alternating with clean ~25fps-delivered periods. Two suspects remain:

1. **Bluetooth/Wi-Fi antenna coexistence.** iPhones share one 2.4GHz antenna between BT and
   Wi-Fi; ANY ongoing BLE traffic (an Apple Watch on the wrist and/or AirPods are constant BLE
   chatters!) steals radio time in exactly this periodic pattern. Also found on code review:
   `BLEPairing` never explicitly disconnected from the camera after the handshake - the link
   only died implicitly on object dealloc. Now torn down deterministically
   (`cancelPeripheralConnection` + `stopScan` right after credentials are obtained).
2. **iOS roam-scanning because the camera Wi-Fi has no internet.** iOS marks such networks and
   periodically scans for "better" known networks - and at home, the user's home Wi-Fi is right
   there advertising itself. Multi-second scan sweeps would produce exactly these episodes.

**Next field tests, in order of diagnostic value:**
1. **Bluetooth fully OFF** (Settings → Bluetooth, NOT Control Center - CC leaves BLE partly on),
   take off/disconnect Apple Watch/AirPods if worn, connect to camera via "already on Wi-Fi"
   (direct, no BLE needed), run. Bad stretches gone → coexistence was it.
2. **Home Wi-Fi Auto-Join OFF** (Settings → Wi-Fi → (i) on the home network → Auto-Join off,
   re-enable after), run. Bad stretches gone → roam-scanning was it.
3. If neither: Location Services off temporarily (location triggers Wi-Fi scans too).

**Field forensics round 5 (user, 2026-07-11, Bluetooth fully OFF): CULPRIT CONFIRMED -
Bluetooth/Wi-Fi antenna coexistence was the dominant cause.** With BT off: long stretches of
**out 27-29fps at in=30** (essentially perfect delivery - and the in→out gap of only ~2fps shows
the whole earlier pipeline work paid off), gaps>50ms nearly flat for tens of seconds at a time.
ONE residual ~25s bad episode remained (in=3.1-3.7, maxgap 525-1043ms - radio away for over a
SECOND at a time). That episode's signature differs from the BT pattern (much longer excursions,
300-600ms was BT's range) and matches the remaining suspect: **iOS roam-scanning toward the
known home network** (camera Wi-Fi has no internet; home Wi-Fi beckons). Startup was also rough
(RCStartRemoteCtl needed a retry, first ~15s choppy) - connection-establishment phase, separate
minor issue.

**FIELD USAGE RULE #1 (documented, to surface in the app's Phase-4 polish later):** for stable
monitor sessions, turn Bluetooth OFF - via Settings, not Control Center - and disconnect/remove
Apple Watch / AirPods. Since BLE pairing needs BT, the workflow is: (1) camera on, pair via BLE
as usual, (2) join the camera Wi-Fi, (3) Settings → Bluetooth OFF, (4) app → "Connect (already
on camera Wi-Fi)" - the credentials stay valid until the camera power-cycles, so direct
reconnect works without BLE.

**Still pending: the Auto-Join test** (home Wi-Fi → Auto-Join off) to nail the residual ~25s
episodes. If confirmed → FIELD USAGE RULE #2.

**Field forensics round 6 (user, 2026-07-11, home Wi-Fi Auto-Join OFF): residual episodes NOT
eliminated** - one ~25s episode with the same signature (maxgap 500-1022ms, in=3-4) occurred at
roughly the same rate as round 5 (~once per 2-3 minutes). Auto-Join ruled out as the residual
cause - which fits: disabling Auto-Join stops iOS *joining* other networks, not *scanning* for
them, and periodic system Wi-Fi scans happen regardless. Baseline aside from the episode was
excellent again: out 26-28.5fps sustained.

**Conclusion - likely at the OS ceiling.** The remaining pattern (a ~20-25s degraded stretch
every ~2-3 minutes, radio away up to ~1s at a time, self-recovering) matches iOS's periodic
background roam/scan cycles, which apps cannot suppress. Expected behavior to document for the
monitor use case: with Bluetooth off (RULE #1), expect ~27-28fps with a brief self-recovering
degradation every few minutes. Optional last-mile field test if the user ever wants to squeeze
further: Location Services fully off (Settings → Privacy - location triggers extra Wi-Fi scans)
+ "Ask to Join Networks" off; unverified whether it reduces episode frequency.

**Possible Phase-4 polish item derived from this work:** a subtle "weak link" indicator during
episodes (the receiver's gap counters spike measurably when one starts) - so the shooter knows
the stutter is the radio link, not the camera or a hang; purely informational.

## Backlog additions (user, 2026-07-11 end of session, researched same day)

1. **Top bar rework: status chip replaces the "YI M1 Monitor" title.** The connected-state text
   ("Connected · 75% · 412 shots") truncates in the current chip; the title is the least useful
   element there. Move the status into the title's position and make it a tappable menu that
   absorbs the connection actions (Connect BLE / Connect direct / Disconnect / Reset) - freeing
   the separate ConnectionMenu button's space. Pure UI rework in `RootView`/`ConnectionMenu`.

2. **DJI Mimo-style system Wi-Fi join dialog - RE-EVALUATE `NEHotspotConfiguration`.** The user
   spotted DJI Mimo showing the native "'DJI Mimo' Wants to Join Wi-Fi Network 'OsmoNano-XXXX'?"
   alert - that IS `NEHotspotConfiguration.apply` (Network Extension → Hotspot Configuration),
   the API our plan deferred as v2 assuming it needs a paid account. Research (2026-07-11) was
   inconclusive on personal-team availability: Apple docs just document the entitlement; an old
   forum quote about "requesting the NEHotspot entitlement" refers to the OLDER, restricted
   `NEHotspotHelper` API, NOT `NEHotspotConfiguration` (a standard Xcode capability checkbox
   since iOS 11). **Action: test empirically** - add the "Hotspot Configuration" capability in
   Xcode with the user's free personal team; if the provisioning profile generates, implement
   the DJI-style join (BLE gets credentials → `NEHotspotConfiguration(ssid:passphrase:)` → one
   native tap instead of the whole manual sheet/Settings flow). If the profile fails, the
   manual sheet stays and this is settled for good.
   **The other half of the user's ask - programmatic hardware Bluetooth toggling - is NOT
   possible on iOS**: no public API lets an app turn BT off (DJI can't either; their app just
   benefits from the same manual discipline). Our equivalent: a pre-session reminder/checklist
   in the UI ("Bluetooth off for a stable feed") as part of the Phase-4 polish.

3. **Recording auto-restart around the camera's built-in clip limits.** Research confirms the
   limits (user remembered them roughly right): YI's own help pages state a 30-minute recording
   limit (standard EU-import-tax-era cap) and 4K clips fixed at ~8.5 minutes due to the 4GB
   FAT32 file-size ceiling (some reviewers measured ~7.5 min; bitrate-dependent). Plan:
   - **First: on-device diagnosis (user's own suggestion)** - start a recording, let it hit the
     limit, and observe what the app sees: does `isRecording` stay true (state desync)? Does
     live view visibly switch back to preview? Does anything in the live-metadata header or
     GetCameraStatus change? That determines the detection mechanism.
   - **Then: auto-restart** - at minimum a local timer (we know the elapsed time and the video
     format), proactively sending VideoRecordingStart when the camera's limit stops the clip
     (with the existing 1.5s record-command cooldown respected; a 1-2s gap between clips is
     physically unavoidable). If diagnosis reveals a detectable "recording stopped" signal,
     react to that instead of/in addition to the timer. Surface it in the UI (e.g. the recording
     timer chip shows "clip 2 · 3:12").
   - **Bypass research (2026-07-11): a true nonstop bypass is IMPOSSIBLE - all hardware routes
     closed.** (a) Firmware modification: the only tooling is the same unpacker/repacker our own
     research is built on, long established as unsafe to flash (non-byte-identical repack);
     community project archived May 2024. (b) HDMI external recording: the M1's micro-HDMI is
     PLAYBACK-ONLY - plugging a cable in immediately STOPS recording and switches modes; no live
     output exists. (c) exFAT to dodge the 4GB ceiling: camera requires FAT32. The app-side
     auto-restart above is the best physically possible outcome.
   - **Nuance the on-device diagnosis should settle:** YI's own help wording ("videos are all
     fixed at 8:30 in 4K") suggests the camera may auto-SPLIT into a new file at the 4GB
     boundary and keep recording (action-cam style) rather than stopping - in which case only
     the 30-minute cap actually stops recording, and auto-restart is needed just once per half
     hour (a 1-2s gap every 30 min ≈ near-perfect nonstop). If 4K genuinely stops at ~8:30, the
     timer-based restart fires every ~8 min instead. Either way the plan works; the test decides
     the cadence.

## Backlog — approved next steps (2026-07-09, in this order of discussion, priority TBD)

1. **Phase 4 polish (from Part 5):** clear in-app guidance for permission-denied paths
   (Bluetooth off, Local Network denied, user backs out of the manual-join flow), empty/error
   states, connection-stuck reset UX, and the macOS quirks copy (video format read-only w/ lock
   note, "camera screen is locked during a session", one-client note).
2. **Landscape / on-camera-monitor layout (post-v1, the user's real target form factor):** see
   the Part 6 orientation note - live view filling most of the frame, controls as a thin
   overlay/sidebar; needs a real landscape-specific arrangement, not a rotated vertical stack.
3. **macOS parity/fixes:** port the iOS camera-vanished detection (consecutive status-poll
   failures → disconnect + error; macOS currently stays "Connected" forever with a frozen live
   view), and the long-standing Wi-Fi-restore-on-disconnect fix (macOS roadmap item 3 -
   Location Services / CoreWLAN-free SSID detection or a manual "restore to" setting).
4. **Photo previews (thumbnails) in the iOS file browser (user request 2026-07-09):** show a
   small thumbnail per file row instead of text-only. Protocol-wise this is already available -
   `GetFile` with `resulotion: "Thumbnail"` (`FileQuality.fast`, smaller than the ~228KB
   MidThumb used for the post-shot review; exact size unmeasured). Design notes for
   implementation: load lazily per visible row (List cells appear → fetch), cache in-memory by
   path, and remember the camera can only handle ONE http request at a time (HTTPClient already
   serializes - a burst of thumbnail fetches will simply queue, so consider fetching only
   visible rows and cancelling scrolled-away ones to keep the queue short; also mind that a
   long full-size download will stall thumbnail loads and vice versa). Video files may or may
   not serve thumbnails via the same command - verify on-device; fall back to a type icon.

### Feature backlog from the 2026-07-09 brainstorm (user-approved selections)

**Approved, no open questions:**
- ~~**Keep screen awake during a session**~~ **DONE 2026-07-09**: `UIApplication.isIdleTimerDisabled`
  tracks `connectionState == .connected` in RootView (restored on disconnect/error/onDisappear).
- ~~**Recording timer**~~ **DONE 2026-07-09**: `RecordingTimerChip` (red dot + monospaced mm:ss,
  hours shown when >1h) floats over the top of the live view, driven by a 1s `TimelineView`;
  counts locally from the moment `isRecording` flipped true.
- **Focus peaking** - edge highlighting over live view; the top-value monitor feature given the
  user's manual-focus lens. NOTE: unlike exposure tools, peaking is NOT invalidated by the
  preview's auto-exposure quirk (edges are edges regardless of brightness) - it can work
  pre-record. Implementation: per-frame edge detection (Sobel/gradient threshold) on the decoded
  live-view JPEG; frames are small so CPU should be fine, but profile on-device.
- **Multi-select in the file browser** - batch download / batch delete (DeleteFile already takes
  an array of paths - single command).
- **Save downloads directly to the Photos library** (PHPhotoLibrary + NSPhotoLibraryAddUsageDescription)
  instead of (or alongside) the share sheet.
- ~~**Haptic feedback**~~ **DONE 2026-07-09**: `UIImpactFeedbackGenerator` on the shutter action -
  .medium for photo, .heavy for record start/stop.
- ~~**Camera battery warning**~~ **DONE 2026-07-09**: slim red banner under the top bar when the
  polled batteryLevel is ≤15% (threshold constant in RootView's `lowBatteryLevel`).

**Approved with caveats / needs on-device tests first:**
- **Punch-in zoom via a button** (like the camera's own zoom button, not pinch) - user is
  skeptical the live-view resolution is enough for it to be useful. Cheap to build; try it and
  judge with eyes. If the JPEG is too soft when magnified, drop the feature.
- **Exposure tools (histogram/zebras/false color) - ONLY meaningful while recording.** User
  correctly pointed out the known quirk (macOS ARCHITECTURE.md §12 / live-testing-findings §12):
  the pre-record live view runs an auto-exposure-ish preview pipeline that does NOT reflect the
  real exposure, so pre-record scopes would show garbage. Once recording starts, live view
  switches to the REAL crop + exposure - scopes could activate automatically right then. BUT the
  user also reports the during-recording live view has low fps and visible artifacts - **needs an
  on-device test before building anything**: record, watch the feed, judge whether frame
  quality/rate is good enough to drive a histogram/zebras meaningfully.

**Device-test results for the 2026-07-09 batch (user, 2026-07-11):** recording timer ✓, haptics ✓,
thirds/diagonals new semantics ✓, app launch speed is fine when launched normally (so the earlier
"slow launch" was indeed debugger/Simulator overhead - launch-screen item deprioritized).
Screen-awake and battery banner unverified but low-risk; the record-desync fix (body-code check +
cooldown + long-press force-stop) is still UNTESTED on-device - exercise it next time (rapid
start/stop cycles, then long-press).

**New observation to investigate (user, 2026-07-11): live view seemed slower away from home.**
Most likely RF environment (the camera's AP is 2.4GHz; away-from-home = crowded spectrum or more
distance), not a code issue - but we currently have zero visibility into feed health.

- **Live-view fps/drop diagnostics (APPROVED for the plan, user 2026-07-11):** an optional debug
  overlay showing live-view fps + dropped/invalid frame count. LiveViewReceiver already detects
  and discards broken frames (the `frameValid` path) - it just doesn't count them; add counters
  to `LiveViewFrame`/receiver stats and a small toggleable overlay chip. Distinguishes "camera
  sends fewer frames" vs "phone drops packets" vs "subjective" next time the field slowness
  happens.

- **File browser UX rework (user feedback 2026-07-11): swipe-to-reveal download/delete is
  unintuitive - rethink row actions.** Candidate directions, to be combined with the already-
  planned thumbnails + multi-select + save-to-Photos into ONE coherent rework rather than three
  bolt-ons:
  - **Tap a row → file detail screen** (large preview via MidThumb, filename/date/type, explicit
    Download / Save to Photos / Delete buttons) - the most discoverable, gallery-like pattern,
    and the natural home for save-to-Photos. Recommended primary direction.
  - **Selection mode** (Edit button or long-press) with a bottom toolbar for batch
    Download/Delete - this IS the multi-select feature; one mechanism for single and batch.
  - Keep swipe actions as a power-user shortcut (they cost nothing to leave in).
  - Alternative considered: visible per-row action buttons - rejected-by-default (clutters rows,
    doesn't scale to thumbnails), revisit only if the detail screen feels too heavy.

- **Startup optimization / perceived-launch fix (user request 2026-07-09):** the app takes long
  enough to launch that it reads as frozen - add a launch indicator so there's no dead-screen
  effect. Approach, in order: (1) first measure what's actually slow WITHOUT the debugger
  attached (the reported hangs - 2.5s+ - were all under Xcode's debugger + Simulator, both of
  which inflate launch massively; a clean on-device tap-the-icon launch may already be fine);
  (2) make the launch screen meaningful - `UILaunchScreen` in project.yml is currently an empty
  dict (blank screen): give it the app's dark background color (and optionally the icon) so the
  transition from tap to UI feels instant and branded rather than "hung"; (3) only if a real
  post-launch delay remains, add an explicit lightweight "starting…" state in RootView
  (ProgressView over AppColor.bg) - but nothing in our init path should genuinely take seconds
  (CameraSession init is trivial, no networking until Connect is tapped), so (1) will likely
  show it's debugger/Simulator overhead.

**Rejected:** auto-download after each shot (not wanted).

**Open question to test on-device (user suggested):** does the camera auto-power-off on its own
while a phone remote-control session is active (i.e. does its idle/sleep timer keep running when
the screen is locked by the session)? If yes - how does it manifest on the app side (probably
the camera-vanished detection kicking in after ~15s)? Worth a deliberate test: connect, don't
touch anything, wait past the camera's auto-off interval, observe. The result decides whether
the app needs a keep-alive (e.g. a periodic harmless command) or just a specific "camera powered
off" message.

---

**Recording-state desync fixed (first CAMERA-side bug caught, on-device 2026-07-09):** rapid
record start/stop cycling left the camera recording (its own controls locked by the session -
known quirk) while the app showed "not recording". Root cause on our side: the camera reports
command failures as **HTTP 200 + `{"code":<err>}` in the body** (same shape as the 1515/1502
errors seen earlier), and `toggleRecording` flipped `isRecording` on transport status alone - a
body-level Stop failure was silently counted as success. Three-part fix: (1) new
`HTTPClient.Response.isCameraSuccess` (transport 200 AND body code 200 when the body is
JSON-with-code; regression-tested incl. the observed 1515/1502 bodies) now gates
`toggleRecording`, `startRemoteControlSession`, `shootPhoto`'s RCDoShooting, and `deleteFile`;
(2) a 1.5s cooldown after every record command (the firmware needs a beat to finalize a file -
rapid cycling is what wedged it); (3) an escape hatch: **long-press the shutter in video mode
force-sends VideoRecordingStop** regardless of the believed state (`forceStopRecording()` in the
protocol; warning haptic) - recovery without disconnecting. User-side recovery for a wedged
camera: Disconnect (releases the camera's control lock via RCStopRemoteCtl), then stop
physically, or power-cycle the camera. All 32 tests pass.

**Guide behavior fixed (user feedback 2026-07-09, after on-device use):** (1) thirds/diagonals
no longer disappear during recording - the old code early-returned after drawing the "Recording"
note; now the note draws AND the guides span the full visible frame (which during recording IS
the real capture area, since the feed switches to the actual crop - macOS fact §12; only the
now-redundant dashed outline is suppressed). (2) Pre-record, thirds/diagonals now ALWAYS follow
the effective capture area (measured video/photo crop for the current format/aspect),
independent of the Crop-outline toggle - FHD/4K record 16:9, so guides across the full 4:3
preview were compositionally wrong. The Crop toggle now only controls the dashed outline+label;
`drawCrop` was split into `cropCGRect` (geometry) + `drawCropOutline` (drawing) accordingly.

**Manual live-view rotation for vertical shooting (user request 2026-07-09).** The user's real
use case: shooting with the camera physically mounted sideways - the sensor stream then arrives
rotated on the phone. Design decision (user asked for opinion, agreed manual switching): NOT a
split of the Photo/Video mode toggle (orientation is an independent axis - it applies to photo,
video, and the crop overlays alike), but a single rotate button in the top bar cycling
0° -> 90° -> -90° (`ViewRotation` enum, `AppIcon.rotate` = SF "rotate.right", amber when
active). Implementation in `LiveViewCanvas`: the live image and photo-review image rotate via
`rotationEffect` (fitted rect computed from the swapped display size; inner frame uses
pre-rotation dims - rotationEffect is purely visual); guide overlays are drawn in *visual* space
with only the crop-rect fractions coordinate-transformed (`visualCrop`), so thirds/diagonals
land correctly inside the rotated crop AND text labels stay upright; tap-to-focus inverse-maps
visual touch points back to sensor pixel coordinates (`sensorRelativePoint`). Rotation is
UI-only - nothing about the protocol or sent commands changes.

---

## 2026-07-12 — I1: NEHotspotConfiguration spike (TASKS_V2_IOS_THEN_MACOS.md, Phase I)

Programmatic Wi-Fi join, replacing the assumption from Part 4.2 that this needed a paid Apple
Developer account. New `HotspotJoiner` actor (YiM1Core, guarded
`#if canImport(NetworkExtension) && os(iOS)` so the macOS host build used for `swift test`
still compiles): wraps `NEHotspotConfiguration(ssid:passphrase:isWEP:false)` +
`NEHotspotConfigurationManager.shared.apply`, `joinOnce = false`. Wired into
`CameraSession.connectViaBLE`: after BLE hands back credentials, try the hotspot join first;
on success, skip the manual sheet entirely and go straight to `.connecting` + a 20s reachability
poll + `startRemoteControlSession()`. On **any** failure - `apply` throwing, or a "successful"
join that still isn't reachable within 20s - falls through unchanged to the pre-existing
manual-join sheet path (`pendingWiFiCredentials` + `.awaitingWiFiJoin`). `WiFiJoinSheet.swift`
was not touched and remains the fallback exactly as before.

Entitlement: `com.apple.developer.networking.HotspotConfiguration = true`. Gotcha hit while
wiring this up - **xcodegen owns and regenerates `YiM1Monitor.entitlements` from
`project.yml`'s `entitlements.properties` key; hand-editing the `.entitlements` file directly
gets silently overwritten back to `<dict/>` on the next `xcodegen generate`.** Fixed by adding
the key under `properties:` in `project.yml` instead - regenerating now correctly emits the
entitlement into the file. Worth remembering for any future entitlement additions.

Verified: YiM1Core builds clean for both the macOS host target (`swift build`) and the iOS
simulator cross-compile target; all 35 tests still green; a full `xcodebuild` of the
`YiM1Monitor` app target for `iphonesimulator` (`CODE_SIGNING_ALLOWED=NO`) succeeds with the
new entitlement + `HotspotJoiner` in place.

**User-verification still required (cannot be done from here):** whether the free/personal-team
provisioning profile will actually sign an app carrying the Hotspot Configuration entitlement.
Build to a real device in Xcode:
- If it builds/signs normally → the spike works; on the next BLE connect attempt, watch for the
  native "'YiM1Monitor' Wants to Join Wi-Fi Network" system alert (same one seen in the DJI Mimo
  screenshot) - accepting it should connect with no manual sheet at all.
- If signing fails with an entitlement/provisioning/capability error → open `project.yml`,
  delete the `com.apple.developer.networking.HotspotConfiguration: true` line under the
  `YiM1Monitor` target's `entitlements.properties`, run `xcodegen generate` again, and rebuild -
  this reverts to the empty entitlements file and the manual sheet continues exactly as before
  (nothing else needs to change; the runtime fallback means the connect flow degrades
  gracefully either way).

**VERDICT (user-verified on-device, 2026-07-12): the spike FAILED at the provisioning gate -
question closed permanently, do NOT re-attempt.** Xcode's exact error: *"Personal development
teams, including [the user's], do not support the Hotspot capability."* So the original Part 4.2
assumption was right for the wrong reason: `NEHotspotConfiguration` is not the restricted
`NEHotspotHelper`, but the Hotspot Configuration CAPABILITY still requires a paid Apple
Developer Program membership to appear in a provisioning profile - DJI Mimo can use it because
DJI has a paid account. There is no free-team workaround.

The revert went FURTHER than the instructions above (full code revert, not just the
entitlement): `HotspotJoiner.swift` deleted, `tryHotspotJoin`/the hotspot-attempt block removed
from `connectViaBLE` (restoring the exact pre-I1 flow: BLE → credentials → `.awaitingWiFiJoin` →
manual sheet), the `entitlements:` section dropped from `project.yml`, and the `.entitlements`
file deleted. That's the right call - the code could never succeed on this team, so keeping it
as dead weight had no value. Verified after the revert (this session): no functional hotspot
references remain anywhere (only explanatory comments in `WiFiConnector.swift`/
`WiFiJoinSheet.swift`), `xcodegen generate` runs clean, the full app target builds for
`iphonesimulator`, and all 38 YiM1Core tests pass. The manual join sheet is the permanent v1
Wi-Fi flow unless a paid developer account ever appears.

## 2026-07-12 — I2: Top bar rework (TASKS_V2_IOS_THEN_MACOS.md, Phase I)

Fixed the truncating status chip ("Connected · 76% · 412 shots" was clipping) by removing the
"YI M1 Monitor" title and giving the chip that freed leading width. The chip is now the
connection menu's own tappable label instead of a separate trailing ellipsis button:
`ConnectionMenu` became generic over its label (`ConnectionMenu<Session, MenuLabel: View>`,
`@ViewBuilder label: () -> MenuLabel`) so RootView can pass `{ statusChip }` straight in - the
menu content (Connect BLE / Connect direct / Disconnect / Reset, same enable/disable logic) is
untouched. Hit one naming collision while doing this: naming the generic parameter `Label`
shadowed SwiftUI's own `Label` view used inside the menu items (`Label("Connect (Bluetooth)",
systemImage: ...)`) - renamed the generic to `MenuLabel`. Added a small chevron.down to
`statusChip` so it still reads as tappable now that the ellipsis icon is gone. Peaking/rotate
buttons stayed on the trailing side, untouched.

Verified: full `xcodebuild` of the app target for `iphonesimulator` succeeds. Also
booted an iPhone 17 Simulator, temporarily swapped `App.swift` to `MockCameraSession` +
`connectDirect()` on appear (reverted after), and screenshotted the running app: the full
"Connected · 76% · 412 shots" string renders with room to spare, chevron present, peaking/rotate
buttons intact on the trailing side. Did not exhaustively re-test every menu action's enabled/
disabled state live (the underlying `ConnectionMenu` logic itself was not touched, only its
label), so a final on-device pass by the user is still worthwhile but low-risk.

## 2026-07-12 — I3: Weak-link indicator (TASKS_V2_IOS_THEN_MACOS.md, Phase I)

User-facing counterpart to the DEBUG fps chip, built directly on the radio-away forensics from
the stutter investigation. `CameraSession` now tracks the delta of
`LiveViewStats.recvGapsOver50msCount` between each 5s `sampleLiveViewStats()` tick (that counter
is cumulative since the receiver started, so a delta - not the raw value - is what indicates
"something's wrong right now"). New `@Published var liveViewLinkUnstable: Bool`: set true when
the delta exceeds 10 (field logs during the investigation showed ~25-30 new gaps per 5s during a
radio-away episode vs ~0-2 normally, so 10 sits comfortably clear of both); cleared only on a
fully clean sample (delta == 0) - a delta that's nonzero but under the threshold holds whatever
state was already showing, so one stray gap right after a bad window doesn't flicker the chip.
Added to `CameraSessionProtocol` and `MockCameraSession` (hardcoded `false` - no real feed to
measure). UI: a small amber ("Weak link" + `wifi.exclamationmark`, `AppColor.accent` to match
the existing active-state amber) chip at the live view's top-leading corner (top-center is the
recording timer, top-trailing is the DEBUG fps chip - three independent corners, no collisions).
Unlike the fps chip this one is NOT `#if DEBUG` - it's meant for the field, not just development.

Verified: all 35 YiM1Core tests still green; full `xcodebuild` of the app target for
`iphonesimulator` succeeds. Not verified live against a real radio-away episode (needs the
actual on-device stutter conditions from the earlier investigation) - the threshold/hysteresis
values are carried over directly from that investigation's own field-measured numbers, so they
should hold, but worth having the user confirm the chip actually appears during a real episode
next time they're shooting away from home.

## 2026-07-12 — I4: Recording auto-restart (TASKS_V2_IOS_THEN_MACOS.md, Phase I)

Near-continuous recording via app-side stop/start just under the camera's own recording-length
limits - true nonstop recording is impossible on this camera (firmware repack unsafe, HDMI
playback-only, FAT32 required; see the researched-not-tested backlog notes further up).

New pure-logic type `RecordingAutoRestart` (YiM1Core, unit-tested,
`RecordingAutoRestartTests.swift`, 3 tests): per-format restart intervals with a safe margin
under the known caps - `fhdRestartInterval` = 29:30 (under the ~30-minute general cap),
`fourKRestartInterval` = 8:00 (under the ~8.5-minute 4K/4GB-FAT32 ceiling), prefix-matched
against the `VideoFormat` metadata string using the same convention as `MeasuredCrops.video`
("4K_24" matches "4K"). **Still open, pending the user's own on-device stopwatch-across-the-
boundary test:** whether 4K actually seamlessly splits into a new file at that boundary (in
which case only the 30-minute cap would apply to it too) - if so, only `fourKRestartInterval`
needs bumping to match the FHD value; nothing else in this feature changes.

`CameraSession`: new `@Published var autoRestartRecording: Bool` (default off, user-settable)
and `@Published private(set) var recordingClipNumber: Int` (starts at 1, increments per
restart, resets to 1 whenever recording starts fresh). A monitor task (`startAutoRestartMonitor`)
runs for the lifetime of the current recording (launched alongside it in `toggleRecording`,
cancelled on any stop/disconnect/reset/connection-loss path), polling once a second rather than
sleeping for the whole interval up front so toggling the setting mid-recording takes effect
within a second. `performAutoRestart()` does stop -> cooldown -> start through the exact same
command-grade machinery as a manual toggle (`recordingCommandInFlight` + the 1.5s cooldown -
never bypassed, since rapid cycling is what wedged the real camera during the 2026-07-09 desync
bug). `isRecording` genuinely flips false-then-true across the restart (not held true through
the gap), which has a nice side effect: RootView's existing `onChange(of: session.isRecording)`
naturally resets the on-screen per-clip timer with zero new UI-side wiring, and a failed restart
correctly leaves the UI showing "not recording" instead of lying about camera state. Left an
explicit `// TODO (I4 hook point)` in the monitor loop for whatever detection signal the user's
diagnosis finds (metadata field, GetCameraStatus change, live-view behavior) - once known, that
check goes in ahead of the timer-based fallback for a faster, clock-drift-immune restart.

UI: `RecordingTimerChip` now takes a `clipNumber` and shows "clip N · mm:ss" once N > 1 (plain
elapsed time otherwise - no change for the common case). Settings sheet (`SettingsStrip.swift`'s
`SettingsSheet`) gained a "Auto-restart recording (beta)" toggle row, video-mode only, appended
after the existing settings list.

Added to `CameraSessionProtocol` (`autoRestartRecording: Bool { get set }`,
`recordingClipNumber: Int { get }`) and `MockCameraSession` (toggle is settable for the UI to
work against in previews, but the mock has no real recording loop so it never actually
restarts anything).

Verified: 38 YiM1Core tests green (3 new); full `xcodebuild` of the app target for
`iphonesimulator` succeeds. Not verified live (needs a real recording session to watch a
restart actually happen) - this is exactly the kind of change that benefits from the user's own
on-device pass, especially alongside the still-pending clip-boundary diagnosis test.

## 2026-07-12 — I5: Phase-4 polish batch (TASKS_V2_IOS_THEN_MACOS.md, Phase I)

A coherent pass over the remaining rough edges from the original Phase 4 plan and everything
learned since:

- **Permission-denied paths.** `BLEPairing.centralManagerDidUpdateState` now maps
  `.poweredOff`/`.unauthorized`/`.unsupported` to specific human-readable reasons instead of
  interpolating the raw `CBManagerState` enum; `CameraSession.bleFailureMessage(for:)` turns
  `BLEPairingError.bluetoothUnavailable` into "<reason> - turn Bluetooth on in Settings and try
  again." (other BLE errors keep the generic message). Local Network permission denial can't be
  detected directly (a denied prompt just makes every HTTP call time out, indistinguishable from
  "wrong Wi-Fi network" or "camera out of range") - added a `hasEverConnected` flag
  (UserDefaults-backed, set the first time `startRemoteControlSession` succeeds) that gates a
  hint appended to the unreachable-camera error messages in `connectDirect()` and
  `confirmWiFiJoinInProgress()`'s catch: only shown before the first-ever successful connection,
  since a returning user almost certainly has a different (mundane) problem.
- **Pre-session checklist.** New `FieldTipsSheet.swift` - a static list of the field rules this
  project's investigation actually found (Bluetooth off, expected self-recovering stutters from
  iOS's background Wi-Fi scans, camera screen/controls locking during a session, one client at a
  time, set video format before connecting). Triggered by a new `info.circle` button in the top
  bar (`fieldTipsButton`, next to peaking/rotate) rather than folding it into `ConnectionMenu` -
  keeps that generic component's signature unchanged.
- **Quirks copy.** The video-mode Format/Audio/EIS chips in `SettingsStrip` (confirmed dead
  commands on the wire - HTTP 404 despite valid firmware handlers, see ARCHITECTURE.md) now use
  a new `readOnlyChip` instead of the tappable `chip`: not wrapped in a Button, a small
  `lock.fill` glyph next to the title, dimmer value text - reads as "shown, not settable" rather
  than a broken button.
- **"Camera powered off" specificity.** `startStatusPolling`'s connection-lost message is now
  "Lost connection to the camera (camera off or out of range)" - can't actually distinguish the
  two cases from here (both just stop answering), but the qualifier at least points the user at
  what to check instead of implying an app bug.
- **Launch screen.** Added a `LaunchBackground` color asset (`#0c0d0f`, matching `AppColor.bg`)
  to `Assets.xcassets` and set `UILaunchScreen.UIColorName` to it in `project.yml` (previously an
  empty dict - blank/white flash on cold launch). Note from the earlier startup-perf research:
  the reported 2.5s+ launch hangs were suspected Xcode-debugger/Simulator overhead, not a real
  app delay - this fix addresses the cosmetic flash regardless of that being confirmed.
- **Camera auto-power-off:** nothing built here (matches the plan - it's a user on-device test,
  not a code change); still an open item for the user to run whenever convenient.

Verified: 38 YiM1Core tests green; full `xcodebuild` of the app target for `iphonesimulator`
succeeds. Visually verified in the iPhone 17 Simulator (temporarily swapped to
`MockCameraSession`, reverted after): the field-tips sheet opens from the new info button and
renders all five tips correctly; switching to Video mode and scrolling the settings strip shows
the Format/Audio/EIS chips with the lock glyph, clearly distinct from the tappable chips.
Permission-denied message text and the launch-screen color were reviewed in code but not
exercised live (the former needs an actual denied-permission device state to trigger; the latter
only shows during the ~instant before SwiftUI takes over, hard to screenshot meaningfully).

## 2026-07-12 — I6: Landscape / on-camera-monitor layout (TASKS_V2_IOS_THEN_MACOS.md, Phase I - LAST iOS item; iOS backlog now complete)

The reason this app exists: mounted on/near the camera as a field monitor, normally landscape.
`project.yml` now allows `UIInterfaceOrientationLandscapeLeft`/`LandscapeRight` alongside
Portrait. `RootView` detects orientation via `@Environment(\.verticalSizeClass)` (compact = iPhone
landscape - angle-independent, correctly treats Left/Right the same) and branches into two
completely different layouts rather than letting the portrait stack simply rotate:

- **`portraitBody`** - the exact same VStack as before this task, byte-for-byte behaviorally
  unchanged (topBar/battery-warning/ModeToggle/live-view/controlRow/SettingsStrip stacked
  vertically).
- **`landscapeBody`** (new) - the live view fills the entire frame edge-to-edge
  (`.ignoresSafeArea()`); every control floats over it in three clusters, each button/toggle
  wrapped in a new `edgeScrim()` view modifier (translucent black pill background) so icons stay
  legible over a bright or busy image:
  - **Leading edge:** the status chip/connection menu, the DEBUG fps chip (if built in debug),
    then field-tips/peaking/rotate buttons stacked vertically (these were the top bar's trailing
    cluster in portrait).
  - **Trailing edge:** mode toggle, shutter (reusing the exact same `ShutterButton` + haptics +
    long-press-force-stop gesture as portrait's `controlRow`, factored into a shared
    `shutterControl`), Files, a new settings button, then the crop/thirds/diagonals guide toggles
    - the portrait control row's contents, rearranged vertically.
  - **Top-center:** recording timer + weak-link chip (both reused as-is) + a new compact
    `batteryWarningChip` (the portrait `batteryWarning` is a full-width bar, which doesn't make
    sense floating over the middle of a full-frame image).
  - **Settings strip is hidden entirely** (no vertical room for it) - the new trailing-edge
    settings button (`slider.horizontal.3` icon) presents `SettingsSheet` directly as a sheet.
    `SettingsSheet` (previously `private` inside `SettingsStrip.swift`) is now internal so
    `RootView` can present it without duplicating that view; `SettingCatalog` gained a
    `keys(forMode:)` static helper so both call sites (the portrait strip and the landscape
    sheet) build the identical mode-aware key list from one place instead of two copies of the
    same expression.
  - The live-view canvas itself (`liveViewStack`, factored out of the old inline `ZStack` so both
    orientations share one implementation) needed zero changes - all its overlays (crop/thirds/
    diagonals/peaking, tap-to-focus) are already layout-agnostic; only the recording-timer/weak-
    link/fps chip trio is gated to portrait-only within `liveViewStack` (landscape draws its own
    copies of those three, positioned for its own layout, in `landscapeBody`).
- The manual rotate button (`ViewRotation`, for a physically-sideways-mounted camera) is
  unchanged and still independently useful on top of phone-orientation rotation.

Verified: 38 YiM1Core tests green; full `xcodebuild` of the app target for `iphonesimulator`
succeeds. Visually verified end-to-end in the iPhone 17 Simulator (temporarily swapped to
`MockCameraSession`, reverted after) across an actual portrait -> landscape -> portrait rotation
(`Device > Orientation`/Cmd+Left/Right): portrait layout unchanged; landscape shows the live view
full-frame with all three control clusters correctly scrimmed and positioned; tapped the new
landscape settings button and confirmed `SettingsSheet` opens with the same content as the
portrait strip's sheet; switched to Video mode and started/stopped a (mock) recording, confirming
the shutter button turns into the red recording state and the top-center `RecordingTimerChip`
appears and counts correctly in landscape. Did not test the interaction between manual
`ViewRotation` and landscape phone orientation together (both independently verified, but not in
combination) - low risk since neither code path changed, but worth a mention for the user's own
on-device pass mounting the phone landscape with the camera physically sideways.

**iOS backlog (Phase I, I1-I6) is now complete.** Remaining pending items are all either
user-only on-device tests (I1's provisioning check, I4's clip-boundary diagnosis, the
camera-auto-power-off test) or the macOS parity phase (M1-M6) below, which starts next per the
plan's explicit ordering.

## 2026-07-12 — Landscape layout rework (user's on-device feedback with screenshots)

First real on-device use of I6's landscape layout surfaced the core problem: the edge control
clusters were OVERLAYS on a full-frame canvas, so they sat on top of the live image even though
the letterboxed 4:3 image leaves plenty of free black space at the sides. Reworked per the
user's explicit spec (portrait untouched):

- **Columns are now real layout siblings, not overlays** - `landscapeBody` is a VStack(top row)
  + HStack(left column / `liveViewStack` / right column). The canvas gets exactly the middle
  region; the image letterboxes inside it and the controls live in what used to be dead space.
  The `edgeScrim()` helper (translucent pill behind overlay buttons) became unnecessary and was
  removed.
- **Top row** (the only thing above the live view): status chip/connection menu, DEBUG fps chip
  right of it, then an **icons-only mode toggle** at the trailing edge - `ModeToggle` gained an
  `iconsOnly: Bool = false` parameter (`.labelStyle(.iconOnly)`, tighter padding), portrait
  continues to use the full labeled variant.
- **Left column, six identical buttons** (uniform 28pt-content `PillButtonStyle` pills via a new
  `landscapeIconButton` helper + a matching hand-drawn `landscapeDiagonalsButton`): info,
  peaking, rotate on top, then the crop/thirds/diagonals guide toggles. In portrait these were
  two differently-sized clusters (32pt top-bar icons vs the 40pt `GuideToggles`); landscape now
  presents them as one visually consistent column. Guide toggles stay disabled while
  disconnected, same as portrait.
- **Right column**: shutter on top (same position as before), settings button below it, Files
  below that - the previous order (Files above settings) flipped per the spec.
- Timer/weak-link/battery chips still float top-center, now via an `.overlay(alignment: .top)`
  on the canvas itself.

Verified in the iPhone 17 Simulator (temporary Mock swap, reverted after): all three columns
sit clear of the image area, six left buttons render uniformly and light up amber when active,
the icons-only mode toggle switches modes (shutter turns red in video), right column order is
shutter/settings/Files. Portrait rebuilt and unchanged. Full app build green after the revert.

Second feedback round (same day): right column recentered - settings button sits at the exact
vertical center of the column, shutter above and file manager below at equal distances (fixed
VStack spacing inside a maxHeight-centered frame gives both properties by construction). The
landscape Files button lost its "Files" caption (new label-less `landscapeFilesButton` - every
other landscape icon is caption-free; portrait keeps its captioned version) and both right-column
icons were normalized to 20pt medium; the left-column pill icons gained `.medium` weight to
match. Re-verified in the Simulator: portrait untouched, landscape centered as specified.

## 2026-07-12 — Stale-frame-on-disconnect regression fixed (user-reported on-device)

User report: after disconnecting, the last live-view frame stays frozen on screen instead of
the "Not connected" placeholder. This is a REGRESSION of the original bug #7 fix (which cleared
the image when `frameData` went nil), reintroduced by the 2026-07-11 off-MainActor decode
change: `LiveViewCanvas.onChange` still correctly calls `LiveFrameDecoder.clear()` on nil, but
`clear()` had a race with the background decode queue - at ~25fps there is almost always a
frame MID-DECODE at the moment of disconnect, and that flight's completion handler landed on
the MainActor right after `clear()` and re-assigned `image`, resurrecting the stale frame.

Fix in `LiveFrameDecoder`: a `generation` counter, bumped by `clear()`; a decode completion
whose captured generation no longer matches is discarded. Exactly the pattern
`FocusPeakingProcessor` already used for the same toggle-off race (checked it too - it was
already fully correct, including resetting its in-flight flag). Also fixed the secondary defect
the guard exposed: `clear()` now resets `isDecoding`, otherwise a discarded stale completion
would leave it stuck `true` and the NEXT connection's frames would pile into `pendingData`
forever behind a flight that already landed (a frozen live view on reconnect).

Verified: full app build green. The race itself can't be triggered deterministically without a
live ~25fps feed, so the actual disconnect behavior needs the user's on-device re-test - but
the mechanism is identical to the already-field-proven FocusPeakingProcessor pattern.

## 2026-07-12 — Crop-outside dimming (user request, both platforms)

With the Crop toggle on, everything OUTSIDE the effective capture area is now dimmed (the
preview is wider than what actually gets recorded - the to-be-cropped margins render darker
while the real frame keeps full brightness, so the eye separates them instantly instead of
parsing a dashed line). iOS: even-odd fill of (full frame + crop rect) in
`LiveViewCanvas.guideOverlay`, black at 0.45 opacity, only in the pre-record branch (during
recording the feed itself already shows the real crop - nothing to dim) and only when the crop
toggle is on. macOS parity in the same change: `QPainterPath.subtracted` fill in
`LiveViewWidget.paintEvent`, alpha 115, skipped when the crop rect equals the full frame (e.g.
photo 4:3). Tied to the existing Crop toggle on both platforms - no new UI.

## 2026-07-12 — Lock-the-phone-during-recording scenario (user question, answered + plan)

The user's intended workflow for long continuous recordings: start recording, LOCK the phone
to save battery, unlock every ~10 minutes to check the picture (e.g. sunset light changing).
Analysis of what happens today:
- Locking suspends the app within seconds - status polling, live view, the recording timer AND
  the auto-restart monitor all freeze. **Auto-restart cannot fire while locked**, and there is
  no legitimate iOS background mode that fits this app. The camera itself keeps recording
  autonomously until its own ~30-min limit, then stops.
- On unlock, if Wi-Fi survived the lock: the app resumes as Connected, live view resumes, but
  the recording state is DESYNCED once the camera self-stopped (app says recording, camera
  isn't). A normal shutter tap sends Stop, the camera errors it, `isCameraSuccess` correctly
  refuses to flip the flag - so the tap LOOKS dead. The long-press force-stop is the current
  escape hatch; then start recording again.
- If Wi-Fi dropped during the lock: camera-vanished detection fires ~15s after unlock; rejoin
  the camera network (Auto-Join is off per FIELD USAGE RULE #1, so manually) and Connect direct.
- Which live view shows after unlock is the CAMERA's choice, not the app's - one stream, its
  content switches with the camera's own state (fact §12): still recording → the recording
  feed (real crop/exposure); already self-stopped → the default preview (visibly wider).

Planned follow-ups, gated on today's user tests: (1) a foreground-return resync - on scenePhase
.active, verify the camera's actual recording state and fix `isRecording` (needs the
detectable signal from the clip-boundary diagnosis); (2) possibly an in-app screen-dim button
(black overlay at minimum brightness) as the battery-saving alternative that keeps the app
alive so auto-restart still works. User tests that will inform this: (a) what the app observes
when the camera hits its own recording limit; (b) whether Wi-Fi + the UDP stream survive a
~5-minute lock and resume on unlock.

**First lock test result (2026-07-12, ~1 min lock): INCONCLUSIVE for the real scenario** - the
run was under the Xcode debugger, and iOS does not suspend a debugged app on screen lock (the
logs literally say "App is being debugged"). So "packets kept flowing while locked" only proves
the debugger case; the untethered test (launch from the home screen icon, no Xcode) still needs
doing. Also observed: one single "onChange multiple times per frame" warning over the whole
session (rare enough to just monitor), and a burst of GetCameraStatus -1001 timeouts at session
start before the stream came up (never 3 in a row once connected - the vanished-detector
correctly didn't fire).

**NEW CAMERA FACT (user-identified from the same logs, correcting the first read of them):
while RECORDING, the camera itself throttles the live-view stream to ~7.5fps** (in=7.4-7.8,
rock-steady, for the whole recording stretch; back to 30 the moment recording stops) -
deliberately, to save resources for the encoder. The initial interpretation (screen-off radio
power-save) was wrong: the drop correlates with record start/stop, not lock/unlock. Two
consequences: (1) this quantifies the previously-known "recording live view is low-fps"
observation - ~7.5fps is the by-design ceiling while recording, no app-side fix applies;
(2) it exposed a REAL BUG in the I3 weak-link indicator: at 7.5fps every inter-frame gap
(~133ms) exceeds the 50ms threshold, so the gap counter races upward (~37 per 5s window,
exactly matching the logged ~+40) during ANY recording - the chip would false-positive for
entire recordings. **Fixed**: `sampleLiveViewStats` now forces `liveViewLinkUnstable = false`
while `isRecording` - the signal is meaningless at the recording throttle rate. 38 tests green,
app build green. (macOS has no weak-link indicator, so no parity change needed - but its
`[liveview]` debug log will show the same ~7.5fps/high-gaps pattern during recording; noted so
nobody misreads it as radio trouble there either.)

## 2026-07-12 — Untethered lock test results: TWO open questions answered (user field test)

The real (no-debugger, launched-from-icon) lock test: started recording, locked the phone; on
unlock the app had been terminated by iOS (user landed in the app switcher), the connection was
gone, and a fresh launch + rejoin camera Wi-Fi + Connect direct worked - the RECORDING live
view appeared (camera had kept recording autonomously the whole time). A while later the
recording stopped and live view switched back to the fast/normal feed; the camera held a
**7.5-minute file**.

Conclusions:
1. **Confirmed: locking the phone kills the session in real use** (app terminated, not just
   suspended) - the workflow answer is the screen-dim button, not locking. A relaunched app
   starts from scratch (round shutter button) with no idea the camera is mid-recording - that
   reverse desync (camera recording, app thinks not) is a separate known gap; see the fps-hint
   idea below.
2. **The recording stop was almost certainly the CAMERA's own limit, not the app** - a fresh
   session has no code path that sends VideoRecordingStop unprompted (verified: disconnect only
   sends it when its own flag is true; force-stop is long-press-only). The 7.5-minute file
   matches the researched 4K/4GB-FAT32 ceiling exactly (format still to be confirmed by the
   user, but the number is squarely in the "~7.5-8.5 min" research range).
3. **Assuming 4K: the clip-boundary question is ANSWERED - NO seamless in-camera split.** The
   camera hard-stops (live view reverted to fast, single file). Auto-restart per ~7-minute
   cycle is genuinely required for continuous 4K.
4. **The 4K auto-restart timer was too late**: 8:00 vs the camera's actual stop at ~7:30.
   Lowered to 7:00 on BOTH platforms (`RecordingAutoRestart.fourKRestartInterval`,
   `RECORDING_AUTO_RESTART_4K_INTERVAL`); iOS tests updated.
5. **The live-view fps signature IS the long-sought detection signal** (the I4 TODO hook):
   ~7.5fps while recording → jump to ~30 = the camera stopped on its own. Implemented on both
   platforms as a self-calibrating detector on the 5s stats cadence: it ARMS only after 2
   consecutive slow (<12fps) samples while recording (proof this format throttles - so a
   hypothetical non-throttling format can never false-trigger), then FIRES after 2 consecutive
   fast (>20fps) samples: resyncs `isRecording` to false (fixing the stuck-"recording" UI whose
   shutter tap looked dead), and when auto-restart is on, immediately starts the next clip (no
   stop needed - the camera already stopped). Detection latency ~10-15s worst case, vs the
   timer alone which can only fire proactively. The timer remains as the proactive layer
   (restart BEFORE the camera's stop, no gap beyond the restart itself); the detector is the
   reactive safety net (catches drift, unknown limits, anything missed). macOS's `[liveview]`
   log line now also prints `in=X.X fps` to make the signature visible there. iOS: 38 tests
   green + app build green; macOS: py_compile + a dedicated smoke test of the detector's
   arm/fire/no-false-trigger/auto-restart-off paths, all green.

Still open for a future session: the "reverse resync" (fresh app connect while the camera is
already recording - the same fps signature could ARM outside of recording and show a hint or
adopt the recording; not built yet, needs a careful think about radio-degraded false positives).

## 2026-07-12 — AUTO-RESTART CONFIRMED WORKING ON-DEVICE + three follow-ups from the field run

User ran a real continuous 4K session with the toggle on: **clip 2 and clip 3 seen on the
timer chip, ~7-minute fragments at ~3800MB each** - the timer-based restart works end-to-end.
The measured numbers also nail the camera's ceiling precisely: its own stop is at 7:29/~4096MB,
so our 7:00 restart yields ~3800MB files (the math checks out exactly). Per-format answer for
the user's question: the camera's limit is a SIZE limit (4GB), so duration depends on bitrate -
4K hits it at ~7:29; FHD's much lower bitrate would take 30+ minutes, but the general ~30-min
recording cap fires first. Hence exactly two app-side timer tiers: 4K → 7:00, everything else →
29:30. (Offered the user a 7:15 bump for 4K - ~3.5% fewer restarts, still ~14s margin, the fps
detector as backstop - pending their call.)

Three fixes/features out of the same field run (all same day, both platforms where relevant):
1. **Weak-link chip flashed right after recording stopped** (field screenshot): the first
   post-stop 5s sample's gap delta still covers a stretch of the throttled-rate period. Added a
   one-sample grace (`lastSampleWasRecording`) - the chip is suppressed for the sample after
   recording ends too. iOS only (macOS has no weak-link indicator).
2. **Recording letterbox crop** (user request): during 16:9 recording the camera bakes black
   bars INTO the stream (4:3 frame, 16:9 content centered) - so the guides during recording
   spanned 4:3-with-bars, not the real capture area, and screen space was wasted. Both
   platforms now crop the centered 16:9 content region off the frame at display time during
   FHD/4K recording (2K deliberately excluded - its stream's letterboxing is unverified; its
   measured crop is the full sensor frame). iOS: cheap `CGImage.cropping` per displayed frame
   in `LiveViewCanvas` (peaking overlay cropped identically; tap-to-focus maps against the
   cropped image). macOS: `QImage.copy` in `LiveViewWidget.paintEvent` + focus mapping against
   the displayed image (`_last_display_image`).
3. Verified: macOS py_compile green, iOS 38 tests + full app build green. The letterbox crop
   needs the user's next recording session for visual confirmation (bars gone, guides correct,
   image larger).

## 2026-07-12 — Auto-restart margins tuned per user (three format tiers now)

User's call after the successful field run: tighter margins, less lost tail per clip. Both
platforms updated (`RecordingAutoRestart` / `RECORDING_AUTO_RESTART_*`):
- **4K → 7:23** (6s under the field-measured 7:29 stop)
- **FHD → 29:55** (5s under the ~30-min general cap)
- **2K → 29:50** (new dedicated tier; user asked for a 10s margin under its limit - research
  check found NO 2K-specific measurement, only the general caps; 2K is 2048x1536 4:3
  full-sensor downscale, bitrate never measured. CAVEAT recorded in the code comments: if the
  2K bitrate exceeds ~18 Mbit/s, the 4GB file ceiling arrives before 30 minutes and the timer
  would miss - the fps-signature detector covers that case, and one deliberate 2K recording
  left to run to the camera's own stop would pin the real number.)
With margins this tight, the fps detector's role as safety net matters more: if the camera's
own stop ever beats a timer (clock drift, an off-spec limit), the detector still restarts
within ~10-15s. iOS tests updated for the new tiers (38 green), full app build green, macOS
py_compile green.

## 2026-07-19 — Settings UX rework: inline quick picker (user-approved design)

User feedback: the old flow (chip → sheet → list row → value picker) took up to 4 taps, and the
auto-restart toggle was buried in the sheet. Declined from the backlog at the same time: the
screen-dim button (user will just lower brightness manually) and the reverse-resync (user
accepts keeping the app open during recording sessions). Also fixed the letterbox-crop
engagement jump (image snapped toward the edge before settling) with a 0.25s eased geometry
transition in `LiveViewCanvas`.

New `SettingsStrip` (full rewrite; old `SettingsSheet`/`ValuePickerView` deleted):
- **Tap a chip → an inline horizontal value row expands above the strip** (`ValueQuickPicker`):
  title at left, scrollable value pills, current value highlighted amber and auto-centered via
  `ScrollViewReader` on appear. Tap a value → applies through the same optimistic `setSetting`
  path as before and collapses. Tap the same chip again → just collapses. **2 taps total.**
  Expanded chip gets an amber border. Mode switches collapse any open picker (its key may not
  exist in the other mode's key set).
- **Auto-restart is now a first-class strip chip** (video mode, next to the read-only
  Format/Audio/EIS chips): one tap toggles, amber "On" state readable at a glance from the main
  screen.
- **Landscape**: the settings button no longer opens a sheet - it toggles the same
  `SettingsStrip` as an overlay floated over the live view's bottom edge (black scrim,
  rounded), stacked under the recording timer chip. Button turns amber while open. Flow there:
  button → chip → value = 3 taps, without ever leaving the live view.

Verified in the iPhone 17 Simulator (Mock swap, reverted after), both orientations: landscape -
strip toggles from the settings button, ISO chip expands the pill row, choosing "800" applies
and collapses (chip shows ISO 800), auto-restart chip toggles to amber On next to the lock
chips; portrait - strip expands the same way with the current value auto-centered. Full app
build green after the revert.

## 2026-07-20 — Final audit (user-requested "на всякий случай"), 4 findings, all fixed

Fresh-eyes pass over both codebases, focused on the newest and most intricate paths
(auto-restart + fps detector, live-view pipeline, file browser, parity ports). Findings:

1. **[BOTH, race] fps self-stop detector could false-fire right after an auto-restart.** The
   5s stats window spanning the inter-clip gap reads the camera's full-rate stream as a "fast"
   sample, and the detector's armed flag survived the restart - two such windows in a row
   would flip `isRecording` false and send a doomed extra Start (camera errors it → stuck
   not-recording UI). Fixed: `resetSelfStopDetector()` / `_reset_self_stop_detector()` now
   runs on EVERY recording (re)start (manual start, timer restart, detector's own restart),
   not just on stop. Proven by a macOS smoke reproducing the exact scenario: armed → restart →
   fast gap samples don't fire; genuine re-arm + fast still fires.
2. **[macOS, perf] File-browser thumbnail batch starved the live-view loop and user commands.**
   N thumbnails were queued into the MAIN serial request queue, drained back-to-back on the
   same thread that does UDP recvfrom - freezing live view for the whole batch, and a user
   command (record toggle!) issued after opening the browser sat behind all of them. Fixed:
   thumbnails moved to their own low-priority side queue (`_thumb_requests`), serviced at most
   one per loop pass and only when the main queue is empty; `cancel_pending_thumbnails()`
   drops leftovers when the browser closes; plus a per-dialog thumbnail cache so Refresh after
   a delete doesn't re-fetch everything.
3. **[macOS, minor] Batch download completion said "Saved to <last file>"** - now reports
   "Downloaded N files to <dir>" (failures still listed individually).
4. **[iOS, hygiene] `lastSampleWasRecording` wasn't reset on a new connection** - one
   needlessly suppressed weak-link sample after reconnect. Reset added to `startLiveView`
   alongside the detector state.

Checked and found CLEAN: decoder/peaking generation guards; all teardown paths reset
recording/clip/timer state; one-HTTP-request-at-a-time discipline (incl. the new fetches);
letterbox-crop pipeline consistency (frame + peaking overlay + tap mapping, both platforms,
incl. rotation order); rotation inverse mappings; no dangling references from the I1 revert or
the SettingsSheet removal; no leftover Mock wiring or debug scaffolding. Known accepted
edges (documented, not bugs): a stop tap landing inside a restart's cooldown is swallowed (tap
again); if the detector fires while another record command is mid-flight it only resyncs the
flag without auto-starting the next clip (needs impossible timing in practice); macOS peaking
runs on the GUI thread by design (~2ms/frame, bounded).

Verified after the fixes: iOS 38 tests + full app build green; macOS py_compile + dedicated
smokes for the detector reset and the thumb side-queue green.

## 2026-07-19 — Quick-picker auto-scroll actually working (user-reported)

User report: opening a setting's value row showed the START of the list, not the current value
(e.g. WB at 5000K opening at the list head - one-step adjustments like 5000K -> 4800K meant
scrolling the whole way every time). The auto-scroll code existed but had two real defects:
1. **Chip-to-chip switching reused the view**: tapping another chip while a row was open swaps
   `expandedKey` directly (no collapse in between), SwiftUI reuses the `ValueQuickPicker` view,
   `onAppear` never re-fires, and the old scroll position sticks. Fixed with `.id(key)` -
   fresh view identity per setting.
2. **`scrollTo` raced layout**: called synchronously from `onAppear`, on long option lists it
   ran before the row laid out and landed at the start. Fixed by deferring one runloop
   (`DispatchQueue.main.async`).
Verified in the Simulator including the hard case: picked ISO 1600, opened Shutter, switched
DIRECTLY to the ISO chip - the row opened centered on the highlighted 1600. (Mock caveat noted
while testing: MockCameraSession's initial settingValues use display-style strings that don't
match the real enum rawValues used as pill ids, so INITIAL mock values neither highlight nor
scroll - real-camera values come from metadata/optimistic sets and match; not a product bug.)

## 2026-07-19 — Guide/crop semantics revised per user field feedback (both platforms)

User-reported: with crop+thirds+diagonals on, turning Crop OFF left thirds/diagonals still
following the crop zone. That was the DELIBERATE 2026-07-09 behavior (guides always follow the
effective capture area) - the user now wants the opposite in photo mode, plus a rethink of the
video-mode toggle. Facts verified against the research before changing: FHD/4K always record
16:9 and the format can't be changed remotely (the crop is a fact, not a choice); 2K is the
exception - it records the FULL 4:3 sensor (2048x1536, measured), no crop exists; in photo
mode the crop follows the chosen aspect (4:3 = full frame, others = real crops), i.e. it IS a
choice there.

New semantics, both platforms:
- **Video mode: crop overlay always on, toggle locked** (shown active but not tappable - iOS:
  `GuideToggles.cropAlwaysOn` + the landscape crop button disabled+active in video; macOS:
  `crop_btn` disabled + styled active in `_set_mode`, restored to the user's own state in
  photo). Guides follow the crop as before. 2K draws nothing extra (its rect equals the full
  frame - outline/dim are skipped when the rect IS the frame in VIDEO mode). Follow-up
  correction (same day, user feedback): in PHOTO mode the outline DOES draw even at full frame
  (4:3) - the toggle is tappable there, and a tap with zero visible change reads as broken;
  the skip-at-full-frame rule only applies to video, where there's no tappable toggle.
- **Photo mode: the toggle now governs the guides too** - crop on -> thirds/diagonals inside
  the capture area (+ dim outside); crop off -> guides span the whole visible frame (the
  user's requested "stretch to the full screen" behavior, replacing the 2026-07-09 rule).
- During recording: unchanged (guides span the full visible frame - the feed already shows the
  real crop, now bar-cropped too).

Verified: iOS full app build green; macOS py_compile + a smoke check of the toggle
enable/lock state across mode/connection transitions and the crop-shown flag math. Needs the
user's next live session for a visual pass.

## 2026-07-12 — Recording timer moved to the bottom (user feedback during field test)

The RecordingTimerChip floated top-center over the live view, where it collided with the busy
top elements during recording (in landscape: the status/fps/mode-toggle row). Moved to
BOTTOM-center over the canvas in both orientations (landscape: an `.overlay(alignment: .bottom)`
on the canvas; portrait: bottom of the same ZStack that previously pinned it top). Weak-link and
battery chips stay top-center. Build green; needs a quick visual confirm during the next
recording session.
