import XCTest
@testable import YiM1Core

/// Guards the RCVideoFormatSet wiring. The whole point of these tests is the parameter NAME:
/// "Resolution", not "VideoFormat". The latter is what the live-view metadata field is called,
/// and confusing the two is exactly why this command was written off as unreachable for years
/// (see 'fable research/rcvideoformatset-solved.md'). If someone "tidies up" the param name to
/// match the metadata key, these tests fail loudly instead of the app silently 404-ing.
final class VideoFormatTests: XCTestCase {

    /// The exact request that was verified against a real camera on 2026-07-24, and whose
    /// resulting file ffprobe reported as 24000/1001 fps (96 frames in 4.004 s).
    func testCommandMatchesTheHardwareVerifiedRequest() {
        let command = SettingCatalog.command(for: .videoFormat, rawValue: VideoFormat.fhd24.rawValue)
        XCTAssertEqual(command, ["command": "RCVideoFormatSet", "Resolution": "FHD_24"])
    }

    func testParameterNameIsResolutionNotVideoFormat() {
        XCTAssertEqual(VideoFormat.paramName, "Resolution")
        XCTAssertNotEqual(VideoFormat.paramName, "VideoFormat",
                          "\"VideoFormat\" is the METADATA field name; sending it as the parameter returns 404.")
        XCTAssertEqual(VideoFormat.commandName, "RCVideoFormatSet")
    }

    /// Every mode the shipping picker offers, and nothing else. All eleven were accepted by a real
    /// camera; the four 720p/slow-motion entries were added after the 2026-07-24 hidden-value
    /// sweep. Membership is the assertion - order only affects how the picker reads.
    func testShippedFormatsAreExactlyTheHardwareConfirmedSet() {
        XCTAssertEqual(Set(VideoFormat.allCases.map(\.rawValue)),
                       ["4K_30", "2K_30",
                        "FHD_60", "FHD_30", "FHD_24",
                        "720P_60", "720P_30", "720P_24", "VGA_240"])
    }

    /// 1080p24 is the headline capability - no menu on the camera offers it. 4K_24 was found in
    /// the firmware but the camera reverts it to 4K_30 on record (hardware-verified), so it must
    /// NOT ship; 4K is locked to 30p.
    func testTwentyFourPIsFhdOnly() {
        XCTAssertTrue(VideoFormat.allCases.contains(.fhd24))
        XCTAssertFalse(VideoFormat.allCases.map(\.rawValue).contains("4K_24"),
                       "4K_24 is accepted but not applied - the camera reverts to 4K_30.")
        XCTAssertFalse(VideoFormat.allCases.map(\.rawValue).contains("4K_30_LOW"),
                       "4K_30_LOW is accepted but not applied - the camera reverts to 4K_30.")
    }

    func testEverySettingKeyResolvesToACommand() {
        for key in SettingKey.allCases {
            XCTAssertNotNil(SettingCatalog.commandInfo[key],
                            "\(key) has no command mapping - it would fail silently in the UI.")
            XCTAssertFalse(SettingCatalog.options(for: key).isEmpty,
                           "\(key) offers no options - its chip would open an empty picker.")
        }
    }

    /// Format belongs to Video mode only; putting it in the Photo strip would be misleading.
    func testFormatAppearsInVideoModeOnly() {
        XCTAssertTrue(SettingCatalog.keys(forMode: .video).contains(.videoFormat))
        XCTAssertFalse(SettingCatalog.keys(forMode: .photo).contains(.videoFormat))
    }

    func testLabelsMarkTheModesTheCameraMenuCannotReach() {
        XCTAssertEqual(PrettyLabel.prettyLabel(for: .videoFormat, rawValue: "FHD_30"), "1080 30p")
        XCTAssertTrue(PrettyLabel.prettyLabel(for: .videoFormat, rawValue: "FHD_24").contains("★"))
    }

    /// The auto-restart tier is chosen by prefix-matching the metadata string, so a format the
    /// user can now select from the app must still land on the right timer.
    func testNewlySelectableFormatsStillPickARestartTier() {
        // FHD_60 falls through to the FHD tier. That tier is UNMEASURED for 60p - see the note
        // in RecordingAutoRestart; the fps self-stop detector is the safety net if it is wrong.
        XCTAssertEqual(RecordingAutoRestart.restartInterval(forVideoFormat: "FHD_60"),
                       RecordingAutoRestart.restartInterval(forVideoFormat: "FHD_30"))
    }
}

