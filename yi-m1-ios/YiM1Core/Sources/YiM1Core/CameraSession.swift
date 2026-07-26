// The real CameraSessionProtocol implementation - orchestrates BLE -> manual Wi-Fi join wait ->
// RCStartRemoteCtl -> live view + status polling, plus settings/capture/files. Port of
// yi-m1-remote-control/app/camera_session.py + the settings-sync logic from main_window.py.
import Foundation

@MainActor
public final class CameraSession: ObservableObject, CameraSessionProtocol {
    @Published public private(set) var connectionState: ConnectionState = .disconnected
    @Published public var mode: CaptureMode = .photo
    @Published public private(set) var isRecording = false
    @Published public private(set) var status: CameraStatus?
    @Published public private(set) var metadata: CameraMetadata?
    @Published public private(set) var latestFrameData: Data?
    @Published public private(set) var photoReview: PhotoReviewState = .idle
    @Published public private(set) var photoReviewImageData: Data?
    @Published public private(set) var pendingWiFiCredentials: WiFiCredentials?
    @Published public private(set) var settingValues: [SettingKey: String] = [:]
    @Published public private(set) var liveViewFPS: Double = 0
    @Published public private(set) var liveViewDroppedFrameCount: Int = 0
    @Published public private(set) var liveViewBufferDroppedFrameCount: Int = 0
    /// Rate at which the camera's frames are STARTING to arrive (first packet seen), regardless
    /// of whether they complete - the gap between this and `liveViewFPS` is what the loss layers
    /// are eating. Updated on the 5s status-poll tick from the receiver's cumulative counter.
    @Published public private(set) var liveViewIncomingFPS: Double = 0
    /// User toggle (I4, 2026-07-12), default off - restarts recording near-instantly just under
    /// the camera's own recording-length limits for near-continuous capture. See
    /// `RecordingAutoRestart` for why app-side restart is the achievable ceiling (true nonstop
    /// recording is impossible on this camera).
    @Published public var autoRestartRecording: Bool = false
    /// Which clip of the current recording session this is - 1 for the first, incremented on
    /// each successful auto-restart. Reset to 1 whenever recording starts fresh.
    @Published public private(set) var recordingClipNumber: Int = 1
    /// True when the live-view feed is showing the radio-away symptom found during the
    /// 2026-07-11 stutter investigation (Bluetooth/Wi-Fi antenna coexistence, plus iOS's own
    /// unsuppressable background Wi-Fi scans) - a burst of >50ms inter-packet gaps. Purely
    /// informational: tells the shooter "that's radio contention, not a hang" - see FIELD USAGE
    /// RULE #1 (turn Bluetooth off) in this file's dated notes.
    @Published public private(set) var liveViewLinkUnstable: Bool = false

    private var lastStatsSampleTime: Date?
    private var lastFramesStartedCount = 0
    private var lastRecvGapsOver50msCount = 0
    /// More than this many new >50ms gaps within one 5s sample window marks the link unstable.
    /// Field logs during the investigation showed ~25-30 such events per 5s during a radio-away
    /// episode vs ~0-2 normally - comfortably clear of this threshold either way.
    private static let weakLinkGapDeltaThreshold = 10

    // Camera-self-stop detection via the live-view fps signature (the I4 "detection signal"
    // hook, filled in 2026-07-12 after the user's field test): while recording, the camera
    // throttles live view to ~7.5fps; the moment it stops recording on its own (its ~7.5-min
    // 4K / ~30-min general limit), the stream jumps back to ~30fps. Sampled on the 5s cadence:
    // the detector ARMS only after two consecutive slow samples while recording (proof that
    // THIS format actually throttles - self-calibrating, so a hypothetical non-throttling
    // format can never false-trigger), then fires after two consecutive fast samples.
    private var recordingThrottleArmed = false
    private var slowSamplesWhileRecording = 0
    private var fastSamplesWhileRecording = 0
    /// Whether the PREVIOUS 5s stats sample was taken while recording - see the weak-link
    /// post-stop grace in `sampleLiveViewStats`.
    private var lastSampleWasRecording = false
    private static let recordingThrottleFPSCeiling: Double = 12   // below = throttled (recording)
    private static let recordingStoppedFPSFloor: Double = 20      // above = full-rate (stopped)

    /// Rolling window for the fps figure - recomputed on every frame arrival rather than on a
    /// timer, so it's always current the moment something reads it.
    private var recentFrameTimestamps: [Date] = []
    private static let fpsWindow: TimeInterval = 2.0

