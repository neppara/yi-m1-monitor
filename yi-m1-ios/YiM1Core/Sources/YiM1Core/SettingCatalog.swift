// Bridges the generic, per-enum SettingValue types (CameraSettings.swift) with the
// SettingKey-based API used by CameraSession/Views (see DEVELOPMENT_PLAN.md Part 3's
// `CameraSessionProtocol`). This lets the UI work generically off a SettingKey without needing
// generics/type erasure at every call site - the concrete enum's static properties remain the
// single source of truth; this just aggregates them into lookup tables.
import Foundation

public struct SettingOption: Sendable, Equatable, Identifiable {
    public var id: String { rawValue }
    public let rawValue: String
    public let displayLabel: String
}

public enum SettingCatalog {
    /// commandName/paramName per key, e.g. .iso -> ("RCISOSet", "ISO"). Derived directly from
    /// each enum's static properties - see CameraSettings.swift.
    public static let commandInfo: [SettingKey: (commandName: String, paramName: String)] = [
        .exposureMode: (ExposureMode.commandName, ExposureMode.paramName),
        .meteringMode: (MeteringMode.commandName, MeteringMode.paramName),
        .focusMode: (FocusMode.commandName, FocusMode.paramName),
        .imageQuality: (ImageQuality.commandName, ImageQuality.paramName),
        .imageAspect: (ImageAspect.commandName, ImageAspect.paramName),
        .fileFormat: (FileFormat.commandName, FileFormat.paramName),
        .driveMode: (DriveMode.commandName, DriveMode.paramName),
        .fNumber: (FStop.commandName, FStop.paramName),
        .shutterSpeed: (ShutterSpeed.commandName, ShutterSpeed.paramName),
        .ev: (EvOffset.commandName, EvOffset.paramName),
        .iso: (Iso.commandName, Iso.paramName),
        .whiteBalance: (WhiteBalance.commandName, WhiteBalance.paramName),
        .colorMode: (ColorStyle.commandName, ColorStyle.paramName),
        .videoFormat: (VideoFormat.commandName, VideoFormat.paramName),
    ]

    /// Builds the full command dict for a setting, e.g. (.iso, "800") -> {"command":"RCISOSet","ISO":"800"}.
    public static func command(for key: SettingKey, rawValue: String) -> [String: String]? {
        guard let info = commandInfo[key] else { return nil }
        return ["command": info.commandName, info.paramName: rawValue]
    }

    /// All selectable options for a setting, in enum-declaration order (parity with the macOS
    /// combo boxes), each with its wire value + UI-friendly label.
    public static func options(for key: SettingKey) -> [SettingOption] {
        switch key {
        case .exposureMode: return ExposureMode.allCases.map { SettingOption(rawValue: $0.rawValue, displayLabel: $0.displayLabel) }
        case .meteringMode: return MeteringMode.allCases.map { SettingOption(rawValue: $0.rawValue, displayLabel: $0.displayLabel) }
        case .focusMode: return FocusMode.allCases.map { SettingOption(rawValue: $0.rawValue, displayLabel: $0.displayLabel) }
        case .imageQuality: return ImageQuality.allCases.map { SettingOption(rawValue: $0.rawValue, displayLabel: $0.displayLabel) }
        case .imageAspect: return ImageAspect.allCases.map { SettingOption(rawValue: $0.rawValue, displayLabel: $0.displayLabel) }
        case .fileFormat: return FileFormat.allCases.map { SettingOption(rawValue: $0.rawValue, displayLabel: $0.displayLabel) }
        case .driveMode: return DriveMode.allCases.map { SettingOption(rawValue: $0.rawValue, displayLabel: $0.displayLabel) }
        case .fNumber: return FStop.allCases.map { SettingOption(rawValue: $0.rawValue, displayLabel: $0.displayLabel) }
        case .shutterSpeed: return ShutterSpeed.allCases.map { SettingOption(rawValue: $0.rawValue, displayLabel: $0.displayLabel) }
        case .ev: return EvOffset.allCases.map { SettingOption(rawValue: $0.rawValue, displayLabel: $0.displayLabel) }
        case .iso: return Iso.allCases.map { SettingOption(rawValue: $0.rawValue, displayLabel: $0.displayLabel) }
        case .whiteBalance: return WhiteBalance.allCases.map { SettingOption(rawValue: $0.rawValue, displayLabel: $0.displayLabel) }
        case .colorMode: return ColorStyle.allCases.map { SettingOption(rawValue: $0.rawValue, displayLabel: $0.displayLabel) }
        case .videoFormat: return VideoFormat.allCases.map { SettingOption(rawValue: $0.rawValue, displayLabel: $0.displayLabel) }
        }
    }

    /// Settings shared between photo and video (confirmed via the NaturalBW video test - see
    /// fable research/live-testing-findings.md section 9), always shown regardless of mode.
    public static let sharedKeys: [SettingKey] = [
        .exposureMode, .iso, .shutterSpeed, .fNumber, .ev, .whiteBalance, .meteringMode, .focusMode, .colorMode,
    ]

    /// Photo-only settings (about the still file), shown only in Photo mode.
    public static let photoOnlyKeys: [SettingKey] = [.imageQuality, .imageAspect, .fileFormat, .driveMode]

    /// The mode-aware key list (shared + photo-only when in Photo mode) - factored out (I6,
    /// 2026-07-12) so both the portrait `SettingsStrip` and the landscape settings sheet build
    /// the identical list instead of duplicating the expression in two SwiftUI files.
    /// Video-only settings. `.videoFormat` became settable on 2026-07-24 once RCVideoFormatSet's
    /// real parameter key ("Resolution") was recovered from the firmware - before that it was a
    /// read-only metadata chip, because the command was believed to be unreachable. Audio and EIS
    /// stay read-only for now: their handlers exist too, but their parameter keys are still unknown.
    public static let videoOnlyKeys: [SettingKey] = [.videoFormat]

    public static func keys(forMode mode: CaptureMode) -> [SettingKey] {
        sharedKeys + (mode == .photo ? photoOnlyKeys : videoOnlyKeys)
    }
}
