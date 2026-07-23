# Tasks: Focus Peaking + File Browser Rework

Self-contained work orders for an executing model (Sonnet). Written 2026-07-11 by the
orchestrating session. Read this WHOLE file before writing code, then read the referenced
sources. The authoritative project context is `DEVELOPMENT_PLAN.md` (same directory) - skim its
"РЕАЛИЗОВАНО", "Full audit pass", and "Backlog" sections if anything here needs more background.

---

## 0. Project ground rules (violating any of these has bitten us before - all are load-bearing)

**Environment / build & test recipes:**
- Full Xcode lives at `/Applications/Xcode.app`, but `xcode-select` points at CLT. Prefix every
  xcode-dependent command with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`
  (scoped env var - do NOT run `xcode-select -s`, it needs sudo and changes global state).
- Core logic package: `YiM1Core/` (SPM, dual-platform iOS 16 / macOS 13).
  - Build: `cd YiM1Core && DEVELOPER_DIR=... swift build`
  - Tests: `cd YiM1Core && DEVELOPER_DIR=... swift test` — 32 tests, ALL must stay green.
  - iOS cross-compile check:
    `swift build --sdk $(DEVELOPER_DIR=... xcrun --sdk iphonesimulator --show-sdk-path) -Xswiftc -target -Xswiftc arm64-apple-ios16.0-simulator`
- App target: `YiM1Monitor/` (sources only; the real project is generated). There is no
  headless full-app build in this sandbox (no Simulator runtime for xcodebuild destinations).
  To compile-verify SwiftUI code against the REAL iOS SDK, temporarily create
  `YiM1Monitor/Package.swift` (verification-only shim), build, then DELETE it plus
  `Package.resolved`, `.build/`, `.swiftpm/`:
  ```swift
  // swift-tools-version: 5.9
  import PackageDescription
  let package = Package(
      name: "YiM1MonitorUICheck",
      platforms: [.iOS(.v16), .macOS(.v13)],
      products: [.library(name: "YiM1MonitorUICheck", targets: ["YiM1MonitorUICheck"])],
      dependencies: [.package(path: "../YiM1Core")],
      targets: [.target(
          name: "YiM1MonitorUICheck",
          dependencies: [.product(name: "YiM1Core", package: "YiM1Core")],
          path: ".",
          exclude: ["App/Info.plist", "App/YiM1Monitor.entitlements", "App/App.swift",
                    "App/Assets.xcassets", "Design/AppIcon.svg", "Package.swift"]
      )]
  )
  ```
  Build it with the same `--sdk`/`-target` flags as above from inside `YiM1Monitor/`.
  Note it excludes `App/App.swift` (the `@main` entry) - if you add files the shim can't
  compile (e.g. referencing `@main`), extend `exclude`.
- If you touch `project.yml` (e.g. Info.plist keys): regenerate with
  `cd yi-m1-ios && DEVELOPER_DIR=... xcodegen generate`. Info.plist properties are declared in
  `project.yml`'s `info.properties` (xcodegen REGENERATES `YiM1Monitor/App/Info.plist` from it -
  edit the YAML, never the plist).

**Protocol invariants (from live testing - never "improve" these):**
- The camera handles ONE HTTP request at a time. `HTTPClient` (YiM1Core) already serializes all
  send/download calls through a chain + `httpMaximumConnectionsPerHost = 1`. Never bypass it,
  never add a second URLSession/client.
- Camera errors arrive as **HTTP 200 + `{"code":<err>}` in the body**. Use
  `HTTPClient.Response.isCameraSuccess`, never raw `status == 200`, for anything that flips state.
- `GetFile`'s quality parameter is spelled `resulotion` (camera firmware misspelling - correct).
  Qualities: `Original` (~32MB full file) / `MidThumb` (~228KB preview) / `Thumbnail`
  (`FileQuality.fast`, smaller, exact size unmeasured, on-device unverified).
- Wire values (command names, param strings) must match `yi-m1-remote-control/prot_http/` exactly.
- iOS 16 APIs only. Known trap: `onChange(of:) { newValue in }` (one-parameter form) - the
  two-parameter form is iOS 17+ and has already broken the build once.
- `CameraSessionProtocol` is `@MainActor`. Views are generic over it
  (`struct X<Session: CameraSessionProtocol>`); `MockCameraSession` (app target) must implement
  every protocol addition or nothing compiles.
- Live-view frames arrive as JPEG `Data` in `session.latestFrameData` (~10-15fps, sensor
  orientation). `LiveViewCanvas` decodes, letterbox-fits, optionally rotates (`ViewRotation`),
  and overlays guides. Read `YiM1Monitor/Views/LiveViewCanvas.swift` fully before Task A.

**Process requirements:**
- After finishing each task: append a dated implementation note to `DEVELOPMENT_PLAN.md` (same
  style as the existing "РЕАЛИЗОВАНО"/fix sections - what, why, key decisions, what's untested).
- Keep all 32 YiM1Core tests green; add tests where this file says so.
- Final state must have NO leftover verification shim files.
- **Run `cd yi-m1-ios && DEVELOPER_DIR=... xcodegen generate` every time you add a NEW file to
  `YiM1Monitor/`, not just once at the end.** The generated `.xcodeproj` is a snapshot of
  whatever files existed on disk at the last `generate` call - a file created afterward silently
  doesn't exist in the project until the next regenerate. Symptom if you forget: Xcode reports
  "Cannot find 'X' in scope" for a type that's clearly right there in the file, often alongside a
  bogus *second* error on a nearby line (e.g. a `.onChange` closure "expecting 0 arguments") -
  that second error is a cascade from the first failed type lookup breaking overload resolution
  for the rest of the modifier chain, not a real separate bug. (Hit exactly this 2026-07-11 after
  adding `FocusPeaking.swift` following the Task B regenerate - lost a review cycle to it.)

---

## Task A — Focus peaking

**Goal:** manual-focus assist - highlight in-focus (high-contrast) edges over live view with a
colored outline. The user shoots a manual-focus lens; this is the app's highest-value monitor
feature. It must work pre-record (edges are exposure-independent, so the preview's
auto-exposure quirk doesn't matter here).

### A1. Processor (new file `YiM1Monitor/Design/FocusPeaking.swift` or `Views/FocusPeaking.swift`)

Create a `FocusPeakingProcessor` (class, its own internal serial processing) that turns a JPEG
frame `Data` into an overlay `UIImage` (transparent everywhere except peaking-colored edges):

- Pipeline (Core Image, GPU-backed, reuse ONE `CIContext` for the processor's lifetime):
  1. `CIImage(data:)`
  2. `CIFilter.edges()` (`CIEdges`, `intensity` ~1..5 - expose as a constant)
  3. Threshold the edge magnitude so only strong edges survive. iOS 16 has
     `CIFilter.colorThreshold()` (`CIColorThreshold`, iOS 14+); pick threshold ~0.1-0.3,
     constant, tune later.
  4. Colorize: use the thresholded mask to produce solid `AppColor.accent`-amber
     (`#f5a623`) pixels where edges are, transparent elsewhere. One way:
     `CIBlendWithMask` (amber constant-color input image, clear background, mask = threshold
     output). Any equivalent CI composition is fine - correctness over cleverness.
  5. Render to `CGImage` → `UIImage`.
