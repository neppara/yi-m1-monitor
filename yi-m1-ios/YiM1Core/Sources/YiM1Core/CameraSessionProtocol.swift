// The seam between the protocol/session layer and SwiftUI (DEVELOPMENT_PLAN.md Part 3).
// Views bind to this; CameraSession (this package) is the real implementation, MockCameraSession
// (app target, since it needs no networking) is used for SwiftUI previews and UI-only testing.
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

public enum ConnectionState: Sendable, Equatable {
    case disconnected
    case pairing              // BLE handshake in progress
    case awaitingWiFiJoin     // credentials obtained, waiting for the user to join manually (v1 flow)
    case connecting           // reachable, RCStartRemoteCtl in flight
    case connected
    /// RCStopRemoteCtl is in flight. Distinct from .disconnected so a new connect attempt can't
    /// start (and race) until the camera has actually acknowledged releasing its one-client slot
    /// - reconnecting before that lands can get rejected by the camera ("rc only one").
    case disconnecting
    case error(String)
}

public enum CaptureMode: Sendable, Equatable {
    case photo
    case video
}

public enum PhotoReviewState: Sendable, Equatable {
    case idle
    case downloading(bytesReceived: Int, total: Int)
    case ready
    case failed(String)
}

@MainActor
public protocol CameraSessionProtocol: AnyObject, ObservableObject {
    var connectionState: ConnectionState { get }
    var mode: CaptureMode { get set }
    var isRecording: Bool { get }
    var status: CameraStatus? { get }
    var metadata: CameraMetadata? { get }
    var latestFrameData: Data? { get }          // raw JPEG bytes - Views decode to a displayable image
    var photoReview: PhotoReviewState { get }
    var photoReviewImageData: Data? { get }     // valid while photoReview == .ready
    var pendingWiFiCredentials: WiFiCredentials? { get } // set while connectionState == .awaitingWiFiJoin
    var settingValues: [SettingKey: String] { get } // current known value per setting

    /// Live-view fps (2s rolling window) and cumulative dropped-frame counts, for the DEBUG
    /// diagnostic overlay - lets a slow feed away from home (crowded 2.4GHz RF vs an app-side
    /// problem) actually be diagnosed instead of just eyeballed. The two drop counts indict
    /// different layers - see `LiveViewStats`'s doc comment: `liveViewDroppedFrameCount` is a
    /// real network/reassembly loss; `liveViewBufferDroppedFrameCount` is a fully-reassembled
    /// frame this app itself discarded because the UI consumer fell behind.
    var liveViewFPS: Double { get }
    var liveViewDroppedFrameCount: Int { get }
    var liveViewBufferDroppedFrameCount: Int { get }
    /// Rate at which camera frames START arriving (first packet seen), complete or not - the gap
    /// between this and `liveViewFPS` is what loss is eating.
    var liveViewIncomingFPS: Double { get }
    /// True during a radio-away episode (Bluetooth/Wi-Fi antenna coexistence, or iOS's own
    /// background Wi-Fi scans) - user-facing, unlike the DEBUG-only fps figures above, so the
    /// shooter can tell stutter-from-radio apart from an app hang.
    var liveViewLinkUnstable: Bool { get }
    /// User toggle (I4) - near-continuous recording via app-side stop/start just under the
    /// camera's own recording-length limits. See `RecordingAutoRestart`.
    var autoRestartRecording: Bool { get set }
    /// 1 for the first clip of the current recording, incremented on each successful
    /// auto-restart; reset to 1 whenever recording starts fresh.
    var recordingClipNumber: Int { get }

    // Connection
    func connectViaBLE()
    func connectDirect()
    func disconnect()
    func reset()
    /// Called by the UI once the manual Wi-Fi join sheet is dismissed/the reachability poll
    /// should (re)start - see WiFiConnector + DEVELOPMENT_PLAN.md Part 4.2.
    func confirmWiFiJoinInProgress()

    // Capture
    func shootPhoto()
    func toggleRecording()
    /// Sends VideoRecordingStop regardless of the believed recording state - escape hatch for a
    /// desynced camera (observed on-device 2026-07-09: camera stuck recording while the app said
    /// it wasn't). Wired to a long-press on the shutter in video mode.
    func forceStopRecording()
    func focus(atImagePoint point: (x: Int, y: Int))

    // Settings
    func setSetting(_ key: SettingKey, value: String)

    // Files
    func listFiles() async -> FileListResponse.Result
    func downloadFile(_ path: String, quality: FileQuality, to url: URL, onProgress: @escaping (Int, Int) -> Void) async throws
    /// Fetches file bytes directly (no disk write) - for thumbnails and the file-detail preview,
    /// which need `Data` to decode into a `UIImage`, not a saved file.
    func fetchFileData(_ path: String, quality: FileQuality) async throws -> Data
    /// Batch delete - `DeleteFile`'s wire format already takes an array of paths (one command
    /// either way), so single-file delete is just `deleteFiles([path])`.
    func deleteFiles(_ paths: [String]) async -> Bool
}
