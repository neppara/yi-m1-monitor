// The app shell: status bar, mode toggle, live view, controls, settings strip - same
// information architecture as the macOS main_window.py MainWindow, adapted to the portrait-first
// touch layout decided in Part 6.
import SwiftUI
import UIKit
import YiM1Core

struct RootView<Session: CameraSessionProtocol>: View {
    @ObservedObject var session: Session

    @State private var showCrop = false
    @State private var showThirds = false
    @State private var showDiagonals = false
    @State private var showFileBrowser = false
    @State private var rotation: ViewRotation = .none
    @State private var recordingStartedAt: Date?
    @State private var showPeaking = false
    @State private var showFieldTips = false
    /// Landscape only (I6, 2026-07-12; reworked same day) - the settings strip is not
    /// permanently visible there; the settings button toggles it as an overlay floated over
    /// the live view's bottom edge.
    @State private var showLandscapeSettings = false
    @StateObject private var peakingProcessor = FocusPeakingProcessor()

    /// iPhone landscape has a compact vertical size class - the idiomatic, rotation-angle-
    /// independent (LandscapeLeft vs LandscapeRight both qualify) way to detect it.
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var isConnected: Bool { session.connectionState == .connected }

    /// Camera battery percentage when it's low enough to warn about, else nil. 15% matches the
    /// point where the camera's own indicator goes red.
    private var lowBatteryLevel: Int? {
        guard isConnected, let status = session.status,
              let level = Int(status.batteryLevel), level <= 15 else { return nil }
        return level
    }