- **Frame dropping is mandatory:** decode/process on a background queue; if a new frame arrives
  while one is processing, drop the older work (keep-latest, no queue). The simplest correct
  shape: an `isProcessing` flag + `pendingData` slot, or an `AsyncStream` consumed by a single
  loop. Never let processing back up behind the ~10-15fps feed.
- Publish the latest overlay via `@Published var overlay: UIImage?` (`ObservableObject`,
  publish on main).
- When peaking is toggled off: clear `overlay`, stop processing.

### A2. Wiring (edit `RootView.swift`, `LiveViewCanvas.swift`, `Design/Icons.swift`)

- `RootView`: `@State private var showPeaking = false`; toggle button in the TOP BAR next to the
  rotate button (the bottom-right guide cluster is full - 4th button doesn't fit its third of
  the width). Same styling as `rotateButton`: SF symbol `scope` (add `AppIcon.peaking = "scope"`),
  16pt, `AppColor.accent` when active, 32×32 frame, accessibility label "Focus peaking".
- Frame feed into the processor: drive it from `session.latestFrameData` changes while
  `showPeaking && connectionState == .connected` (e.g. `.onChange(of: session.latestFrameData)`
  in RootView forwarding into the processor; remember: iOS-16 one-parameter `onChange`).
  Processor instance: `@StateObject` in RootView.