/// The four commands that were filed as "dead - 404 despite a valid firmware handler" until the
/// parameter names were recovered on 2026-07-24. Each assertion below is the exact request that
/// a real camera accepted and echoed back through live-view metadata.
final class RevivedVideoCommandTests: XCTestCase {

    func testStabilisationUsesOperateWithUppercaseValues() {
        XCTAssertEqual(SettingCatalog.command(for: .videoEis, rawValue: "ON"),
                       ["command": "RCEisSwitchSet", "Operate": "ON"])
        XCTAssertEqual(SettingCatalog.command(for: .videoEis, rawValue: "OFF"),
                       ["command": "RCEisSwitchSet", "Operate": "OFF"])
    }

    func testAudioSwitchAndNoiseReductionShareTheOperateKey() {
        XCTAssertEqual(SettingCatalog.command(for: .audioSwitch, rawValue: "OFF"),
                       ["command": "RCVASwitchSet", "Operate": "OFF"])
        XCTAssertEqual(SettingCatalog.command(for: .audioNoiseReduce, rawValue: "ON"),
                       ["command": "RCVANoiseReduceSet", "Operate": "ON"])
    }

    func testMicLevelUsesVol() {
        XCTAssertEqual(SettingCatalog.command(for: .audioVolume, rawValue: "50"),
                       ["command": "RCVAVolSet", "Vol": "50"])
    }

    /// Lowercase "On"/"Off" 404s on the real camera - the firmware compares against uppercase
    /// literals at 0x1540f0/0x1540f4. Guard the casing explicitly.
    func testOnOffValuesAreUppercase() {
        XCTAssertEqual(Set(OnOff.allCases.map(\.rawValue)), ["ON", "OFF"])
    }

    /// 720p and the slow-motion mode were confirmed by metadata; the two that the camera accepted
    /// but never actually applied must stay out, or the picker would offer a mode that silently
    /// does nothing.
    func testOnlyHardwareConfirmedFormatsShip() {
        let values = Set(VideoFormat.allCases.map(\.rawValue))
        XCTAssertTrue(values.isSuperset(of: ["720P_60", "720P_30", "720P_24", "VGA_240"]))
        for reverted in ["2880_24", "1920_24", "4K_24", "4K_30_LOW"] {
            XCTAssertFalse(values.contains(reverted), "\(reverted): accepted but the camera reverts it")
        }
        XCTAssertFalse(values.contains("VGA"), "returns a plain 404")
    }

    func testSlowMotionIsLabelledSoItIsNotMistakenForAPlainVGAMode() {
        XCTAssertTrue(PrettyLabel.prettyLabel(for: .videoFormat, rawValue: "VGA_240")
                        .lowercased().contains("slow"))
    }

    func testEveryVideoOnlyKeyIsSettable() {
        for key in SettingCatalog.videoOnlyKeys {
            XCTAssertNotNil(SettingCatalog.commandInfo[key], "\(key) has no command mapping")
            XCTAssertFalse(SettingCatalog.options(for: key).isEmpty, "\(key) has no options")
        }
    }
}

/// The dial-mode list came from the inherited bullbin map and carried a value the camera does
/// not have. Pinned here so it cannot creep back.
final class ExposureModeValueTests: XCTestCase {

    /// The camera's own value table (.data 0xc09c2c68) reads exactly: Auto, P, A, S, M, Scene.
    func testDialModeMatchesTheCameraValueTable() {
        XCTAssertEqual(Set(ExposureMode.allCases.map(\.rawValue)),
                       ["Auto", "P", "A", "S", "M", "Scene"])
    }

    func testTheInventedCValueIsGone() {
        XCTAssertFalse(ExposureMode.allCases.map(\.rawValue).contains("C"),
                       "\"C\" is not in the camera's value table - it would be rejected.")
    }

    func testSceneBuildsTheRequestTheCameraAccepted() {
        XCTAssertEqual(SettingCatalog.command(for: .exposureMode, rawValue: "Scene"),
                       ["command": "RCSwitchDialMode", "DialMode": "Scene"])
    }
}
