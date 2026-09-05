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
    @State private var showLandscapeSettings = false
    @StateObject private var peakingProcessor = FocusPeakingProcessor()

    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var isConnected: Bool { session.connectionState == .connected }

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
            }
        }
        .onChange(of: session.isRecording) { recording in
            recordingStartedAt = recording ? Date() : nil
        }
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

    // MARK: - 竖屏

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

    // MARK: - 横屏

    private var landscapeBody: some View {
        VStack(spacing: 0) {
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
                VStack(spacing: AppLayout.isFourInchPhone ? 4 : AppSpace.sm) {
                    landscapeIconButton(systemImage: "info.circle", active: false, label: "使用提示") {
                        showFieldTips = true
                    }
                    landscapeIconButton(systemImage: AppIcon.peaking, active: showPeaking, label: "峰值对焦") {
                        showPeaking.toggle()
                        if !showPeaking { peakingProcessor.clear() }
                    }
                    landscapeIconButton(systemImage: AppIcon.rotate, active: rotation.isRotated, label: "旋转实时取景") {
                        rotation = rotation.next()
                    }
                    landscapeIconButton(
                        systemImage: AppIcon.crop,
                        active: showCrop || session.mode == .video,
                        label: "裁切范围"
                    ) {
                        showCrop.toggle()
                    }
                    .disabled(!isConnected || session.mode == .video)

                    landscapeIconButton(systemImage: AppIcon.thirds, active: showThirds, label: "三分线") {
                        showThirds.toggle()
                    }
                    .disabled(!isConnected)

                    landscapeDiagonalsButton
                        .disabled(!isConnected)

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, AppLayout.isFourInchPhone ? 4 : AppSpace.sm)

                liveViewStack
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
                            if showLandscapeSettings {
                                SettingsStrip(session: session)
                                    .disabled(!isConnected)
                                    .background(Color.black.opacity(0.6))
                                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
                            }
                        }
                        .padding(.bottom, AppSpace.sm)
                    }

                VStack(spacing: AppLayout.isFourInchPhone ? AppSpace.lg : AppSpace.xl + AppSpace.sm) {
                    shutterControl
                    landscapeSettingsButton
                    landscapeFilesButton
                }
                .frame(maxHeight: .infinity)
                .padding(.horizontal, AppLayout.isFourInchPhone ? 4 : AppSpace.sm)
            }
        }
    }

    private func landscapeIconButton(
        systemImage: String,
        active: Bool,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: AppLayout.isFourInchPhone ? 14 : 16, weight: .medium))
                .frame(
                    width: AppLayout.isFourInchPhone ? 24 : 28,
                    height: AppLayout.isFourInchPhone ? 24 : 28
                )
        }
        .buttonStyle(PillButtonStyle(active: active))
        .accessibilityLabel(label)
    }

    private var landscapeDiagonalsButton: some View {
        Button {
            showDiagonals.toggle()
        } label: {
            DiagonalsIcon(color: showDiagonals ? AppColor.accent : AppColor.text2)
                .frame(width: AppLayout.isFourInchPhone ? 14 : 16, height: AppLayout.isFourInchPhone ? 14 : 16)
                .frame(
                    width: AppLayout.isFourInchPhone ? 24 : 28,
                    height: AppLayout.isFourInchPhone ? 24 : 28
                )
        }
        .buttonStyle(PillButtonStyle(active: showDiagonals))
        .accessibilityLabel("对角线")
    }

    private var landscapeSettingsButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                showLandscapeSettings.toggle()
            }
        } label: {
            Image(systemName: AppIcon.settings)
                .font(.system(size: AppLayout.isFourInchPhone ? 18 : 20, weight: .medium))
                .foregroundStyle(showLandscapeSettings ? AppColor.accent : AppColor.text2)
                .frame(width: AppLayout.isFourInchPhone ? 38 : 44, height: AppLayout.isFourInchPhone ? 38 : 44)
        }
        .disabled(!isConnected)
        .accessibilityLabel("设置")
    }

    private var landscapeFilesButton: some View {
        Button {
            showFileBrowser = true
        } label: {
            Image(systemName: AppIcon.folder)
                .font(.system(size: AppLayout.isFourInchPhone ? 18 : 20, weight: .medium))
                .foregroundStyle(AppColor.text2)
                .frame(width: AppLayout.isFourInchPhone ? 38 : 44, height: AppLayout.isFourInchPhone ? 38 : 44)
        }
        .disabled(!isConnected)
        .accessibilityLabel("文件")
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

    // MARK: - 实时取景

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
    private var liveViewStatsChip: some View {
        Text(String(
            format: "入 %.0f · 出 %.1f · 网 %d · 缓 %d",
            session.liveViewIncomingFPS,
            session.liveViewFPS,
            session.liveViewDroppedFrameCount,
            session.liveViewBufferDroppedFrameCount
        ))
        .font(.system(size: AppFont.caption, design: .monospaced))
        .foregroundStyle(AppColor.text2)
        .padding(.horizontal, AppSpace.sm)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.55))
        .clipShape(Capsule())
    }
    #endif

    private var weakLinkChip: some View {
        HStack(spacing: 6) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: AppFont.caption))
            Text("链路较弱")
                .font(.system(size: AppFont.caption, weight: .medium))
        }
        .foregroundStyle(AppColor.accent)
        .padding(.horizontal, AppSpace.sm)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.55))
        .clipShape(Capsule())
    }

    private func batteryWarningChip(level: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "battery.25")
                .font(.system(size: AppFont.caption))
            Text("电量低 · \(level)%")
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
            Text("相机电量低 · \(level)%")
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
                if !presented && session.pendingWiFiCredentials != nil {
                    session.reset()
                }
            }
        )
    }

    // MARK: - 顶栏

    private var topBar: some View {
        HStack(spacing: AppLayout.isFourInchPhone ? 2 : AppSpace.sm) {
            ConnectionMenu(session: session) { statusChip }
            Spacer(minLength: AppSpace.xs)
            fieldTipsButton
            peakingButton
            rotateButton
        }
        .padding(.horizontal, AppLayout.isFourInchPhone ? AppSpace.md : AppSpace.lg)
        .padding(.top, AppSpace.md)
        .padding(.bottom, AppSpace.sm)
    }

    private var fieldTipsButton: some View {
        Button {
            showFieldTips = true
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 16))
                .foregroundStyle(AppColor.text2)
                .frame(width: AppLayout.isFourInchPhone ? 28 : 32, height: AppLayout.isFourInchPhone ? 28 : 32)
        }
        .accessibilityLabel("使用提示")
    }

    private var rotateButton: some View {
        Button {
            rotation = rotation.next()
        } label: {
            Image(systemName: AppIcon.rotate)
                .font(.system(size: 16))
                .foregroundStyle(rotation.isRotated ? AppColor.accent : AppColor.text2)
                .frame(width: AppLayout.isFourInchPhone ? 28 : 32, height: AppLayout.isFourInchPhone ? 28 : 32)
        }
        .accessibilityLabel("旋转实时取景")
    }

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
                .frame(width: AppLayout.isFourInchPhone ? 28 : 32, height: AppLayout.isFourInchPhone ? 28 : 32)
        }
        .accessibilityLabel("峰值对焦")
    }

    private var statusChip: some View {
        HStack(spacing: AppLayout.isFourInchPhone ? 4 : 6) {
            Circle().fill(dotColor).frame(width: 7, height: 7)
            Text(statusText)
                .font(.system(size: AppFont.small))
                .foregroundStyle(AppColor.text2)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
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
        case .disconnected:
            return "未连接"
        case .pairing:
            return AppLayout.isFourInchPhone ? "蓝牙配对中…" : "正在配对，请查看相机屏幕…"
        case .awaitingWiFiJoin:
            return "等待 Wi-Fi"
        case .connecting:
            return "连接中…"
        case .connected:
            guard let status = session.status else { return "已连接" }
            return AppLayout.isFourInchPhone
                ? "已连接 · \(status.batteryLevel)% · \(status.shotsLeft)张"
                : "已连接 · \(status.batteryLevel)% · 剩余 \(status.shotsLeft) 张"
        case .disconnecting:
            return "正在断开…"
        case .error(let message):
            return "错误：\(message)"
        }
    }

    // MARK: - 底部控制

    private var controlRow: some View {
        HStack(spacing: 0) {
            HStack {
                Spacer(minLength: 0)
                filesButton
                Spacer()
            }
            .frame(maxWidth: .infinity)

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

            HStack {
                Spacer()
                GuideToggles(
                    showCrop: $showCrop,
                    showThirds: $showThirds,
                    showDiagonals: $showDiagonals,
                    cropAlwaysOn: session.mode == .video
                )
                .disabled(!isConnected)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, AppLayout.isFourInchPhone ? AppSpace.md : AppSpace.lg)
        .padding(.vertical, AppSpace.md)
    }

    private var filesButton: some View {
        Button {
            showFileBrowser = true
        } label: {
            VStack(spacing: 2) {
                Image(systemName: AppIcon.folder)
                    .font(.system(size: AppLayout.isFourInchPhone ? 18 : 20))
                Text("文件")
                    .font(.system(size: AppFont.caption))
            }
            .foregroundStyle(AppColor.text2)
            .frame(width: AppLayout.isFourInchPhone ? 48 : 64)
        }
        .disabled(!isConnected)
        .accessibilityLabel("相机文件")
    }
}

private struct RecordingTimerChip: View {
    let startedAt: Date
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
        return clipNumber > 1 ? "片段 \(clipNumber) · \(elapsed)" : elapsed
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