- `LiveViewCanvas`: new optional `peakingOverlay: UIImage?` parameter. Render it EXACTLY like
  the live image (same `fittedRect` from `displaySize`, same `rotatedImage(_:fitted:)` path,
  positioned identically) between the live image and the guide overlay, with
  `.allowsHitTesting(false)`. It must rotate together with the image when `ViewRotation` is
  active. Skip drawing it while `photoReview` is `.ready`/`.downloading` (those take over).
- Overlay/image size mismatch note: the processor output has the same pixel dimensions as the
  frame it was made from, so the same fitting math applies verbatim.

### A3. Verification & acceptance

- YiM1Core untouched → tests stay green (run anyway).
- UI cross-compile via the shim passes.
- Add a Simulator-testable path: extend `MockCameraSession` with a `simulateFrames()` dev helper
  or simply verify the processor directly - a tiny XCTest is NOT possible in the app target (no
  test target), so instead: create the processor in a `#if DEBUG` SwiftUI preview or a small
  `@main`-independent function that runs it on a generated test image (e.g. a
  `UIGraphicsImageRenderer` image: sharp black/white checkerboard half + solid gray half) and
  assert-print that the overlay has non-transparent pixels over the checkerboard and none over
  the flat half. Document in the plan note how it was verified.
- Performance: no formal budget, but the frame-dropping design above is required; note in the
  plan that on-device profiling is pending (user will judge fps impact by eye).
- On-device testing is the USER's step - list what they should check: peaking appears on
  focused edges, follows rotation, toggles cleanly, doesn't lag live view.

---

## Task B — File browser rework

**Goal (user feedback):** swipe-to-reveal actions are unintuitive. Rework into: tap a row → a
file detail screen with explicit actions; selection mode for batch operations; thumbnails in
rows; Save to Photos. Swipe actions stay as a shortcut. This subsumes three previously separate
backlog items (thumbnails, multi-select, save-to-Photos) - implement as ONE coherent change to
`YiM1Monitor/Views/FileBrowserView.swift` (+ core/protocol additions below).

### B1. Core/protocol additions (YiM1Core)

