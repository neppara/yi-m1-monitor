# Tasks V2: Finish the iOS app, then bring macOS to parity

Self-contained work orders for an executing model (Sonnet). Written 2026-07-11 by the
orchestrating session, after the live-view radio investigation concluded. Read this WHOLE file
before writing code. Authoritative background: `yi-m1-ios/DEVELOPMENT_PLAN.md` (especially the
dated 2026-07-08..11 sections at the end) and `yi-m1-remote-control/app/ARCHITECTURE.md`.

**Scope decisions (user, 2026-07-11):** everything below IS in scope; punch-in zoom and exposure
scopes (histogram/zebras) are explicitly OUT of scope for this pass. Execution order is strict:
**complete the entire iOS phase (I1-I6) first, then the macOS phase (M1-M6)** - macOS is a
catch-up port of everything learned/built on iOS, adapted to its architecture, not a
simultaneous track.

---

## 0. Ground rules

### 0.1 iOS (yi-m1-ios/) - all rules from the previous task file still apply

- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` prefix on every xcode-dependent
  command (never `xcode-select -s`).
- YiM1Core: `swift build` / `swift test` (35 tests green, keep them green) + iOS cross-compile
  check via `--sdk $(xcrun --sdk iphonesimulator --show-sdk-path) -Xswiftc -target -Xswiftc
  arm64-apple-ios16.0-simulator`.
- App target has no headless build here: verify SwiftUI via the temporary
  `YiM1Monitor/Package.swift` shim (see the template in
  `yi-m1-ios/TASKS_FOCUS_PEAKING_AND_FILE_BROWSER.md` §0 - excludes App.swift, Info.plist,
  entitlements, Assets.xcassets, AppIcon.svg, itself), and DELETE the shim + `.build`/`.swiftpm`
  after every use.
- **Run `xcodegen generate` after EVERY new file added to `YiM1Monitor/`** (not just at the
  end - a file created after the last generate silently doesn't exist in the Xcode project;
  the symptom is "Cannot find 'X' in scope" plus a bogus cascading error nearby).
- Protocol invariants: ONE HTTP request at a time (HTTPClient serializes - never bypass);
  camera errors are HTTP 200 + `{"code":<err>}` body (`Response.isCameraSuccess`, never raw
  status); `resulotion` misspelling is correct; wire values match
  `yi-m1-remote-control/prot_http/` exactly; iOS 16 APIs only (one-parameter `onChange`);
  `CameraSessionProtocol` is `@MainActor` and `MockCameraSession` must implement every addition.
- Record commands: respect the existing 1.5s cooldown / `recordingCommandInFlight` machinery in
  `CameraSession` - rapid start/stop cycling physically wedges the camera (proven on-device).
- After each task: dated implementation note appended to `yi-m1-ios/DEVELOPMENT_PLAN.md`; no
  leftover shim files.

### 0.2 macOS (yi-m1-remote-control/app/) - different world, different rules

- Python 3 + PySide6. No xcodegen, no SPM. Verify with `python3 -m py_compile app/*.py` plus a
  construction/state-transition smoke test in the style already used (see ARCHITECTURE.md's bug
  history - previous sessions scripted QApplication + MainWindow construction and simulated
  signal firing without a camera).
- Architecture: `camera_session.py` is a single QThread owning ALL I/O (BLE via bleak, HTTP via
  urllib3, UDP live view) sequentially - requests come in through a queue, results leave as Qt
  signals. `main_window.py` is the UI. KEEP this single-thread model - it's load-bearing (it's
  why macOS never hit the concurrent-HTTP 1515 bug).
- Design system lives in `app/theme.py` (same tokens as iOS `Theme.swift`) and `app/icons.py`.
- The authoritative doc to update after each macOS task: `app/ARCHITECTURE.md` (same style as
  its existing bug-by-bug history).
- The user runs macOS live tests the same way as iOS ones - mark anything needing the real
  camera as "user-verifies" in your notes.

---

## PHASE I - iOS completion

### I1. NEHotspotConfiguration spike + native Wi-Fi join (highest UX value, do first)

Background: the plan assumed the Hotspot Configuration entitlement needs a paid account and
built the manual-join sheet instead. The user then spotted DJI Mimo (a normal App Store app)
showing the native "wants to join Wi-Fi network" alert - that IS
`NEHotspotConfiguration.apply`. Research found the paid-account assumption may conflate this
API with the older, genuinely-restricted `NEHotspotHelper`. Test it for real:

1. Add the entitlement: `com.apple.developer.networking.HotspotConfiguration` = true in
   `YiM1Monitor/App/YiM1Monitor.entitlements` (currently an empty dict), and declare the
   capability in `project.yml` if xcodegen supports it (it passes entitlements through via the
   `entitlements:` key already there). Regenerate.
2. Implement a `WiFiJoining`-style seam (the plan's Part 4.2 always intended this):
   - New `HotspotJoiner` in YiM1Core (or app target if NetworkExtension import is cleaner
     there - NetworkExtension IS available to YiM1Core's iOS builds, but keep the macOS build
     of YiM1Core compiling: wrap in `#if canImport(NetworkExtension) && os(iOS)`).
   - `func join(ssid: String, password: String) async throws` using
     `NEHotspotConfiguration(ssid:passphrase:isWEP:false)`, `joinOnce = false` (persist for the
     session; the password rotates on camera power-cycle anyway), applied via
     `NEHotspotConfigurationManager.shared.apply`.
3. Wire into `CameraSession.connectViaBLE`'s flow: after BLE returns credentials, TRY the
   hotspot join first; on success skip straight to the reachability poll + RCStartRemoteCtl
   (no sheet). On ANY failure (error thrown, user tapped Cancel on the system alert, entitlement
   missing at runtime) **fall back to the existing manual-join sheet flow unchanged** - the
   sheet code stays as the fallback, do not delete it.
4. **The provisioning gate is user-verified:** whether the free personal team signs an app with
   this entitlement can only be proven in the user's Xcode. Structure the code so a signing
   failure is trivially reversible: ONE commit/change-block for the entitlement file + one for
   the code (which already runtime-falls-back). Tell the user exactly what to check: build to
   device; if signing fails with an entitlement/provisioning error, remove the entitlement line
   and the manual sheet continues as before.

Acceptance: YiM1Core still builds for macOS + iOS; all tests green; with the entitlement
present the BLE flow attempts the system dialog and falls back cleanly; plan note written
including the user-verification instructions.

### I2. Top bar rework (user feedback: status text truncates)

Current top bar: `Text("YI M1 Monitor")` + statusChip + peakingButton + rotateButton +
ConnectionMenu. Problems: the connected status ("Connected · 75% · 412 shots") truncates; the
title is the least useful element.

- Remove the title. The status chip moves to the leading position and gets the freed width
  (`lineLimit(1)` can stay - it should now fit; verify with the longest realistic string).
- Make the status chip itself the connection menu: wrap it in the `Menu` that currently lives
  in `ConnectionMenu` (Connect BLE / Connect direct / Disconnect / Reset, same enable/disable
  logic). The separate ellipsis button disappears; `ConnectionMenu.swift` becomes the chip-menu
  (rename or repurpose - keep the generic-over-Session pattern).
- Keep peaking + rotate buttons as-is on the trailing side.
- Verify in the Simulator with MockCameraSession (connect → status text fully visible; menu
  opens from the chip; disabled states correct mid-connection).

### I3. Weak-link indicator (from the radio investigation)

The receiver already counts inter-packet gaps (`LiveViewStats.recvGapsOver50msCount`,
`maxRecvGapMs`). During a radio-away episode (iOS background Wi-Fi scans - unsuppressable, see
DEVELOPMENT_PLAN's forensics rounds 5-6) these spike measurably: ~25-30 gap events per 5s vs
~0-2 normally.

- `CameraSession`: track the gaps>50ms delta between 5s samples (the sampling plumbing exists
  in `sampleLiveViewStats()`); publish `@Published var liveViewLinkUnstable: Bool` - true when
  the last sample's delta exceeds ~10, with hysteresis so it doesn't flicker (e.g. require one
  clean sample to clear). Add to `CameraSessionProtocol` + Mock (always false).
- UI (`RootView`): when true, a small amber chip over the live view (near the recording timer's
  position but not colliding with it): SF `wifi.exclamationmark` + "Weak link" - informational
  only, so the shooter knows stutter = radio, not a hang. NOT `#if DEBUG` - this one is
  user-facing (unlike the fps chip, which stays DEBUG-only).

### I4. Recording auto-restart (near-continuous recording)

Confirmed facts (researched + YI's own help pages): a 30-minute recording cap exists; 4K clips
come out fixed at ~8.5 min (4GB FAT32 ceiling). OPEN question the user will answer on-device
(filming a stopwatch across the boundary): does 4K auto-split into a new file and keep
recording (then only the 30-min cap matters), or does recording fully stop at ~8:30?
True bypass is impossible (firmware repack unsafe - own research; HDMI is playback-only;
FAT32 required), so app-side restart is the ceiling. Build it to handle EITHER answer:

- `CameraSession`: new `@Published var autoRestartRecording: Bool` (a user toggle, default
  OFF) + the machinery: while recording with the toggle on, run a monitor task that
  (a) tracks elapsed time from `isRecording` flipping true, and (b) watches for the camera
  stopping on its own. Detection options in preference order - implement all cheaply:
  1. If the user's diagnosis finds a detectable signal (metadata field change, GetCameraStatus
     change, live-view behavior) - a TODO hook point, clearly marked, to wire once known.
  2. Timer-based proactive restart: configurable per-format limits (constants: FHD 29:30,
     4K 8:00 as safe margins under the 30:00/8:30 caps), restart = `VideoRecordingStop` →
     cooldown → `VideoRecordingStart` through the EXISTING toggleRecording-grade machinery
     (never bypass `recordingCommandInFlight`/cooldown - rapid cycling wedges the camera).
  3. On restart: increment a `@Published var recordingClipNumber: Int`.
- UI: the auto-restart toggle lives in the settings sheet or as a long-press option on... no -
  simplest discoverable spot: a small toggle row appended to the SettingsSheet (SettingsStrip's
  sheet) labeled "Auto-restart recording (beta)". The RecordingTimerChip shows "clip N · mm:ss"
  when N > 1.
- If the user's stopwatch test later proves 4K auto-splits seamlessly, the 4K timer constant
  just gets bumped to the 30-min value - note this in the code comment.
- Protocol + Mock additions as usual. Unit-test the timer math if extractable (e.g. a pure
  helper deciding "restart due at t" given format + elapsed).

### I5. Phase-4 polish batch (error paths + guidance + small stuff)

One coherent pass over the rough edges, per the original plan's Phase 4 and everything learned:

- **Permission-denied paths:** Bluetooth off/denied during BLE connect (CBCentralManager state
  unauthorized/poweredOff → clear error message with what to do, not a generic failure);
  Local Network permission denied (all HTTP times out - after connection-lost/unreachable
  errors, the message should mention checking Settings → Privacy → Local Network if it's the
  first-ever session).
- **Pre-session checklist hint:** first-connect (or a small `(i)` info button in the top bar) →
  a sheet listing the field rules discovered this week: "For a stable feed: Bluetooth OFF
  (Settings, not Control Center) · expect brief self-recovering stutters every few minutes
  (iOS background scans) · camera screen locks during the session · one client at a time ·
  video format must be set on the camera before connecting". Content lives in one static view;
  keep it short and dismissible, shown from the connection menu or an info icon.
- **Quirks copy check:** video-mode read-only chips (Format/Audio/EIS) - ensure they read as
  intentionally read-only (e.g. a small lock glyph), not broken.
- **"Camera powered off" specificity:** when connection-lost fires, if the last GetCameraStatus
  succeeded > N minutes ago vs seconds ago, we can't distinguish power-off from range - keep the
  existing message but append "(camera off or out of range)".
- **Launch screen:** give `UILaunchScreen` in project.yml the app's dark background color
  (`UIColorName` requires an asset - add a named color "LaunchBackground" #0c0d0f to
  Assets.xcassets) so cold launch doesn't flash blank/white. Deprioritized earlier but it's
  3 lines while you're in there.
- **Camera auto-power-off test support:** nothing to build - just note in the plan that the
  user still owes this test (connect, idle past the camera's auto-off, observe).

### I6. Landscape / on-camera-monitor layout (the user's true target form factor)

The reason this app exists: the phone mounted on/near the camera as a field monitor, usually
LANDSCAPE. Currently portrait-only (`UISupportedInterfaceOrientations` in project.yml).

- Allow landscape (add LandscapeLeft/LandscapeRight to project.yml; keep portrait).
- **Do NOT let the portrait stack rotate as-is.** Build a landscape-specific arrangement in
  `RootView` (branch on size class / `GeometryReader` aspect): live view fills the whole frame
  edge-to-edge; controls overlay it like a real field monitor:
  - Trailing edge vertical strip: shutter/record (center), Files below, mode toggle above -
    compact, over a translucent scrim.
  - Leading edge or top corners: status chip (compact form: dot + battery + fps if DEBUG),
    peaking/rotate/guide toggles as a slim vertical cluster.
  - Settings strip: hidden by default in landscape; a small chevron/button summons the existing
    SettingsSheet (already a sheet - reuse).
  - Recording timer + weak-link chips float top-center as today.
- Overlays (crop/thirds/diagonals/peaking) and tap-to-focus already live inside LiveViewCanvas
  and are layout-agnostic - they need no changes, just a bigger canvas.
- The manual `ViewRotation` button stays relevant (camera mounted sideways while phone is
  landscape = still may need rotation) - verify the combination visually in the Simulator with
  the Mock.
- Keep portrait exactly as it is today. Test both orientations + rotation transitions in the
  Simulator; guard against the WiFi join sheet / file browser breaking in landscape (sheets
  handle themselves, just check).

---

## PHASE M - macOS catch-up (start ONLY after I1-I6 are done)

Port everything learned on iOS into `yi-m1-remote-control/app/`, adapted to the Python/Qt
single-thread architecture. For each: update `app/ARCHITECTURE.md` with the same rigor as its
existing bug entries.

### M1. Body-code checking (the latent recording-desync bomb)

`camera_session.py` treats HTTP status 200 as success everywhere. The camera signals failures
as HTTP 200 + `{"code":<err>}` (proven on iOS: 1515 "rc only one", 1502 filelist, and the
recording desync). Add an `is_camera_success(status, body)` helper (parse body JSON, require
code==200 when present - mirror `HTTPClient.Response.isCameraSuccess` semantics exactly,
including "non-JSON body counts as success") and use it in `_do_toggle_recording`,
`_do_connect`/`_do_connect_direct` (RCStartRemoteCtl), shoot flow (RCDoShooting), and delete
handling in the file browser's result path. Add the 1.5s record-command cooldown equivalent
(timestamp check in `_do_toggle_recording`) and a force-stop request kind (`"force_stop"`)
mirroring iOS's long-press escape hatch - wire to a long-press or menu action in
`main_window.py`.

### M2. Camera-vanished detection

macOS still stays "Connected" forever when the camera dies (its 5s GetCameraStatus poll in
`run()` ignores failures). Port the iOS consecutive-failures logic: 3 consecutive poll failures
→ emit `errorOccurred` + `disconnected`, tear down like `_do_disconnect` minus the stop command
(nothing reachable), stop the loop. Mind the single-thread structure: the poll lives inline in
the UDP loop - count there.

### M3. Guide semantics parity

Port the iOS guide behavior to `LiveViewWidget`: thirds/diagonals ALWAYS follow the effective
capture area (measured video/photo crop for the current format/aspect) independent of the
crop-outline toggle, and stay visible during recording (spanning the full frame - the feed
already shows the real crop then); the Crop toggle only controls the dashed outline + label.
This is a paint-logic change in `paintEvent`/`_draw_crop` mirroring LiveViewCanvas's
`guideOverlay`/`cropCGRect`/`drawCropOutline` split.

### M4. Live-view receiver hardening parity

The Python UDP loop has the ORIGINAL strict-order reassembly (any out-of-order packet kills the
frame). Port the iOS improvements, adapted:
- Reorder-tolerant, TWO-frame-window reassembly (dict/array of pending frames, complete when
  all indices present, evict per iOS rules - see `LiveViewReceiver.swift`'s v3 comments).
- `SO_RCVBUF` bump to 1MB + readback.
- Frame/drop counters + a periodic debug print (every ~5s) matching the iOS `[liveview]` line -
  invaluable if the Mac ever shows stutter.
- SKIP the keep-alive uplink and NET_SERVICE_TYPE on macOS unless the user reports Mac-side
  stutter: the Mac showed none of the iOS radio behavior (different power management), and
  unnecessary uplink is noise. Note the omission + reasoning in ARCHITECTURE.md.

### M5. Wi-Fi restore on disconnect (the oldest open macOS item)

`_previous_ssid` capture is broken because `get_current_wifi_ssid()` (networksetup/CoreWLAN)
requires Location Services and silently returns None. Implement the pragmatic fallback from the
roadmap: a manual "network to restore after disconnect" setting - a small text field or picker
in the UI (persisted via QSettings), used by `_do_disconnect` when set; keep the automatic
capture as a bonus when it happens to work. Try `wdutil info` / `system_profiler
SPAirPortDataType -json` parsing as a CoreWLAN-free auto-detect first (cheap to attempt,
verify it returns the SSID without special permissions on the user's macOS version) - if it
works, the manual field becomes the fallback rather than the primary.

### M6. Recording auto-restart parity

Once I4's design is settled (and the user's clip-boundary diagnosis is in), port the
auto-restart to macOS: same per-format timer constants, same cooldown discipline, a checkbox in
the UI, clip counter in the status bar. Reuse whatever detection signal I4's diagnosis found.

---

## Execution notes

- Strict order: I1 → I2 → I3 → I4 → I5 → I6, then M1 → M6. Items I2/I3 are small; batching
  their verification passes is fine. Do NOT parallelize iOS and macOS.
- User-gated points (flag in your notes, don't block on them): I1's provisioning check, I4's
  clip-boundary diagnosis (build timer-based first, hook detection later), M5's wdutil
  experiment needs the user's Mac terminal.
- Out of scope (do not build): punch-in zoom, exposure scopes/histogram/zebras.
- After the macOS phase: update the memory-relevant summary at the top of
  `yi-m1-ios/DEVELOPMENT_PLAN.md` and `app/ARCHITECTURE.md`'s "Как продолжить" section.
