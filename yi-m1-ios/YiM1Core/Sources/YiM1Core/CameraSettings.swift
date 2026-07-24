// Camera setting enums - exact port of
// yi-m1-remote-control/prot_http/const_http_cmd_rc_params.py
//
// Every `rawValue` is the literal string the camera's HTTP API expects/reports - do not
// "clean up" or reformat these; they were confirmed working live against the real camera.
// `SettingKey.rawValue` equals the live-view metadata JSON field name (see CameraMetadata.swift)
// so the same key both reads the current value and identifies the write command.
import Foundation

/// Identifies a settable camera parameter. rawValue == the metadata field name reported in the
/// live-view UDP header (see CameraMetadata.swift), which is deliberately NOT always the same
/// as the HTTP param name used to *write* the setting (see `SettingValue.paramName` below -
/// ExposureMode is the one exception: metadata key "ExposureMode", write param "DialMode").
public enum SettingKey: String, CaseIterable, Sendable {
    case exposureMode = "ExposureMode"
    case meteringMode = "MeteringMode"
    case focusMode = "FocusMode"
    case imageQuality = "ImageQuality"
    case imageAspect = "ImageAspect"
    case fileFormat = "FileFormat"
    case driveMode = "DriveMode"
    case fNumber = "Fnumber"
    case shutterSpeed = "ShutterSpeed"
    case ev = "EV"
    case iso = "ISOSetting"
    case whiteBalance = "WB"
    case colorMode = "ColorMode"
    case videoFormat = "VideoFormat"
    case videoEis = "VideoEis"
    case audioSwitch = "VASwitch"
    case audioNoiseReduce = "VANR"
    case audioVolume = "VAVol"
}

/// A settable camera value. `rawValue` is the exact API string; `command()` builds the
/// `{"command": ..., <param>: <value>}` dict RCCmdSet* sends. `displayLabel` is UI-only - the
/// wire value is never affected by it (see PrettyLabel.swift).
public protocol SettingValue: RawRepresentable, CaseIterable, Sendable where RawValue == String {
    static var settingKey: SettingKey { get }
    static var commandName: String { get }
    static var paramName: String { get }
}

public extension SettingValue {
    /// Command dict to send over HTTP, e.g. {"command":"RCISOSet","ISO":"800"}.
    func command() -> [String: String] {
        ["command": Self.commandName, Self.paramName: rawValue]
    }

    /// UI-friendly label - see PrettyLabel.prettyLabel(for:rawValue:).
    var displayLabel: String {
        PrettyLabel.prettyLabel(for: Self.settingKey, rawValue: rawValue)
    }
}

// MARK: - RCSwitchDialMode {DialMode} (note: metadata key "ExposureMode" != param "DialMode")

public enum ExposureMode: String, SettingValue {
    case auto = "Auto", program = "P", aperturePriority = "A", shutterPriority = "S", manual = "M", masterGuide = "C"
    public static let settingKey = SettingKey.exposureMode
    public static let commandName = "RCSwitchDialMode"
    public static let paramName = "DialMode"
}

// MARK: - RCMeteringModeSet {MeteringMode}

public enum MeteringMode: String, SettingValue {
    case multi = "Multi", spot = "Spot", centerWeighted = "CenterWeighted"
    public static let settingKey = SettingKey.meteringMode
    public static let commandName = "RCMeteringModeSet"
    public static let paramName = "MeteringMode"
}

// MARK: - RCFocusModeSet {FocusMode}

public enum FocusMode: String, SettingValue {
    case contrastAutofocus = "C-AF", singleAreaAutofocus = "S-AF", manualFocus = "MF"
    public static let settingKey = SettingKey.focusMode
    public static let commandName = "RCFocusModeSet"
    public static let paramName = "FocusMode"
}