    private let httpClient: HTTPClient
    private let wifiConnector: WiFiConnector
    private let bleFactory: @Sendable () -> BLEPairing
    private let liveViewReceiver: LiveViewReceiver

    private var connectTask: Task<Void, Never>?
    private var liveViewTask: Task<Void, Never>?
    private var statusPollTask: Task<Void, Never>?
    private var reviewClearTask: Task<Void, Never>?
    private var autoRestartTask: Task<Void, Never>?
    /// Wall-clock start of the CURRENT clip (reset on each successful auto-restart) - drives the
    /// auto-restart monitor's elapsed-time check. Distinct from RootView's own `recordingStartedAt`
    /// (which drives the on-screen timer and is derived from `isRecording` toggling, the same
    /// underlying event).
    private var recordingStartedAt: Date?

    // Settings pending-value sync - exact port of the macOS bug #10/#12 fix (see
    // main_window.py's _on_setting_changed / _on_live_metadata). When the user changes a
    // setting, its metadata-driven sync is suppressed until either the camera confirms the new
    // value or a timeout passes (whichever first) - so a live-view frame captured just before
    // the camera applied the change can't snap the UI back to the old value. `.imageAspect` is a
    // permanent exception (bug #12): its metadata field has been observed to never reliably
    // reflect the pending value at all, so it's trusted indefinitely (deadline = .distantFuture)
    // rather than ever "giving up" and reverting.
    private var pendingSettings: [SettingKey: (expectedValue: String, deadline: Date)] = [:]
    private static let neverExpireKeys: Set<SettingKey> = [.imageAspect]
    private static let defaultConfirmTimeout: TimeInterval = 5.0

    public init(
        httpClient: HTTPClient = HTTPClient(),
        liveViewReceiver: LiveViewReceiver = LiveViewReceiver(),
        bleFactory: @escaping @Sendable () -> BLEPairing = { BLEPairing() }
    ) {
        self.httpClient = httpClient
        self.wifiConnector = WiFiConnector(httpClient: httpClient)
        self.liveViewReceiver = liveViewReceiver
        self.bleFactory = bleFactory
    }

    private var isConnectionAttemptInFlight: Bool {
        switch connectionState {
        case .pairing, .awaitingWiFiJoin, .connecting, .connected, .disconnecting: return true
        case .disconnected, .error: return false
        }
    }

    // MARK: - Connection

    // NOTE on the `if Task.isCancelled { return }` checks in every connect flow below: reset()
    // cancels connectTask, but cancellation is cooperative - an in-flight BLE handshake or
    // reachability poll keeps running until its next suspension point, then lands in the catch
    // (Task.sleep throws CancellationError when cancelled) or falls through to a state write.
    // Without these checks an abandoned attempt would clobber connectionState AFTER reset()
    // already moved the session on (e.g. flipping a fresh new connection into .error).

    public func connectViaBLE() {
        guard !isConnectionAttemptInFlight else { return } // ignore duplicate taps mid-attempt
        connectionState = .pairing
        connectTask?.cancel()
        connectTask = Task { [weak self] in
            guard let self else { return }
            do {
                let ble = self.bleFactory()
                let creds = try await ble.pairWithClosestCamera()
                if Task.isCancelled { return }

                self.pendingWiFiCredentials = creds
                self.connectionState = .awaitingWiFiJoin
                // The reachability wait is kicked off by confirmWiFiJoinInProgress(), called by
                // the UI once it's presented the manual-join sheet - see that method.
            } catch {
                if Task.isCancelled { return }
                self.connectionState = .error(Self.bleFailureMessage(for: error))
            }
        }
    }

    /// Permission-denied paths (I5, 2026-07-12) should say what to do, not just fail generically
    /// - `BLEPairingError.bluetoothUnavailable` already carries a human-readable reason (see
    /// `BLEPairing.centralManagerDidUpdateState`); everything else keeps the generic message.
    private static func bleFailureMessage(for error: Error) -> String {
        if case BLEPairingError.bluetoothUnavailable(let reason) = error {
            return "\(reason) - turn Bluetooth on in Settings and try again."
        }
        return "BLE pairing failed: \(error)"
    }

