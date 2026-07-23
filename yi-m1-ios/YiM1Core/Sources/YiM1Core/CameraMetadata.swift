// Parses the JSON header embedded in the first 2048 bytes of every reassembled live-view UDP
// frame - port of yi-m1-remote-control/app/camera_session.py's _parse_live_metadata.
//
// Confirmed real fields (fable research/live-testing-findings.md, 2026-07-02/07): ExposureMode,
// MeteringMode, ImageQuality, ImageAspect, DriveMode, FileFormat, Fnumber(+Min/Max), EV,
// ISOSetting(+ISOAutoValue), WB, ColorMode, LensStatus, BatteryLevel, FocusMode, FocusSupport,
// VideoFormat, VASwitch, VAVol, VANR, VideoEis, SurplusPhotoCnts. Not every field is modeled
// below as a typed property - only the ones the UI needs; `raw` keeps everything for anything
// else (and for forward-compatibility if the firmware adds fields).
import Foundation

public struct CameraMetadata: Sendable {
    public let raw: [String: String]

    public init(raw: [String: String]) {
        self.raw = raw
    }

    /// Read a setting's current value by its SettingKey (which equals the metadata field name -
    /// see CameraSettings.swift). IMPORTANT: `.imageAspect` is confirmed unreliable (bug #12) -
    /// it appears to always report "4:3" regardless of the real setting. Don't use this to
    /// force-revert UI state for that key; see CameraSession's pending-value logic.
    public subscript(key: SettingKey) -> String? {
        raw[key.rawValue]
    }

    public var videoFormat: String? { raw["VideoFormat"] }
    public var videoAudioSwitch: String? { raw["VASwitch"] }
    public var videoEis: String? { raw["VideoEis"] }

    /// Parses the fixed 2048-byte, null-padded JSON header. Returns nil (not a throwing
    /// function - a bad/corrupt header is an expected, non-fatal occurrence per live testing,
    /// not a programmer error) if the bytes aren't valid JSON after trimming at the first NUL.
    public static func parse(headerBytes: Data) -> CameraMetadata? {
        // Find the first NUL byte (the header is null-padded to fill exactly 2048 bytes).
        let trimmed: Data
        if let nulIndex = headerBytes.firstIndex(of: 0) {
            trimmed = headerBytes[headerBytes.startIndex..<nulIndex]
        } else {
            trimmed = headerBytes
        }
        guard !trimmed.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: trimmed) as? [String: Any] else {
            return nil
        }
        // All values in the real payload are JSON strings (even numeric-looking ones like
        // "200" or "75") - stringify defensively in case a future firmware sends a bare number.
        var stringMap: [String: String] = [:]
        for (k, v) in obj {
            if let s = v as? String {
                stringMap[k] = s
            } else {
                stringMap[k] = "\(v)"
            }
        }
        return CameraMetadata(raw: stringMap)
    }
}

public struct CameraStatus: Sendable, Equatable {
    public let batteryLevel: String
    public let shotsLeft: String
    public let lensVersion: String
    public let lensType: String

    public init(batteryLevel: String, shotsLeft: String, lensVersion: String, lensType: String) {
        self.batteryLevel = batteryLevel
        self.shotsLeft = shotsLeft
        self.lensVersion = lensVersion
        self.lensType = lensType
    }

    /// Parses a GetCameraStatus response body, e.g.
    /// {"code":200,"data":{"batteryLevel":"50","SurplusPhotoCnts":"1119","lenVer":"0.0","lenType":""}}
    public static func parse(responseBody: Data) -> CameraStatus? {
        guard let obj = try? JSONSerialization.jsonObject(with: responseBody) as? [String: Any],
              let data = obj["data"] as? [String: Any] else {
            return nil
        }
        return CameraStatus(
            batteryLevel: (data["batteryLevel"] as? String) ?? "?",
            shotsLeft: (data["SurplusPhotoCnts"] as? String) ?? "?",
            lensVersion: (data["lenVer"] as? String) ?? "",
            lensType: (data["lenType"] as? String) ?? ""
        )
    }
}