/// Not a settings-strip entry (used only by RCDoFocus, see Commands.swift), kept separate from
/// FocusMode (the "current focus mode" setting) intentionally - the Python code keeps them as
/// two different enums too (RcFocusMode vs RcTriggerFocusMode).
/// Video resolution / frame rate, sent as RCVideoFormatSet's "Resolution" parameter.
///
/// The parameter name is the whole story here. It is NOT "VideoFormat" - that is only what the
/// live-view *metadata* field is called, and guessing it (plus "Value" and "Mode") is why this
/// command was written off as "returns 404, unreachable" for so long. The real key, "Resolution",
/// was read out of the firmware handler at 0x0015641c; all seven values below then came straight
/// from .rodata and every one was accepted by a real camera on 2026-07-24. FHD_24 and FHD_30
/// were additionally verified end to end with ffprobe on the recorded files (24000/1001 and
/// 30000/1001). See 'fable research/rcvideoformatset-solved.md'.
///
/// uhd24 and fhd24 are worth calling out: 24p appears in NO menu on the camera body and was
/// never supported by the official app. It is reachable only through this command.
public enum VideoFormat: String, SettingValue {
    case uhd30 = "4K_30"
    case uhd24 = "4K_24"
    case uhd30Low = "4K_30_LOW"
    case qhd30 = "2K_30"
    case fhd60 = "FHD_60"
    case fhd30 = "FHD_30"
    case fhd24 = "FHD_24"
    // Confirmed live 2026-07-24: accepted AND echoed back by the live-view metadata.
    case hd60 = "720P_60"
    case hd30 = "720P_30"
    case hd24 = "720P_24"
    /// SLOW MOTION. The camera captures at ~240 fps and conforms it to a 30 fps file itself: a
    /// 3-second recording produced a 23-second, 690-frame 640x480 clip - roughly 8x slow motion,
    /// verified with ffprobe. The YI M1 officially has no slow-motion mode; this was in the
    /// firmware all along.
    case vga240 = "VGA_240"
    // DELIBERATELY ABSENT - do not "restore" these: "2880_24" and "1920_24" return HTTP 200 but
    // the metadata never changes, i.e. the camera does not apply them. Almost certainly leftovers
    // of the multi-product Xacti ASDK platform, like StartMovieStream. Plain "VGA" 404s.
    public static let settingKey = SettingKey.videoFormat
    public static let commandName = "RCVideoFormatSet"
    public static let paramName = "Resolution"
}

/// Shared value type for the three video switches. UPPERCASE, and that matters: the strings live
/// at 0x1540f0 / 0x1540f4 in the firmware and the handlers compare against them directly.
/// "On"/"Off" would 404 - the exact trap that kept these commands filed as "dead" for years.
public enum OnOff: String, SettingValue {
    case on = "ON", off = "OFF"
    public static let settingKey = SettingKey.videoEis
    public static let commandName = "RCEisSwitchSet"
    public static let paramName = "Operate"
}

/// Microphone level. "50" is confirmed live (metadata echoed VAVol="50"); the rest of the scale
/// is a reasonable 0-100 spread and is NOT individually verified.
public enum AudioVolume: String, SettingValue {
    case v0 = "0", v25 = "25", v50 = "50", v75 = "75", v100 = "100"
    public static let settingKey = SettingKey.audioVolume
    public static let commandName = "RCVAVolSet"
    public static let paramName = "Vol"
}

public enum TriggerFocusMode: String, Sendable {
    case auto = "Auto"
    case manual = "Manual"
}

// MARK: - RCImageQualitySet {ImageQuality}

public enum ImageQuality: String, SettingValue {
    case mp50Interpolated = "50", mp20 = "20", mp16 = "16", mp8 = "8", mp3 = "3", vga = "VGA"
    public static let settingKey = SettingKey.imageQuality
    public static let commandName = "RCImageQualitySet"
    public static let paramName = "ImageQuality"
}

// MARK: - RCImageAspect {ImageAspect}
//
// IMPORTANT (bug #12, macOS ARCHITECTURE.md): the live-view metadata's ImageAspect field has
// been observed to ALWAYS report "4:3" regardless of what's actually set. RCImageAspect itself
// is confirmed to genuinely work (proven by the tripod crop measurements). Any UI syncing
// against metadata for this key must trust the last user request indefinitely rather than
// reverting when metadata never confirms it - see CameraSession's pending-value logic, which
// treats `.imageAspect` as a "never expire" key (mirrors macOS NEVER_EXPIRE_METADATA_KEYS).