    var body: some View {
        Group {
            if verticalSizeClass == .compact {
                landscapeBody
            } else {
                portraitBody
            }
        }
        .background(AppColor.bg)
        .sheet(isPresented: $showFileBrowser) {
            FileBrowserView(session: session)
        }
        .sheet(isPresented: $showFieldTips) {
            FieldTipsSheet()
        }
        .sheet(isPresented: wifiJoinPresented) {
            if let credentials = session.pendingWiFiCredentials {
                WiFiJoinSheet(session: session, credentials: credentials)
                    .presentationDetents([.medium])
            }
        }
        .onChange(of: session.isRecording) { recording in
            recordingStartedAt = recording ? Date() : nil
        }
        // Keep the phone awake while connected - this app IS the camera monitor; the phone
        // sleeping mid-shoot defeats its whole purpose. Restored on disconnect/error and when
        // the view goes away (iOS also force-restores it when the app fully quits).
        .onChange(of: session.connectionState) { state in
            UIApplication.shared.isIdleTimerDisabled = (state == .connected)
            if state != .connected {
                peakingProcessor.clear()
            }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    // MARK: - Portrait (default, Part 6 touch layout - unchanged by I6)

    private var portraitBody: some View {
        VStack(spacing: 0) {
            topBar
            if let level = lowBatteryLevel {
                batteryWarning(level: level)
            }
            ModeToggle(mode: modeBinding)
                .padding(.bottom, AppSpace.sm)

            liveViewStack
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            controlRow
            SettingsStrip(session: session)
                .opacity(isConnected ? 1 : 0.4)
                .disabled(!isConnected)
        }
    }

    // MARK: - Landscape (I6, 2026-07-12; reworked same day per user's on-device feedback:
    // controls were overlaying the live image even though the letterboxed 4:3 image leaves
    // free space at the sides - so the columns are now real layout SIBLINGS of the canvas,
    // not overlays, and the canvas gets exactly the middle region between them)

    /// Row 1: status chip + fps counter (DEBUG) + icons-only mode toggle. Below it, three
    /// columns: left - six uniform toggle buttons (info/peaking/rotate + crop/thirds/diagonals),
    /// center - the live view, right - shutter/settings/files. Settings are one tap away
    /// (`showLandscapeSettings`) rather than a permanently-visible strip - there isn't the
    /// vertical space for one here.
    private var landscapeBody: some View {
        VStack(spacing: 0) {
            // Top row - the only thing above the live view.
            HStack(spacing: AppSpace.sm) {
                ConnectionMenu(session: session) { statusChip }
                #if DEBUG
                if isConnected { liveViewStatsChip }
                #endif
                Spacer()
                ModeToggle(mode: modeBinding, iconsOnly: true)
            }
            .padding(.horizontal, AppSpace.md)
            .padding(.vertical, AppSpace.xs)

            HStack(spacing: 0) {
                // Left column: six identical-size toggles - view controls on top (info,
                // peaking, rotate), guide overlays below (crop, thirds, diagonals).
                VStack(spacing: AppSpace.sm) {
                    landscapeIconButton(systemImage: "info.circle", active: false, label: "Field tips") {
                        showFieldTips = true
                    }
                    landscapeIconButton(systemImage: AppIcon.peaking, active: showPeaking, label: "Focus peaking") {
                        showPeaking.toggle()
                        if !showPeaking { peakingProcessor.clear() }
                    }
                    landscapeIconButton(systemImage: AppIcon.rotate, active: rotation.isRotated, label: "Rotate live view") {
                        rotation = rotation.next()
                    }
                    // Crop is a fact in video mode (2026-07-19) - shown active and locked; a
                    // real toggle only in photo mode. Mirrors GuideToggles.cropAlwaysOn.
                    landscapeIconButton(systemImage: AppIcon.crop,
                                        active: showCrop || session.mode == .video, label: "Crop") {
                        showCrop.toggle()
                    }
                    .disabled(!isConnected || session.mode == .video)
                    landscapeIconButton(systemImage: AppIcon.thirds, active: showThirds, label: "Thirds") {
                        showThirds.toggle()
                    }
                    .disabled(!isConnected)
                    landscapeDiagonalsButton
                        .disabled(!isConnected)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, AppSpace.sm)

                liveViewStack
                    // Weak-link/battery float top-center over the image; the recording timer
                    // moved to the bottom (user feedback 2026-07-12: at the top it collided
                    // with the busy top row during recording).
                    .overlay(alignment: .top) {
                        VStack(spacing: AppSpace.sm) {
                            if let level = lowBatteryLevel {
                                batteryWarningChip(level: level)
                            }
                            if isConnected && session.liveViewLinkUnstable {
                                weakLinkChip
                            }
                        }
                        .padding(.top, AppSpace.sm)
                    }
                    .overlay(alignment: .bottom) {
                        VStack(spacing: AppSpace.sm) {
                            if let startedAt = recordingStartedAt {
                                RecordingTimerChip(startedAt: startedAt, clipNumber: session.recordingClipNumber)
                            }
                            // The settings strip in landscape is on-demand (settings button
                            // toggles it) - same chips + inline quick picker as portrait,
                            // floated over the bottom edge on a scrim instead of the old
                            // navigation sheet (2026-07-12 UX rework: fewer taps, live view
                            // stays visible while adjusting).
                            if showLandscapeSettings {
                                SettingsStrip(session: session)
                                    .disabled(!isConnected)
                                    .background(Color.black.opacity(0.6))
                                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
                            }
                        }
                        .padding(.bottom, AppSpace.sm)
                    }

                // Right column (2026-07-12 user feedback): settings dead-center vertically,
                // shutter above and file manager below at equal distances - the fixed VStack
                // spacing gives the equidistance, maxHeight centering puts settings in the
                // middle of the column.
                VStack(spacing: AppSpace.xl + AppSpace.sm) {
                    shutterControl
                    landscapeSettingsButton
                    landscapeFilesButton
                }
                .frame(maxHeight: .infinity)
                .padding(.horizontal, AppSpace.sm)
            }
        }
    }

    /// One uniform left-column toggle (2026-07-12 landscape rework): same 44pt-content pill for
    /// all six, unlike portrait where the top-bar buttons and the guide cluster deliberately
    /// differ in size.
    private func landscapeIconButton(systemImage: String, active: Bool, label: String,
                                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(PillButtonStyle(active: active))
        .accessibilityLabel(label)
    }

    /// Diagonals has no SF Symbol (see Icons.swift) - same shape as `landscapeIconButton`,
    /// hand-drawn glyph inside.
    private var landscapeDiagonalsButton: some View {
        Button {
            showDiagonals.toggle()
        } label: {
            DiagonalsIcon(color: showDiagonals ? AppColor.accent : AppColor.text2)
                .frame(width: 16, height: 16)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(PillButtonStyle(active: showDiagonals))
        .accessibilityLabel("Diagonals")
    }

    private var landscapeSettingsButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                showLandscapeSettings.toggle()
            }
        } label: {
            Image(systemName: AppIcon.settings)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(showLandscapeSettings ? AppColor.accent : AppColor.text2)
                .frame(width: 44, height: 44)
        }
        .disabled(!isConnected)
        .accessibilityLabel("Settings")
    }

