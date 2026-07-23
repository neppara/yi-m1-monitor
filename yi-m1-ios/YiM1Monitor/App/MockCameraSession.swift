// Fake CameraSessionProtocol implementation for SwiftUI previews and clickable UI development
// without hardware (Phase 2 of DEVELOPMENT_PLAN.md runs entirely against this). Mirrors
// CameraSession's state machine shape (including the pending-value settings sync) closely
// enough that swapping in the real session later (T3.2) is a one-line change in App.swift.
import Foundation
import UIKit
import YiM1Core

@MainActor
final class MockCameraSession: ObservableObject, CameraSessionProtocol {
    @Published var connectionState: ConnectionState = .disconnected
    @Published var mode: CaptureMode = .photo
    @Published var isRecording = false
    @Published var status: CameraStatus?
    @Published var metadata: CameraMetadata?
    @Published var latestFrameData: Data?
    @Published var photoReview: PhotoReviewState = .idle
    @Published var photoReviewImageData: Data?
    @Published var pendingWiFiCredentials: WiFiCredentials?
    // No real live-view feed in the mock, so these stay at zero rather than faking numbers.
    @Published var liveViewFPS: Double = 0
    @Published var liveViewDroppedFrameCount: Int = 0
    @Published var liveViewBufferDroppedFrameCount: Int = 0
    @Published var liveViewIncomingFPS: Double = 0
    @Published var liveViewLinkUnstable: Bool = false
    // No real recording loop to restart in the mock - the toggle is settable (so the settings
    // sheet's UI works) but never triggers any restart machinery.
    @Published var autoRestartRecording: Bool = false
    @Published var recordingClipNumber: Int = 1
    @Published var settingValues: [SettingKey: String] = [
        .exposureMode: "P", .iso: "Auto", .shutterSpeed: "1/125", .fNumber: "2.8", .ev: "0",
        .whiteBalance: "Auto", .meteringMode: "Center", .focusMode: "AF-S", .colorMode: "Standard",
        .imageQuality: "20M", .imageAspect: "4:3", .fileFormat: "JPEG", .driveMode: "Single",
    ]

    private var pendingSettings: [SettingKey: (expectedValue: String, deadline: Date)] = [:]
    private static let neverExpireKeys: Set<SettingKey> = [.imageAspect]

    private var reviewClearTask: Task<Void, Never>?

    func connectViaBLE() {
        simulateConnect(withWiFiSheet: true)
    }

    func connectDirect() {
        simulateConnect(withWiFiSheet: false)
    }

    private func simulateConnect(withWiFiSheet: Bool) {
        Task {
            connectionState = .pairing
            try? await Task.sleep(nanoseconds: 500_000_000)
            if withWiFiSheet {
                pendingWiFiCredentials = WiFiCredentials(ssid: "YI_M1_1A2B3C", password: "8x9Qk2mP")
                connectionState = .awaitingWiFiJoin
            } else {
                finishConnecting()
            }
        }
    }