public enum ImageAspect: String, SettingValue {
    case a43 = "4:3", a32 = "3:2", widescreen = "16:9", square = "1:1"
    public static let settingKey = SettingKey.imageAspect
    public static let commandName = "RCImageAspect"
    public static let paramName = "ImageAspect"
}

// MARK: - RCFileFormatSet {FileFormat}

public enum FileFormat: String, SettingValue {
    case raw = "RAW"
    case jpegSmall = "JPG-S", jpegMedium = "JPG-M", jpegLarge = "JPG-L"
    case rawAndJpegSmall = "RAWJ-S", rawAndJpegMedium = "RAWJ-M", rawAndJpegLarge = "RAWJ-L"
    public static let settingKey = SettingKey.fileFormat
    public static let commandName = "RCFileFormatSet"
    public static let paramName = "FileFormat"
}

// MARK: - RCDriveModeSet {DriveMode}

public enum DriveMode: String, SettingValue {
    case single = "Single", continuous = "Continuous", delay2s = "2SDelay", delay10s = "10SDelay"
    public static let settingKey = SettingKey.driveMode
    public static let commandName = "RCDriveModeSet"
    public static let paramName = "DriveMode"
}

// MARK: - RCFNSet {Fnumber} (aperture)

public enum FStop: String, SettingValue, CaseIterable {
    case f1_0 = "1.0", f1_2 = "1.2", f1_4 = "1.4", f1_7 = "1.7", f1_8 = "1.8"
    case f2_0 = "2.0", f2_2 = "2.2", f2_5 = "2.5", f2_8 = "2.8"
    case f3_2 = "3.2", f3_5 = "3.5"
    case f4_0 = "4.0", f4_5 = "4.5"
    case f5_0 = "5.0", f5_6 = "5.6"
    case f6_3 = "6.3"
    case f7_1 = "7.1"
    case f8_0 = "8.0"
    case f9_0 = "9.0"
    case f10 = "10", f11 = "11", f13 = "13", f14 = "14", f16 = "16", f18 = "18"
    case f20 = "20", f22 = "22", f25 = "25", f29 = "29", f32 = "32"
    public static let settingKey = SettingKey.fNumber
    public static let commandName = "RCFNSet"
    public static let paramName = "Fnumber"
}

// MARK: - RCShutterSpeedSet {ShutterSpeed}

public enum ShutterSpeed: String, SettingValue, CaseIterable {
    case time = "TIME", bulb = "BULB"
    // Long exposures (seconds)
    case s60 = "60s", s50 = "50s", s40 = "40s", s30 = "30s", s25 = "25s", s20 = "20s"
    case s15 = "15s", s13 = "13s", s10 = "10s", s8 = "8s", s6 = "6s", s5 = "5s", s4 = "4s"
    case s3_2 = "3.2s", s2_5 = "2.5s", s2 = "2s", s1_6 = "1.6s", s1_3 = "1.3s", s1 = "1s"
    // Fast shutter (fractions of a second)
    case sf1_3 = "1/1.3s", sf1_6 = "1/1.6s", sf2 = "1/2s", sf2_5 = "1/2.5s", sf3 = "1/3s"
    case sf4 = "1/4s", sf5 = "1/5s", sf6 = "1/6s", sf8 = "1/8s", sf10 = "1/10s"
    case sf13 = "1/13s", sf15 = "1/15s", sf20 = "1/20s", sf25 = "1/25s", sf30 = "1/30s"
    case sf40 = "1/40s", sf50 = "1/50s", sf60 = "1/60s", sf80 = "1/80s", sf100 = "1/100s"
    case sf125 = "1/125s", sf160 = "1/160s", sf200 = "1/200s", sf250 = "1/250s", sf320 = "1/320s"
    case sf400 = "1/400s", sf500 = "1/500s", sf640 = "1/640s", sf800 = "1/800s", sf1000 = "1/1000s"
    case sf1250 = "1/1250s", sf1600 = "1/1600s", sf2000 = "1/2000s", sf2500 = "1/2500s"
    case sf3200 = "1/3200s", sf4000 = "1/4000s"
    public static let settingKey = SettingKey.shutterSpeed
    public static let commandName = "RCShutterSpeedSet"
    public static let paramName = "ShutterSpeed"
}