    public func confirmWiFiJoinInProgress() {
        guard connectionState == .awaitingWiFiJoin else { return }
        connectionState = .connecting
        connectTask?.cancel()
        connectTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.wifiConnector.waitForReachability(timeout: 120)
                try await self.startRemoteControlSession()
            } catch {
                if Task.isCancelled { return }
                if self.pendingWiFiCredentials != nil {
                    // The manual-join sheet is still up - go back to .awaitingWiFiJoin so its
                    // "I've connected" button works as a retry, instead of dead-ending in .error
                    // behind a sheet whose button would no-op.
                    self.connectionState = .awaitingWiFiJoin
                } else {
                    self.connectionState = .error(Self.unreachableMessage("Could not reach the camera after joining Wi-Fi: \(error)"))
                }
            }
        }
    }

    public func connectDirect() {
        guard !isConnectionAttemptInFlight else { return }
        connectionState = .connecting
        connectTask?.cancel()
        connectTask = Task { [weak self] in
            guard let self else { return }
            guard await self.wifiConnector.isReachableNow() else {
                if Task.isCancelled { return }
                self.connectionState = .error(Self.unreachableMessage("Camera not reachable - make sure this iPhone is already on the camera's Wi-Fi network."))
                return
            }
            do {
                try await self.startRemoteControlSession()
            } catch {
                if Task.isCancelled { return }
                self.connectionState = .error("\(error)")
            }
        }
    }

    private func startRemoteControlSession() async throws {
        let response = await httpClient.send(Commands.rcStartRemoteCtl())
        guard response.isCameraSuccess else {
            let bodyPreview = String(data: response.body.prefix(120), encoding: .utf8) ?? ""
            throw NSError(domain: "CameraSession", code: response.status,
                           userInfo: [NSLocalizedDescriptionKey: "RCStartRemoteCtl failed (status=\(response.status) \(bodyPreview))"])
        }
        try Task.checkCancellation() // reset() during the await above - don't resurrect the session
        connectionState = .connected
        pendingWiFiCredentials = nil
        Self.hasEverConnected = true
        startLiveView()
        startStatusPolling()
    }

    /// Whether this app has ever reached `.connected` on this device (I5, 2026-07-12) - gates
    /// the Local Network permission hint below: a first-time user who denied that prompt sees an
    /// unreachable-camera error that looks identical to "just not on the right Wi-Fi network", so
    /// the extra hint is only useful (and only shown) before the first successful connection.
    /// Persisted via UserDefaults since a fresh CameraSession is created per app launch.
    private static var hasEverConnected: Bool {
        get { UserDefaults.standard.bool(forKey: "yim1.hasConnectedSuccessfully") }
        set { UserDefaults.standard.set(newValue, forKey: "yim1.hasConnectedSuccessfully") }
    }

    private static func unreachableMessage(_ base: String) -> String {
        guard !hasEverConnected else { return base }
        return base + " If this is your first time connecting, check Settings → Privacy & Security → Local Network and make sure YI M1 Monitor is allowed."
    }

    public func disconnect() {
        let wasRecording = isRecording
        connectTask?.cancel()
        liveViewTask?.cancel()
        statusPollTask?.cancel()
        reviewClearTask?.cancel()
        autoRestartTask?.cancel()
        liveViewReceiver.stop()

        // Clear the visual state immediately - no reason to show a stale live view/review frame
        // while the teardown below is still in flight.
        isRecording = false
        recordingStartedAt = nil
        recordingClipNumber = 1
        latestFrameData = nil
        photoReview = .idle
        photoReviewImageData = nil
        connectionState = .disconnecting

        let client = httpClient
        Task { [weak self] in
            if wasRecording {
                _ = await client.send(Commands.videoRecordingStop())
            }
            _ = await client.send(Commands.rcStopRemoteCtl())
            // Only now has the camera's one-client slot actually been released - flipping to
            // .disconnected (which re-enables Connect) only after this completes prevents a fast
            // reconnect from racing its own RCStartRemoteCtl against this RCStopRemoteCtl and
            // getting rejected by the camera ("rc only one"). Guarded on still being in
            // .disconnecting: if the user hit Reset (or anything else moved the state on) while
            // the stop command was in flight, this completion must not clobber the newer state.
            guard let self, self.connectionState == .disconnecting else { return }
            self.resetPublishedState()
        }
    }

    /// Abandon whatever's in flight without waiting for it to unwind (mirrors the macOS "Reset
    /// connection" button - there's no clean way to cancel a stuck BLE call mid-flight, so this
    /// just stops listening to it and starts clean; the old attempt becomes a harmless orphan).
    public func reset() {
        connectTask?.cancel()
        liveViewTask?.cancel()
        statusPollTask?.cancel()
        reviewClearTask?.cancel()
        autoRestartTask?.cancel()
        liveViewReceiver.stop()
        // Best-effort attempt to make the camera release its one-client slot too, in case it's
        // actually still reachable and only our own state got stuck - but don't wait on it, since
        // Reset exists precisely for when nothing can be trusted to complete.
        let client = httpClient
        Task { _ = await client.send(Commands.rcStopRemoteCtl()) }
        resetPublishedState()
    }

    private func resetPublishedState() {
        connectionState = .disconnected
        isRecording = false
        recordingStartedAt = nil
        recordingClipNumber = 1
        latestFrameData = nil
        photoReview = .idle
        photoReviewImageData = nil
        pendingWiFiCredentials = nil
        status = nil
        metadata = nil
        pendingSettings = [:]
    }

    // MARK: - Live view + status polling

    private func startLiveView() {
        liveViewTask?.cancel()
        let receiver = liveViewReceiver
        recentFrameTimestamps = []
        liveViewFPS = 0
        liveViewDroppedFrameCount = 0
        liveViewBufferDroppedFrameCount = 0
        liveViewIncomingFPS = 0
        liveViewLinkUnstable = false
        lastStatsSampleTime = nil
        lastFramesStartedCount = 0
        lastRecvGapsOver50msCount = 0
        lastSampleWasRecording = false
        resetSelfStopDetector()
        liveViewTask = Task { [weak self] in
            let stream = receiver.start()
            for await frame in stream {
                if Task.isCancelled { break }
                guard let self else { break }
                self.latestFrameData = frame.jpegData
                self.recordFrameArrival()
                if let metadata = frame.metadata {
                    self.handleNewMetadata(metadata)
                }
            }
        }
    }

    /// Updates the fps/dropped-frame debug stats - called once per delivered live-view frame.
    private func recordFrameArrival() {
        let now = Date()
        recentFrameTimestamps.append(now)
        let cutoff = now.addingTimeInterval(-Self.fpsWindow)
        recentFrameTimestamps.removeAll { $0 < cutoff }
        liveViewFPS = Double(recentFrameTimestamps.count) / Self.fpsWindow
        let stats = liveViewReceiver.statsSnapshot()
        liveViewDroppedFrameCount = stats.droppedFrameCount
        liveViewBufferDroppedFrameCount = stats.bufferDroppedFrameCount
    }

    /// Consecutive GetCameraStatus failures (timeout, unreachable, bad response) tolerated before
    /// declaring the connection lost - the camera itself has no way to notify us when it drops
    /// (powered off, out of range, screen-locked, etc.), so this poll doubles as the only signal
    /// we have. 3 tries at the 5s poll interval (~15s, plus each attempt's own 3s HTTP timeout)
    /// tolerates a brief Wi-Fi blip without either flapping on transient hiccups or leaving the
    /// UI stuck on "Connected" for too long after the camera actually vanished.
    private static let maxConsecutiveStatusFailures = 3

    private func startStatusPolling() {
        statusPollTask?.cancel()
        let client = httpClient
        statusPollTask = Task { [weak self] in
            var consecutiveFailures = 0
            while !Task.isCancelled {
                let response = await client.send(Commands.getCameraStatus())
                if response.status == 200, let parsed = CameraStatus.parse(responseBody: response.body) {
                    consecutiveFailures = 0
                    self?.status = parsed
                } else {
                    consecutiveFailures += 1
                    if consecutiveFailures >= Self.maxConsecutiveStatusFailures {
                        // I5 (2026-07-12): can't actually distinguish "camera powered off" from
                        // "out of Wi-Fi range" from here (both just stop answering) - the
                        // qualifier at least tells the user what to check instead of implying an
                        // app bug.
                        self?.handleConnectionLost(reason: "Lost connection to the camera (camera off or out of range)")
                        return
                    }
                }
                self?.sampleLiveViewStats()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    /// Periodic (5s, piggybacked on the status poll) deep-dive into live-view health: computes
    /// the camera's incoming frame rate from the receiver's frames-STARTED counter (delivered
    /// fps alone can't distinguish "camera sends little" from "we lose much"), and in DEBUG
    /// prints a full forensic line to the Xcode console - the user explicitly asked for richer
    /// logs to analyze the field stutters with (2026-07-11).
    private func sampleLiveViewStats() {
        let stats = liveViewReceiver.statsSnapshot(resetPeakGap: true) // 5s sampler owns the peak interval
        let now = Date()
        if let lastTime = lastStatsSampleTime {
            let elapsed = now.timeIntervalSince(lastTime)
            if elapsed > 0 {
                liveViewIncomingFPS = Double(stats.framesStartedCount - lastFramesStartedCount) / elapsed
            }
        }
        lastStatsSampleTime = now
        lastFramesStartedCount = stats.framesStartedCount

        // Weak-link detection (I3, 2026-07-12): delta of >50ms gaps since the last 5s sample.
        // Hysteresis - only a fully clean sample (delta == 0) clears the flag; a delta in
        // between (below the threshold but nonzero) holds whatever state was already showing,
        // so one stray gap right after a bad window doesn't cause a visible flicker.
        let gapDelta = stats.recvGapsOver50msCount - lastRecvGapsOver50msCount
        lastRecvGapsOver50msCount = stats.recvGapsOver50msCount
        // The one-sample grace after recording ends matters too (field screenshot 2026-07-12):
        // the first post-stop sample's gap delta still covers a stretch of the throttled-rate
        // period, so without it the chip flashes right after every recording stops.
        let recordingAffectsThisSample = isRecording || lastSampleWasRecording
        lastSampleWasRecording = isRecording
        if recordingAffectsThisSample {
            // CAMERA FACT (field-confirmed 2026-07-12): while recording, the camera itself
            // throttles the live-view stream to ~7.5fps to save resources for the encoder -
            // at that rate EVERY inter-frame gap (~133ms) exceeds the 50ms threshold, so the
            // counter races upward (~37 per 5s window) during any recording. The signal is
            // meaningless then; without this gate the chip would false-positive for the whole
            // duration of every recording.
            liveViewLinkUnstable = false
        } else if gapDelta > Self.weakLinkGapDeltaThreshold {
            liveViewLinkUnstable = true
        } else if gapDelta == 0 {
            liveViewLinkUnstable = false
        }

        // Camera-self-stop detection (see the state properties' doc comment for the mechanism).
        if isRecording, liveViewIncomingFPS > 0 {
            if liveViewIncomingFPS < Self.recordingThrottleFPSCeiling {
                fastSamplesWhileRecording = 0
                slowSamplesWhileRecording += 1
                if slowSamplesWhileRecording >= 2 { recordingThrottleArmed = true }
            } else if liveViewIncomingFPS > Self.recordingStoppedFPSFloor {
                slowSamplesWhileRecording = 0
                if recordingThrottleArmed {
                    fastSamplesWhileRecording += 1
                    if fastSamplesWhileRecording >= 2 {
                        handleCameraSelfStoppedRecording()
                    }
                }
            } else {
                // In-between rate (transition/heavy loss) - counts toward neither state.
                fastSamplesWhileRecording = 0
            }
        } else {
            resetSelfStopDetector()
        }

        #if DEBUG
        let missingPercent = stats.droppedFramesExpectedPackets > 0
            ? 100 * stats.droppedFramesMissingPackets / stats.droppedFramesExpectedPackets
            : 0
        print(String(
            format: "[liveview] in=%.1f fps out=%.1f fps | started=%d ok=%d net=%d buf=%d | dropped frames missing %d%% of their packets | maxgap=%dms gaps>50ms=%d | rcvbuf=%dKB",
            liveViewIncomingFPS, liveViewFPS,
            stats.framesStartedCount, stats.validFrameCount,
            stats.droppedFrameCount, stats.bufferDroppedFrameCount,
            missingPercent, stats.maxRecvGapMs, stats.recvGapsOver50msCount,
            stats.socketReceiveBufferBytes / 1024
        ))
        #endif
    }

    /// The camera disconnecting on its own end (powered off, out of Wi-Fi range, etc.) has no
    /// notification of its own - this is what actually detects it, via startStatusPolling()'s
    /// failure counter. Distinct from disconnect()/reset(): there's no live connection to send
    /// RCStopRemoteCtl to, so this just tears down local state and surfaces an error.
    private func handleConnectionLost(reason: String) {
        guard connectionState == .connected else { return }
        connectTask?.cancel()
        liveViewTask?.cancel()
        statusPollTask?.cancel()
        reviewClearTask?.cancel()
        autoRestartTask?.cancel()
        liveViewReceiver.stop()
        isRecording = false
        recordingStartedAt = nil
        recordingClipNumber = 1
        latestFrameData = nil
        photoReview = .idle
        photoReviewImageData = nil
        pendingWiFiCredentials = nil
        status = nil
        metadata = nil
        pendingSettings = [:]
        connectionState = .error(reason)
    }

    // MARK: - Settings sync

    private func handleNewMetadata(_ metadata: CameraMetadata) {
        self.metadata = metadata

        for key in SettingCatalog.commandInfo.keys {
            guard let value = metadata[key] else { continue }

            if let pending = pendingSettings[key] {
                if value == pending.expectedValue {
                    pendingSettings[key] = nil
                    settingValues[key] = value
                } else if Date() < pending.deadline {
                    continue // camera hasn't caught up yet (or, for .imageAspect, never will) - don't revert the optimistic value
                } else {
                    pendingSettings[key] = nil
                    settingValues[key] = value // gave up waiting - accept whatever the camera actually reports
                }
            } else {
                settingValues[key] = value
            }
        }
    }

    public func setSetting(_ key: SettingKey, value: String) {
        guard connectionState == .connected, let command = SettingCatalog.command(for: key, rawValue: value) else { return }
        let client = httpClient
        Task { _ = await client.send(command) }

        let deadline = Self.neverExpireKeys.contains(key) ? Date.distantFuture : Date().addingTimeInterval(Self.defaultConfirmTimeout)
        pendingSettings[key] = (expectedValue: value, deadline: deadline)
        settingValues[key] = value // optimistic - reflects the user's choice immediately, doesn't wait for metadata
    }

    // MARK: - Capture

    /// Applies a photo-review state change only while still connected - a disconnect/reset mid-
    /// shoot must not have the abandoned shoot task repaint review state onto the fresh session.
    private func setPhotoReview(_ state: PhotoReviewState, imageData: Data? = nil) {
        guard connectionState == .connected else { return }
        photoReviewImageData = imageData
        photoReview = state
    }

    public func shootPhoto() {
        guard connectionState == .connected else { return }
        let client = httpClient
        Task { [weak self] in
            let shootTime = Date()
            let shootResponse = await client.send(Commands.rcDoShooting())
            guard shootResponse.isCameraSuccess else {
                self?.setPhotoReview(.failed("RCDoShooting failed (status=\(shootResponse.status))"))
                return
            }

            // Poll for the new file by max `date`, up to 8s - mirrors macOS's
            // _do_shoot_and_review. GetFileList's response shape here is the confirmed real one
            // (bug #11).
            var newestPath: String?
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline {
                let listResponse = await client.send(Commands.getFileList())
                if case .ok(let files) = FileListResponse.parse(status: listResponse.status, body: listResponse.body),
                   let newest = files.max(by: { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }),
                   let date = newest.date, date >= shootTime.addingTimeInterval(-5) {
                    newestPath = newest.path
                    break
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }

            guard let path = newestPath else {
                self?.setPhotoReview(.failed("Could not find the new photo on the camera after shooting."))
                return
            }

            self?.setPhotoReview(.downloading(bytesReceived: 0, total: -1))
            do {
                // MidThumb ("quality: .medium") is the fast preview - confirmed ~228KB vs
                // ~32MB for .best/"Original" (see DEVELOPMENT_PLAN.md Part 4.3).
                let data = try await client.download(Commands.getFile(path: path, quality: .medium)) { [weak self] received, total in
                    Task { @MainActor in
                        self?.setPhotoReview(.downloading(bytesReceived: received, total: total))
                    }
                }
                guard let self, self.connectionState == .connected else { return }
                self.setPhotoReview(.ready, imageData: data)
                self.reviewClearTask?.cancel()
                self.reviewClearTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 2_000_000_000) // 2s, per the macOS revision (500ms was too short)
                    guard let self, case .ready = self.photoReview else { return }
                    self.photoReview = .idle
                    self.photoReviewImageData = nil
                }
            } catch {
                self?.setPhotoReview(.failed("\(error)"))
            }
        }
    }

    /// Guards toggleRecording against a double-tap race: two quick taps would both read the same
    /// `isRecording`, send VideoRecordingStart twice, and the two success paths would toggle the
    /// flag twice - leaving the UI showing "not recording" while the camera records.
    private var recordingCommandInFlight = false

    /// Held for this long after each record command completes, on top of the in-flight guard.
    /// Rapid start/stop cycling wedged the real camera on-device (2026-07-09): it ended up
    /// recording with its own controls locked while a stop had "succeeded" transport-wise. The
    /// firmware needs a beat to finalize a file before the next command; a sub-1.5s video is
    /// meaningless anyway.
    private static let recordCommandCooldown: TimeInterval = 1.5

    public func toggleRecording() {
        guard connectionState == .connected, !recordingCommandInFlight else { return }
        recordingCommandInFlight = true
        let client = httpClient
        let wasRecording = isRecording
        Task { [weak self] in
            let command = wasRecording ? Commands.videoRecordingStop() : Commands.videoRecordingStart()
            let response = await client.send(command)
            guard let self else { return }
            // isCameraSuccess, not just HTTP 200: the camera signals failure as HTTP 200 +
            // {"code":<err>} (see HTTPClient.Response.isCameraSuccess) - flipping on transport
            // status alone is exactly what desynced the UI from a still-recording camera.
            if response.isCameraSuccess, self.connectionState == .connected {
                self.isRecording = !wasRecording
                if wasRecording {
                    self.recordingStartedAt = nil
                    self.autoRestartTask?.cancel()
                    self.autoRestartTask = nil
                } else {
                    self.recordingStartedAt = Date()
                    self.recordingClipNumber = 1
                    self.resetSelfStopDetector()
                    self.startAutoRestartMonitor()
                }
            }
            try? await Task.sleep(nanoseconds: UInt64(Self.recordCommandCooldown * 1_000_000_000))
            self.recordingCommandInFlight = false
        }
    }

    /// Escape hatch for a desynced camera (long-press on the shutter in video mode): sends
    /// VideoRecordingStop regardless of what `isRecording` claims, and trusts the user -
    /// the flag is cleared even if the camera answers with an error (which it will, harmlessly,
    /// if it genuinely wasn't recording).
    public func forceStopRecording() {
        guard connectionState == .connected, !recordingCommandInFlight else { return }
        recordingCommandInFlight = true
        let client = httpClient
        Task { [weak self] in
            _ = await client.send(Commands.videoRecordingStop())
            guard let self else { return }
            if self.connectionState == .connected {
                self.isRecording = false
            }
            self.recordingStartedAt = nil
            self.autoRestartTask?.cancel()
            self.autoRestartTask = nil
            try? await Task.sleep(nanoseconds: UInt64(Self.recordCommandCooldown * 1_000_000_000))
            self.recordingCommandInFlight = false
        }
    }

    /// Runs for the lifetime of the current recording (started alongside it in `toggleRecording`,
    /// cancelled on any stop) - polls once a second rather than sleeping for the whole interval
    /// up front, so toggling `autoRestartRecording` mid-recording takes effect within a second
    /// instead of only on the next clip.
    private func startAutoRestartMonitor() {
        autoRestartTask?.cancel()
        autoRestartTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { break }
                guard let self else { return }
                guard self.connectionState == .connected, self.isRecording, self.autoRestartRecording,
                      let startedAt = self.recordingStartedAt, !self.recordingCommandInFlight else { continue }
                let elapsed = Date().timeIntervalSince(startedAt)
                // TODO (I4 hook point): if the user's on-device clip-boundary diagnosis finds a
                // detectable signal for the camera stopping/splitting on its own (a metadata
                // field, a GetCameraStatus change, a live-view behavior), check for it here FIRST
                // and restart immediately on that signal rather than waiting for the timer -
                // more responsive and immune to clock drift between our elapsed-time estimate and
                // the camera's own. Until then, the timer below is the only available signal.
                if RecordingAutoRestart.isRestartDue(elapsed: elapsed, videoFormat: self.metadata?.videoFormat) {
                    await self.performAutoRestart()
                }
            }
        }
    }

    /// Must be called on EVERY recording (re)start, not just on stop (2026-07-19 audit find):
    /// the 5s stats window that spans an auto-restart's inter-clip gap reads the camera's
    /// full-rate stream as a "fast" sample, and with the armed flag surviving the restart, two
    /// such windows in a row would false-fire the self-stop detector right after a successful
    /// restart - flipping isRecording to false and sending a doomed extra Start.
    private func resetSelfStopDetector() {
        recordingThrottleArmed = false
        slowSamplesWhileRecording = 0
        fastSamplesWhileRecording = 0
    }

    /// The camera ended the recording on its own (hit its ~7.5-min 4K / ~30-min limit) - fired
    /// by the fps-signature detector in `sampleLiveViewStats`. Resyncs the UI to the truth
    /// (`isRecording` = false; the pre-detector behavior was a stuck "recording" state whose
    /// shutter tap then looked dead, recoverable only via long-press force-stop), and when
    /// auto-restart is on, starts the next clip immediately - no VideoRecordingStop needed,
    /// the camera already stopped itself.
    private func handleCameraSelfStoppedRecording() {
        resetSelfStopDetector()
        isRecording = false
        recordingStartedAt = nil
        guard autoRestartRecording, connectionState == .connected, !recordingCommandInFlight else { return }
        recordingCommandInFlight = true
        let client = httpClient
        Task { [weak self] in
            let response = await client.send(Commands.videoRecordingStart())
            guard let self else { return }
            if response.isCameraSuccess, self.connectionState == .connected {
                self.recordingClipNumber += 1
                self.recordingStartedAt = Date()
                self.isRecording = true
            }
            try? await Task.sleep(nanoseconds: UInt64(Self.recordCommandCooldown * 1_000_000_000))
            self.recordingCommandInFlight = false
        }
    }

    /// Stop -> cooldown -> start, through the same command-grade machinery as a manual
    /// `toggleRecording` (never bypasses `recordingCommandInFlight`/the cooldown - rapid cycling
    /// wedges the real camera, see the 2026-07-09 desync fix above). `isRecording` genuinely
    /// flips false then true again (not held true through the gap) so RootView's existing
    /// `onChange(of: session.isRecording)` naturally resets the on-screen per-clip timer, and so
    /// a failed restart correctly leaves the UI showing "not recording" rather than lying.
    private func performAutoRestart() async {
        guard connectionState == .connected, isRecording, !recordingCommandInFlight else { return }
        recordingCommandInFlight = true
        let client = httpClient

        let stopResponse = await client.send(Commands.videoRecordingStop())
        guard stopResponse.isCameraSuccess else {
            // Couldn't even stop cleanly - leave everything as-is and let the next monitor tick
            // retry, rather than guessing at camera state from a failed transport op.
            try? await Task.sleep(nanoseconds: UInt64(Self.recordCommandCooldown * 1_000_000_000))
            recordingCommandInFlight = false
            return
        }
        isRecording = false
        recordingStartedAt = nil
        try? await Task.sleep(nanoseconds: UInt64(Self.recordCommandCooldown * 1_000_000_000))

        guard connectionState == .connected else {
            recordingCommandInFlight = false
            return
        }
        let startResponse = await client.send(Commands.videoRecordingStart())
        if startResponse.isCameraSuccess, connectionState == .connected {
            recordingClipNumber += 1
            recordingStartedAt = Date()
            isRecording = true
            resetSelfStopDetector() // see its doc comment - the inter-clip gap poisons the samples
        }
        // If the restart's start failed, isRecording/recordingStartedAt stay cleared above -
        // matches reality (the camera isn't recording) instead of the UI claiming otherwise.
        try? await Task.sleep(nanoseconds: UInt64(Self.recordCommandCooldown * 1_000_000_000))
        recordingCommandInFlight = false
    }

    public func focus(atImagePoint point: (x: Int, y: Int)) {
        guard connectionState == .connected else { return }
        let client = httpClient
        // NOTE (unverified - see DEVELOPMENT_PLAN.md Part 4.1): the Posx/Posy coordinate
        // convention has never been confirmed live.
        Task { _ = await client.send(Commands.rcDoFocus(mode: .manual, imagePoint: point)) }
    }

    // MARK: - Files

    public func listFiles() async -> FileListResponse.Result {
        let response = await httpClient.send(Commands.getFileList())
        return FileListResponse.parse(status: response.status, body: response.body)
    }

    public func downloadFile(_ path: String, quality: FileQuality, to url: URL, onProgress: @escaping (Int, Int) -> Void) async throws {
        // Streams straight to disk (2026-07-24). The previous version buffered the entire file
        // in memory and then wrote it in one go, which for a multi-GB clip off this camera got
        // the app jetsam-killed before the write ever happened.
        try await httpClient.download(Commands.getFile(path: path, quality: quality), to: url) { received, total in
            onProgress(received, total)
        }
    }

    public func fetchFileData(_ path: String, quality: FileQuality) async throws -> Data {
        try await httpClient.download(Commands.getFile(path: path, quality: quality)) { _, _ in }
    }

    public func deleteFiles(_ paths: [String]) async -> Bool {
        let response = await httpClient.send(Commands.deleteFile(paths: paths))
        return response.isCameraSuccess
    }
}