    func confirmWiFiJoinInProgress() {
        guard connectionState == .awaitingWiFiJoin else { return }
        connectionState = .connecting
        Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            finishConnecting()
        }
    }

    private func finishConnecting() {
        connectionState = .connected
        pendingWiFiCredentials = nil
        status = CameraStatus(batteryLevel: "76", shotsLeft: "412", lensVersion: "0.0", lensType: "")
        settingValues[.imageAspect] = "4:3"
    }

    func disconnect() {
        isRecording = false
        latestFrameData = nil
        photoReview = .idle
        connectionState = .disconnecting
        Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            connectionState = .disconnected
            status = nil
        }
    }

    func reset() {
        disconnect()
    }

    func setSetting(_ key: SettingKey, value: String) {
        guard connectionState == .connected else { return }
        let oldValue = settingValues[key]
        let deadline = Self.neverExpireKeys.contains(key) ? Date.distantFuture : Date().addingTimeInterval(5)
        pendingSettings[key] = (expectedValue: value, deadline: deadline)
        settingValues[key] = value // optimistic, same as the real session

        Task {
            // Simulate a stale metadata push landing before the camera applied the change - must
            // NOT revert the optimistic value. Exercises the same protection CameraSession relies
            // on (bug #10/#12), just with fake timing instead of a real live-view frame race.
            try? await Task.sleep(nanoseconds: 300_000_000)
            if let oldValue { reconcile(key, oldValue) }
            try? await Task.sleep(nanoseconds: 700_000_000)
            reconcile(key, value) // the camera "confirms" afterward
        }
    }

    private func reconcile(_ key: SettingKey, _ value: String) {
        guard let pending = pendingSettings[key] else {
            settingValues[key] = value
            return
        }
        if value == pending.expectedValue {
            pendingSettings[key] = nil
            settingValues[key] = value
        } else if Date() >= pending.deadline {
            pendingSettings[key] = nil
            settingValues[key] = value
        }
    }

    func shootPhoto() {
        guard connectionState == .connected else { return }
        Task {
            photoReview = .downloading(bytesReceived: 0, total: 228_000)
            for step in stride(from: 0, through: 228_000, by: 40_000) {
                try? await Task.sleep(nanoseconds: 120_000_000)
                photoReview = .downloading(bytesReceived: step, total: 228_000)
            }
            photoReview = .ready
            reviewClearTask?.cancel()
            reviewClearTask = Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard case .ready = photoReview else { return }
                photoReview = .idle
            }
        }
    }

    func toggleRecording() {
        guard connectionState == .connected else { return }
        isRecording.toggle()
    }

    func forceStopRecording() {
        guard connectionState == .connected else { return }
        isRecording = false
    }

    func focus(atImagePoint point: (x: Int, y: Int)) {}

    func listFiles() async -> FileListResponse.Result {
        .ok([
            CameraFile(path: "/DCIM/100YICAM/YIMG0001.JPG", date: Date().addingTimeInterval(-1800), filetype: "picture", isProtected: false),
            CameraFile(path: "/DCIM/100YICAM/YIMG0002.DNG", date: Date().addingTimeInterval(-3600), filetype: "rawJpeg", isProtected: false),
            CameraFile(path: "/DCIM/100YICAM/YIMG0003.JPG", date: Date().addingTimeInterval(-5400), filetype: "picture", isProtected: true),
            CameraFile(path: "/DCIM/100YICAM/YIVID0001.MP4", date: Date().addingTimeInterval(-7200), filetype: "video", isProtected: false),
            CameraFile(path: "/DCIM/100YICAM/YIMG0004.JPG", date: Date().addingTimeInterval(-9000), filetype: "picture", isProtected: false),
            CameraFile(path: "/DCIM/100YICAM/YIMG0005.DNG", date: Date().addingTimeInterval(-10800), filetype: "raw", isProtected: false),
            CameraFile(path: "/DCIM/100YICAM/YIVID0002.MP4", date: Date().addingTimeInterval(-12600), filetype: "video", isProtected: true),
            CameraFile(path: "/DCIM/100YICAM/YIMG0006.JPG", date: Date().addingTimeInterval(-14400), filetype: "picture", isProtected: false),
        ])
    }

    func downloadFile(_ path: String, quality: FileQuality, to url: URL, onProgress: @escaping (Int, Int) -> Void) async throws {
        for step in stride(from: 0, through: 100, by: 20) {
            try? await Task.sleep(nanoseconds: 100_000_000)
            onProgress(step, 100)
        }
        try Self.placeholderImageData(for: path).write(to: url)
    }

    func fetchFileData(_ path: String, quality: FileQuality) async throws -> Data {
        try? await Task.sleep(nanoseconds: 300_000_000)
        return Self.placeholderImageData(for: path)
    }

    func deleteFiles(_ paths: [String]) async -> Bool {
        try? await Task.sleep(nanoseconds: 200_000_000)
        return true
    }

    /// A small solid-color JPEG, colored deterministically by path, standing in for a real
    /// camera thumbnail/preview - enough to sanity-check thumbnail/detail-screen layout in the
    /// Simulator without a camera.
    private static func placeholderImageData(for path: String) -> Data {
        let colors: [UIColor] = [.systemOrange, .systemTeal, .systemPurple, .systemGreen, .systemPink, .systemIndigo]
        let color = colors[abs(path.hashValue) % colors.count]
        let size = CGSize(width: 320, height: 240)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { _ in
            color.setFill()
            UIRectFill(CGRect(origin: .zero, size: size))
        }
        return image.jpegData(compressionQuality: 0.8) ?? Data()
    }
}