// MARK: - RCEVSet {EV}

public enum EvOffset: String, SettingValue, CaseIterable {
    case n5_0 = "-5.0", n4_7 = "-4.7", n4_3 = "-4.3", n4_0 = "-4.0", n3_7 = "-3.7", n3_3 = "-3.3"
    case n3_0 = "-3.0", n2_7 = "-2.7", n2_3 = "-2.3", n2_0 = "-2.0", n1_7 = "-1.7", n1_3 = "-1.3"
    case n1_0 = "-1.0", n0_7 = "-0.7", n0_3 = "-0.3"
    case zero = "0.0"
    case p0_3 = "0.3", p0_7 = "0.7", p1_0 = "1.0", p1_3 = "1.3", p1_7 = "1.7", p2_0 = "2.0"
    case p2_3 = "2.3", p2_7 = "2.7", p3_0 = "3.0", p3_3 = "3.3", p3_7 = "3.7", p4_0 = "4.0"
    case p4_3 = "4.3", p4_7 = "4.7", p5_0 = "5.0"
    public static let settingKey = SettingKey.ev
    public static let commandName = "RCEVSet"
    public static let paramName = "EV"
}

// MARK: - RCISOSet {ISO}

public enum Iso: String, SettingValue {
    case auto = "Auto"
    case i100 = "100", i200 = "200", i400 = "400", i800 = "800", i1600 = "1600"
    case i3200 = "3200", i6400 = "6400", i12800 = "12800", i25600 = "25600"
    public static let settingKey = SettingKey.iso
    public static let commandName = "RCISOSet"
    public static let paramName = "ISO"
}

// MARK: - RCWBSet {WB}

public enum WhiteBalance: String, SettingValue, CaseIterable {
    case auto = "Auto", sunny = "Sunny", cloudy = "Cloudy", shadow = "Shadow", incandescent = "Incandescent"
    case k2000 = "2000", k2050 = "2050", k2100 = "2100", k2150 = "2150", k2200 = "2200", k2250 = "2250"
    case k2300 = "2300", k2350 = "2350", k2400 = "2400", k2450 = "2450", k2500 = "2500", k2550 = "2550"
    case k2600 = "2600", k2650 = "2650", k2700 = "2700", k2750 = "2750", k2800 = "2800", k2850 = "2850"
    case k2900 = "2900", k2950 = "2950", k3000 = "3000", k3100 = "3100", k3200 = "3200", k3300 = "3300"
    case k3400 = "3400", k3500 = "3500", k3600 = "3600", k3700 = "3700", k3800 = "3800", k3900 = "3900"
    case k4000 = "4000", k4200 = "4200", k4400 = "4400", k4600 = "4600", k4800 = "4800", k5000 = "5000"
    case k5200 = "5200", k5400 = "5400", k5600 = "5600", k5800 = "5800", k6000 = "6000", k6200 = "6200"
    case k6400 = "6400", k6600 = "6600", k6800 = "6800", k7000 = "7000", k7500 = "7500", k8000 = "8000"
    case k8500 = "8500", k9000 = "9000", k9500 = "9500", k10000 = "10000", k10500 = "10500"
    case k11000 = "11000", k11500 = "11500"
    public static let settingKey = SettingKey.whiteBalance
    public static let commandName = "RCWBSet"
    public static let paramName = "WB"
}

// MARK: - RCChooseColorMode {ColorMode}

public enum ColorStyle: String, SettingValue {
    case standard = "Standard", portrait = "Portrait", vivid = "Vivid"
    case naturalBW = "NaturalBW", highContrastBW = "HContrastBW"
    public static let settingKey = SettingKey.colorMode
    public static let commandName = "RCChooseColorMode"
    public static let paramName = "ColorMode"
}
