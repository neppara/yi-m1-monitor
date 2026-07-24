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

    /// All seven strings exist in the firmware's .rodata and all seven were accepted by the
    /// camera. Order matters only for the picker; membership is the real assertion.
    func testAllSevenFirmwareValuesArePresent() {
        XCTAssertEqual(Set(VideoFormat.allCases.map(\.rawValue)),
                       ["4K_30", "4K_24", "4K_30_LOW", "2K_30", "FHD_60", "FHD_30", "FHD_24"])
    }

    /// 24p is the headline capability - it appears in no menu on the camera body and was never
    /// supported by the official app.
    func testTwentyFourPModesExist() {
        XCTAssertTrue(VideoFormat.allCases.contains(.uhd24))
        XCTAssertTrue(VideoFormat.allCases.contains(.fhd24))
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
        XCTAssertTrue(PrettyLabel.prettyLabel(for: .videoFormat, rawValue: "4K_24").contains("★"))
    }

    /// The auto-restart tier is chosen by prefix-matching the metadata string, so a format the
    /// user can now select from the app must still land on the right timer.
    func testNewlySelectableFormatsStillPickARestartTier() {
        XCTAssertEqual(RecordingAutoRestart.restartInterval(forVideoFormat: "4K_24"),
                       RecordingAutoRestart.restartInterval(forVideoFormat: "4K_30"))
        XCTAssertEqual(RecordingAutoRestart.restartInterval(forVideoFormat: "4K_30_LOW"),
                       RecordingAutoRestart.restartInterval(forVideoFormat: "4K_30"))
        // FHD_60 falls through to the FHD tier. That tier is UNMEASURED for 60p - see the note
        // in RecordingAutoRestart; the fps self-stop detector is the safety net if it is wrong.
        XCTAssertEqual(RecordingAutoRestart.restartInterval(forVideoFormat: "FHD_60"),
                       RecordingAutoRestart.restartInterval(forVideoFormat: "FHD_30"))
    }
}