- `CameraSessionProtocol` + `CameraSession` + `MockCameraSession`:
  - `func fetchFileData(_ path: String, quality: FileQuality) async throws -> Data` - like
    `downloadFile` but returns Data instead of writing to a URL (thumbnails and detail previews
    need bytes, not files). `CameraSession` implements via the existing
    `httpClient.download(Commands.getFile(...))` (no progress callback needed - pass a no-op).
    Mock: return a small generated placeholder image's JPEG data (`UIGraphicsImageRenderer` is
    UIKit - the Mock lives in the app target so that's fine) after a short sleep.
  - `func deleteFiles(_ paths: [String]) async -> Bool` - batch delete. ONE command:
    `Commands.deleteFile(paths:)` already takes the array (confirmed wire format, test exists).
    Gate on `isCameraSuccess`. Keep the existing single `deleteFile` (or reimplement it as
    `deleteFiles([path])` - your choice, but don't break the protocol for existing callers).
- Add a `CommandsTests` case asserting the multi-path DeleteFile JSON if not already covered
  (there IS `testDeleteFileHasArrayValue` - extend only if you change anything).

### B2. Thumbnails (app target)

- New `ThumbnailStore` (`@MainActor ObservableObject`): `[String: UIImage]` cache +
  `func thumbnail(for file: CameraFile, session:)` triggering
  `fetchFileData(path, quality: .fast)` (the `Thumbnail` quality - **on-device unverified**; if
  it turns out not honored the images will just be MidThumb-slow, still correct).
  - Load lazily: rows request via `.task(id: file.path)` so scroll-away cancels the SwiftUI task;
    check `Task.isCancelled` before firing the HTTP call (once enqueued in HTTPClient's chain a
    request WILL run - the check prevents queue flooding, which matters at one-request-at-a-time).
  - De-dupe in-flight paths. No disk cache - session-scoped memory is fine (file lists are
    small).
  - Decode failure (likely for video files) → cache a `nil` marker and show a type icon
    (`video`/`camera` SF symbol) - do NOT retry every appearance.
- Row layout: ~56pt thumbnail (rounded 6pt, `AppColor.surface2` placeholder while loading) +
  existing filename/type/date stack + lock icon.

### B3. File detail screen (app target)

- `NavigationLink` from each row (browser is already in a `NavigationStack`) to a
  `FileDetailView`:
  - Large preview: `fetchFileData(path, quality: .medium)` (MidThumb ~228KB, decodes fine -
    it's what photo review uses) on appear, `ProgressView` meanwhile, rotation NOT applied
    (files aren't the live sensor feed). Known quirk: MidThumb JPEGs may log
    `premature end of data` warnings - harmless, they decode (documented fact).
  - Metadata rows: filename, type, date, protected flag.
  - Buttons: **Save to Photos** (primary, accent), **Share/Download** (existing share-sheet
    flow, reuse/extract the `ActivityView` + tmp-file logic), **Delete** (destructive,
    confirmation alert, pops back on success and refreshes the list).
- **Save to Photos** (`import Photos`): request add-only auth
  (`PHPhotoLibrary.requestAuthorization(for: .addOnly)`), then for images
  `PHAssetCreationRequest.forAsset().addResource(with: .photo, data: fullData, options: nil)`
  inside `performChanges` - download `Original` quality first (with progress UI - it can be
  ~32MB; reuse the existing progress-overlay pattern). For videos: download to a tmp file and
  add with `.video` + file URL. Success/failure feedback: simple alert or checkmark state.
- **Info.plist key (REQUIRED or the app crashes on save):** add
  `NSPhotoLibraryAddUsageDescription` ("YI M1 Monitor saves downloaded photos and videos to
  your Photos library.") to `project.yml` → `info.properties`, then `xcodegen generate`.

### B4. Selection mode (app target)

- "Select" toolbar button → List `EditMode.active` with multi-selection
  (`@State selection: Set<String>` bound via `List(selection:)`), rows show checkmarks
  (SwiftUI's edit-mode selection UI).
- Bottom toolbar in selection mode: "Save to Photos (N)" and "Delete (N)".
  - Batch delete: single `deleteFiles(paths)` call + confirmation alert ("Delete N files?"),
    then refresh.
  - Batch save: sequential loop (one-request-at-a-time makes parallel pointless), per-file
    progress ("2 of 5…"), stop-on-error with a message saying how far it got.
- Swipe actions: keep as-is (Delete + Download).

### B5. Verification & acceptance

- All YiM1Core tests green (incl. any you add); UI shim cross-compile passes; `xcodegen
  generate` run if `project.yml` changed (it will - the Photos key), and confirm
  `YiM1Monitor/App/Info.plist` gained the key.
- Mock-driven Simulator sanity: MockCameraSession's `listFiles` already returns 3 fake files -
  extend to ~8 (mixed types incl. a protected one) so thumbnails/selection are visually
  testable; its `fetchFileData` placeholder images make rows/detail render.
- Document in the plan note: what's on-device-unverified (Thumbnail quality honored? video
  thumbnails? Photos auth flow on first save; batch flows against the real camera).

---

## Suggested execution order

Task B is bigger but self-contained; Task A touches the hot live-view path. Either order works;
if parallelizing across two agents, they touch disjoint files EXCEPT `RootView.swift` (Task A
only) and `MockCameraSession.swift` + `CameraSessionProtocol.swift` (Task B only) - actually
fully disjoint except both may add `AppIcon` entries in `Design/Icons.swift`; coordinate or
accept a trivial merge there. Single-agent sequential: B then A (B's protocol changes rebuild
YiM1Core; A rides on top).
