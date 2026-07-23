// Non-setting command builders - port of yi-m1-remote-control/prot_http/command_http.py and
// const_http_cmd.py. All commands are `[String: String]` dicts sent as
// `GET http://192.168.0.10/?data=<urlencoded-json>` - see HTTPClient.swift.
import Foundation

/// File download quality - port of const_http_enum_extra.py's CmdEnumFileQuality.
/// `.medium` ("MidThumb") is what the post-shot review uses (confirmed ~228KB vs ~32MB for
/// `.best`/"Original" - see DEVELOPMENT_PLAN.md Part 4.3).
public enum FileQuality: String, Sendable {
    case best = "Original"
    case medium = "MidThumb"
    case fast = "Thumbnail"
}

public enum Commands {
    public static func getCameraStatus() -> [String: String] {
        ["command": "GetCameraStatus"]
    }

    public static func rcStartRemoteCtl() -> [String: String] {
        ["command": "RCStartRemoteCtl"]
    }

    public static func rcStopRemoteCtl() -> [String: String] {
        ["command": "RCStopRemoteCtl"]
    }

    public static func rcDoShooting() -> [String: String] {
        ["command": "RCDoShooting"]
    }

    public static func videoRecordingStart() -> [String: String] {
        ["command": "VideoRecordingStart"]
    }

    public static func videoRecordingStop() -> [String: String] {
        ["command": "VideoRecordingStop"]
    }

    /// RCDoFocus - .auto sends no coordinates; .manual sends image-pixel Posx/Posy as strings.
    /// NOTE (unverified, see DEVELOPMENT_PLAN.md/macOS ARCHITECTURE.md): the Posx/Posy
    /// coordinate convention has never been confirmed live - it's assumed to be pixel
    /// coordinates in the live-view frame's own pixel space, not a percentage or sensor
    /// coordinates.
    public static func rcDoFocus(mode: TriggerFocusMode, imagePoint: (x: Int, y: Int)? = nil) -> [String: String] {
        switch mode {
        case .auto:
            return ["command": "RCDoFocus", "Mode": "Auto"]
        case .manual:
            let p = imagePoint ?? (0, 0)
            return ["command": "RCDoFocus", "Mode": "Manual", "Posx": String(p.x), "Posy": String(p.y)]
        }
    }

    /// GetFileList - id_end must NOT be left at 0 (bug #11, macOS ARCHITECTURE.md): a
    /// zero-width range (0..0) is rejected by the camera itself with
    /// {"code":1502,"data":"get filelist err"}. filetype and RC-session state don't matter
    /// (confirmed live) - always use a generously large range.
    public static func getFileList(filetype: String = "all", rangeStart: Int = 0, rangeEnd: Int = 9999) -> [String: String] {
        ["command": "GetFileList", "range_start": String(rangeStart), "range_end": String(rangeEnd), "filetype": filetype]
    }

    /// GetFile - NOTE the API misspells "resolution" as "resulotion". Replicate exactly; this
    /// is not a typo to "fix", it's what the camera's firmware actually expects.
    public static func getFile(path: String, quality: FileQuality) -> [String: String] {
        ["command": "GetFile", "path": path, "resulotion": quality.rawValue]
    }

    /// DeleteFile's `file_list` is a JSON array, not a string - this is why every builder above
    /// technically returns `[String: String]` (a String-only dict is also a valid `[String:
    /// Any]`) while this one needs `[String: Any]`. HTTPClient.send(_:) accepts `[String: Any]`
    /// uniformly so callers don't need to special-case this.
    public static func deleteFile(paths: [String]) -> [String: Any] {
        ["command": "DeleteFile", "file_list": paths]
    }
}

/// Dead commands - confirmed via live testing to NOT work despite valid-looking handlers in the
/// firmware's dispatch table. Do not use; kept here as documentation so nobody re-guesses these.
/// See fable research/live-testing-findings.md sections 6-11 for the full evidence trail.
public enum DeadCommands {
    public static let names = [
        "RCVideoFormatSet", "RCVASwitchSet", "RCVAVolSet", "RCVANoiseReduceSet", "RCEisSwitchSet",
        "StartMovieStream", // PauseMovieStream/ResumeMovieStream/StopMovieStream return 200 but
                            // are functionally inert (proven: neither live view nor an actual
                            // recording's duration changed) - also do not use.
    ]
}