    /// Label-less counterpart to portrait's `filesButton` (2026-07-12 user feedback: the other
    /// landscape icons carry no captions, so neither should this one) - same icon size/weight
    /// as the settings button above it for a visually even column.
    private var landscapeFilesButton: some View {
        Button {
            showFileBrowser = true
        } label: {
            Image(systemName: AppIcon.folder)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(AppColor.text2)
                .frame(width: 44, height: 44)
        }
        .disabled(!isConnected)
        .accessibilityLabel("Files")
    }

    private var shutterControl: some View {
        ShutterButton(mode: session.mode, isRecording: session.isRecording, isEnabled: isConnected) {
            if session.mode == .photo {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                session.shootPhoto()
            } else {
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                session.toggleRecording()
            }
        }
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 1.0).onEnded { _ in
                guard session.mode == .video, isConnected else { return }
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                session.forceStopRecording()
            }
        )
    }

    // MARK: - Shared: the live view + its floating overlays (identical in both orientations)

    private var liveViewStack: some View {
        ZStack(alignment: .top) {
            LiveViewCanvas(
                frameData: session.latestFrameData,
                mode: session.mode,
                showCrop: showCrop,
                showThirds: showThirds,
                showDiagonals: showDiagonals,
                isRecording: session.isRecording,
                imageAspect: session.settingValues[.imageAspect],
                videoFormat: session.metadata?.videoFormat,
                photoReview: session.photoReview,
                photoReviewImageData: session.photoReviewImageData,
                rotation: rotation,
                peakingOverlay: showPeaking ? peakingProcessor.overlay : nil,
                onFocus: { x, y in session.focus(atImagePoint: (x, y)) },
                onNewFrame: { data in
                    guard showPeaking, isConnected else { return }
                    peakingProcessor.process(data)
                }
            )
            // Portrait draws its own recording timer/weak-link/fps chips inline here (over the
            // canvas, same as before I6); landscape draws its own copies positioned for that
            // layout in landscapeBody - see there. The recording timer sits at the BOTTOM on
            // both orientations (user feedback 2026-07-12: at the top it collided with other
            // elements during recording).
            if verticalSizeClass != .compact {
                if let startedAt = recordingStartedAt {
                    VStack {
                        Spacer()
                        RecordingTimerChip(startedAt: startedAt, clipNumber: session.recordingClipNumber)
                            .padding(.bottom, AppSpace.sm)
                    }
                }
                if isConnected && session.liveViewLinkUnstable {
                    VStack {
                        HStack {
                            weakLinkChip
                            Spacer()
                        }
                        Spacer()
                    }
                    .padding(AppSpace.sm)
                }
                #if DEBUG
                if isConnected {
                    VStack {
                        HStack {
                            Spacer()
                            liveViewStatsChip
                        }
                        Spacer()
                    }
                    .padding(AppSpace.sm)
                }
                #endif
            }
        }
    }

    #if DEBUG
    /// Live-view fps (2s rolling window) + the two separate drop counts - lets a slow feed away
    /// from home (crowded 2.4GHz RF vs an app-side problem) actually be diagnosed instead of just
    /// eyeballed. "net" = packets genuinely never arrived (network/reassembly loss); "buf" = the
    /// frame WAS fully reassembled but this app discarded it because the UI consumer fell behind
    /// (see `LiveViewStats`'s doc comment in YiM1Core) - splitting these two was the whole point
    /// of adding this second number (2026-07-11): they indict completely different layers, and a
    /// single combined count couldn't tell you which one to actually chase. Debug builds only;
    /// deliberately not a user-facing feature.
    private var liveViewStatsChip: some View {
        // "in" = frames the camera started sending (first packet seen, updated every 5s);
        // "out" = frames fully delivered to screen. The in→out gap is what loss is eating.
        Text(String(
            format: "in %.0f · out %.1f · %d net · %d buf",
            session.liveViewIncomingFPS, session.liveViewFPS,
            session.liveViewDroppedFrameCount, session.liveViewBufferDroppedFrameCount
        ))
        .font(.system(size: AppFont.caption, design: .monospaced))
        .foregroundStyle(AppColor.text2)
        .padding(.horizontal, AppSpace.sm)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.55))
        .clipShape(Capsule())
    }
    #endif

    /// Informational only (I3, 2026-07-12) - tells the shooter that stutter right now is radio
    /// contention (Bluetooth/Wi-Fi antenna coexistence, or iOS's own background Wi-Fi scans),
    /// not an app hang. See FIELD USAGE RULE #1 in DEVELOPMENT_PLAN.md: turn Bluetooth off.
    private var weakLinkChip: some View {
        HStack(spacing: 6) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: AppFont.caption))
            Text("Weak link")
                .font(.system(size: AppFont.caption, weight: .medium))
        }
        .foregroundStyle(AppColor.accent)
        .padding(.horizontal, AppSpace.sm)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.55))
        .clipShape(Capsule())
    }

    /// Compact counterpart to `batteryWarning(level:)` for landscape (I6, 2026-07-12) - the
    /// full-width bar doesn't make sense floating over the center of a full-frame live view.
    private func batteryWarningChip(level: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "battery.25")
                .font(.system(size: AppFont.caption))
            Text("Battery low · \(level)%")
                .font(.system(size: AppFont.caption, weight: .medium))
        }
        .foregroundStyle(AppColor.record)
        .padding(.horizontal, AppSpace.sm)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.55))
        .clipShape(Capsule())
    }

    private func batteryWarning(level: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "battery.25")
                .font(.system(size: AppFont.small))
            Text("Camera battery low · \(level)%")
                .font(.system(size: AppFont.caption, weight: .medium))
        }
        .foregroundStyle(AppColor.record)
        .padding(.horizontal, AppSpace.md)
        .padding(.vertical, AppSpace.xs)
        .frame(maxWidth: .infinity)
        .background(AppColor.record.opacity(0.12))
    }

    private var modeBinding: Binding<CaptureMode> {
        Binding(get: { session.mode }, set: { session.mode = $0 })
    }

    private var wifiJoinPresented: Binding<Bool> {
        Binding(
            get: { session.pendingWiFiCredentials != nil },
            set: { presented in
                // Swipe-down dismissal must abandon the attempt, or the still-set credentials
                // immediately re-present the sheet. The extra nil-check matters: SwiftUI also
                // calls set(false) when the sheet closes *programmatically* (credentials cleared
                // on successful connect) - resetting then would tear down the fresh connection.
                if !presented && session.pendingWiFiCredentials != nil {
                    session.reset()
                }
            }
        )
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            // The chip itself opens the connection menu (Connect BLE / Connect direct /
            // Disconnect / Reset) - reworked 2026-07-12 (I2) to replace the truncating
            // "YI M1 Monitor" title with the status text, which now gets that freed leading
            // width instead of squeezing into the trailing cluster.
            ConnectionMenu(session: session) { statusChip }
            Spacer()
            fieldTipsButton
            peakingButton
            rotateButton
        }
        .padding(.horizontal, AppSpace.lg)
        .padding(.top, AppSpace.md)
        .padding(.bottom, AppSpace.sm)
    }

    /// Pre-session checklist (I5, 2026-07-12) - the field rules from the stability
    /// investigation (Bluetooth off, expected self-recovering stutters, one client at a time,
    /// etc.), for a shooter setting up who wasn't around for that investigation.
    private var fieldTipsButton: some View {
        Button {
            showFieldTips = true
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 16))
                .foregroundStyle(AppColor.text2)
                .frame(width: 32, height: 32)
        }
        .accessibilityLabel("Field tips")
    }

    /// Manual live-view rotation for vertical shooting (camera mounted sideways) - cycles
    /// 0° -> 90° -> -90°. Amber while a rotation is active.
    private var rotateButton: some View {
        Button {
            rotation = rotation.next()
        } label: {
            Image(systemName: AppIcon.rotate)
                .font(.system(size: 16))
                .foregroundStyle(rotation.isRotated ? AppColor.accent : AppColor.text2)
                .frame(width: 32, height: 32)
        }
        .accessibilityLabel("Rotate live view")
    }

    /// Focus peaking toggle - manual-focus assist, highlights in-focus edges in the accent color.
    /// Lives in the top bar (not the bottom guide cluster, which is already full with three
    /// toggles across its third of the width).
    private var peakingButton: some View {
        Button {
            showPeaking.toggle()
            if !showPeaking {
                peakingProcessor.clear()
            }
        } label: {
            Image(systemName: AppIcon.peaking)
                .font(.system(size: 16))
                .foregroundStyle(showPeaking ? AppColor.accent : AppColor.text2)
                .frame(width: 32, height: 32)
        }
        .accessibilityLabel("Focus peaking")
    }

    private var statusChip: some View {
        HStack(spacing: 6) {
            Circle().fill(dotColor).frame(width: 7, height: 7)
            Text(statusText)
                .font(.system(size: AppFont.small))
                .foregroundStyle(AppColor.text2)
                .lineLimit(1)
            // Now that this chip doubles as the connection menu's tappable label (no more
            // separate ellipsis button), a chevron signals it opens something.
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(AppColor.text3)
        }
        .statusChipStyle()
    }

    private var dotColor: Color {
        switch session.connectionState {
        case .connected: return AppColor.ok
        case .error: return AppColor.record
        default: return AppColor.text3
        }
    }

    private var statusText: String {
        switch session.connectionState {
        case .disconnected: return "Disconnected"
        case .pairing: return "Pairing — check the camera screen…"
        case .awaitingWiFiJoin: return "Waiting for Wi-Fi"
        case .connecting: return "Connecting…"
        case .connected:
            guard let status = session.status else { return "Connected" }
            return "Connected · \(status.batteryLevel)% · \(status.shotsLeft) shots"
        case .disconnecting: return "Disconnecting…"
        case .error(let message): return "Error: \(message)"
        }
    }

    // MARK: - Control row

    private var controlRow: some View {
        HStack(spacing: 0) {
            HStack {
                Spacer(minLength: 0)
                filesButton
                Spacer()
            }
            .frame(maxWidth: .infinity)

            ShutterButton(mode: session.mode, isRecording: session.isRecording, isEnabled: isConnected) {
                // Haptic confirmation - when the phone is mounted as a monitor you often trigger
                // by feel without looking at the screen. Light for photo, heavy for record.
                if session.mode == .photo {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    session.shootPhoto()
                } else {
                    UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                    session.toggleRecording()
                }
            }
            // Escape hatch for a desynced camera (seen on-device: camera stuck recording while
            // the app said it wasn't - a normal tap would then send Start, not Stop). Long-press
            // in video mode force-sends VideoRecordingStop regardless of the believed state.
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 1.0).onEnded { _ in
                    guard session.mode == .video, isConnected else { return }
                    UINotificationFeedbackGenerator().notificationOccurred(.warning)
                    session.forceStopRecording()
                }
            )

            HStack {
                Spacer()
                GuideToggles(showCrop: $showCrop, showThirds: $showThirds, showDiagonals: $showDiagonals,
                             cropAlwaysOn: session.mode == .video)
                    .disabled(!isConnected)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, AppSpace.lg)
        .padding(.vertical, AppSpace.md)
    }

    private var filesButton: some View {
        Button {
            showFileBrowser = true
        } label: {
            VStack(spacing: 2) {
                Image(systemName: AppIcon.folder).font(.system(size: 20))
                Text("Files").font(.system(size: AppFont.caption))
            }
            .foregroundStyle(AppColor.text2)
            .frame(width: 64)
        }
        .disabled(!isConnected)
    }
}

/// Elapsed recording time, red dot + mm:ss, floating over the top of the live view. The camera
/// doesn't report recording duration - this counts locally from the moment VideoRecordingStart
/// succeeded (isRecording flipped true).
private struct RecordingTimerChip: View {
    let startedAt: Date
    /// > 1 once auto-restart (I4) has kicked in at least once for this recording session.
    let clipNumber: Int

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            HStack(spacing: 6) {
                Circle().fill(AppColor.record).frame(width: 7, height: 7)
                Text(label(for: context.date))
                    .font(.system(size: AppFont.small, weight: .medium, design: .monospaced))
                    .foregroundStyle(AppColor.text)
            }
            .padding(.horizontal, AppSpace.md)
            .padding(.vertical, AppSpace.xs + 1)
            .background(Color.black.opacity(0.55))
            .clipShape(Capsule())
        }
    }

    private func label(for date: Date) -> String {
        let elapsed = formatted(date.timeIntervalSince(startedAt))
        return clipNumber > 1 ? "clip \(clipNumber) · \(elapsed)" : elapsed
    }

    private func formatted(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }
}
