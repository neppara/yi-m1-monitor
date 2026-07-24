// UI-friendly display labels for setting values - exact port of
// yi-m1-remote-control/app/main_window.py's _PRETTY_LABELS / _display_label (2026-07-07).
//
// This ONLY affects what's displayed. The wire value sent to the camera (SettingValue.rawValue)
// is never touched by this - see CameraSettings.swift's `command()`.
import Foundation

public enum PrettyLabel {
    private static let explicitMaps: [SettingKey: [String: String]] = [
        .exposureMode: ["Auto": "Auto", "P": "Program", "A": "Aperture", "S": "Shutter",
                        "M": "Manual", "C": "Master"],
        .meteringMode: ["Multi": "Multi", "Spot": "Spot", "CenterWeighted": "Center"],
        .focusMode: ["C-AF": "C-AF", "S-AF": "S-AF", "MF": "Manual"],
        .fileFormat: ["RAW": "RAW", "JPG-S": "JPEG S", "JPG-M": "JPEG M", "JPG-L": "JPEG L",
                      "RAWJ-S": "RAW+S", "RAWJ-M": "RAW+M", "RAWJ-L": "RAW+L"],
        .driveMode: ["Single": "Single", "Continuous": "Continuous",
                     "2SDelay": "2s timer", "10SDelay": "10s timer"],
        .colorMode: ["Standard": "Standard", "Portrait": "Portrait", "Vivid": "Vivid",
                     "NaturalBW": "B&W soft", "HContrastBW": "B&W hard"],
        // The star marks the two modes that exist ONLY through RCVideoFormatSet - the camera's
        // own menus never offer 24p.
        .videoFormat: ["4K_30": "4K 30p", "4K_24": "4K 24p \u{2605}", "4K_30_LOW": "4K 30p (low)",
                       "2K_30": "2K 30p", "FHD_60": "1080 60p", "FHD_30": "1080 30p",
                       "FHD_24": "1080 24p \u{2605}",
                       "720P_60": "720 60p", "720P_30": "720 30p", "720P_24": "720 24p",
                       "VGA_240": "240fps slow-mo \u{2605}"],
        .videoEis: ["ON": "On", "OFF": "Off"],
        .audioSwitch: ["ON": "On", "OFF": "Off"],
        .audioNoiseReduce: ["ON": "On", "OFF": "Off"],
    ]

    /// Map a raw API value to a readable label for the given setting. Display only - see file
    /// header. Mirrors main_window.py's _display_label exactly, including its quirks (e.g. EV
    /// values starting with "0" don't get a "+" prefix, matching the Python `str.startswith`
    /// check character-for-character).
    public static func prettyLabel(for key: SettingKey, rawValue: String) -> String {
        if let explicit = explicitMaps[key]?[rawValue] {
            return explicit
        }
        switch key {
        case .fNumber:
            return "f/" + rawValue
        case .ev:
            return (rawValue.hasPrefix("-") || rawValue.hasPrefix("0")) ? rawValue : "+" + rawValue
        case .whiteBalance:
            return isAllDigits(rawValue) ? rawValue + "K" : rawValue
        case .imageQuality:
            return isAllDigits(rawValue) ? rawValue + " MP" : rawValue
        default:
            return rawValue
        }
    }

    private static func isAllDigits(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy(\.isNumber)
    }
}
