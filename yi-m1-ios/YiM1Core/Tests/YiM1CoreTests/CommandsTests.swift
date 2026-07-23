import XCTest
@testable import YiM1Core

final class CommandsTests: XCTestCase {
    func testBareCommands() {
        XCTAssertEqual(Commands.getCameraStatus(), ["command": "GetCameraStatus"])
        XCTAssertEqual(Commands.rcStartRemoteCtl(), ["command": "RCStartRemoteCtl"])
        XCTAssertEqual(Commands.rcStopRemoteCtl(), ["command": "RCStopRemoteCtl"])
        XCTAssertEqual(Commands.rcDoShooting(), ["command": "RCDoShooting"])
        XCTAssertEqual(Commands.videoRecordingStart(), ["command": "VideoRecordingStart"])
        XCTAssertEqual(Commands.videoRecordingStop(), ["command": "VideoRecordingStop"])
    }

    func testRcDoFocus() {
        XCTAssertEqual(Commands.rcDoFocus(mode: .auto), ["command": "RCDoFocus", "Mode": "Auto"])
        XCTAssertEqual(
            Commands.rcDoFocus(mode: .manual, imagePoint: (400, 300)),
            ["command": "RCDoFocus", "Mode": "Manual", "Posx": "400", "Posy": "300"]
        )
    }

    func testGetFileListDefaultsToNonZeroRange() {
        // Bug #11 (macOS ARCHITECTURE.md): id_end must NOT be 0, or the camera returns
        // {"code":1502,...}. The default here must never regress to a zero-width range.
        let cmd = Commands.getFileList()
        XCTAssertEqual(cmd["range_start"], "0")
        XCTAssertEqual(cmd["range_end"], "9999")
        XCTAssertNotEqual(cmd["range_end"], "0")
        XCTAssertEqual(cmd["filetype"], "all")
    }

    func testGetFileUsesMisspelledResolutionParam() {
        // NOT a typo - the camera's actual API expects "resulotion". See Commands.swift comment.
        let cmd = Commands.getFile(path: "/DCIM/100YICAM/P1.DNG", quality: .medium)
        XCTAssertEqual(cmd["resulotion"], "MidThumb")
        XCTAssertNil(cmd["resolution"])
    }

    func testDeleteFileHasArrayValue() {
        let cmd = Commands.deleteFile(paths: ["/DCIM/100YICAM/P1.DNG", "/DCIM/100YICAM/P2.DNG"])
        XCTAssertEqual(cmd["command"] as? String, "DeleteFile")
        XCTAssertEqual(cmd["file_list"] as? [String], ["/DCIM/100YICAM/P1.DNG", "/DCIM/100YICAM/P2.DNG"])
    }

    func testSettingCommandsMatchPythonWireFormat() {
        XCTAssertEqual(Iso.i800.command(), ["command": "RCISOSet", "ISO": "800"])
        XCTAssertEqual(ExposureMode.manual.command(), ["command": "RCSwitchDialMode", "DialMode": "M"])
        XCTAssertEqual(ImageAspect.widescreen.command(), ["command": "RCImageAspect", "ImageAspect": "16:9"])
        XCTAssertEqual(FStop.f1_4.command(), ["command": "RCFNSet", "Fnumber": "1.4"])
        XCTAssertEqual(ColorStyle.naturalBW.command(), ["command": "RCChooseColorMode", "ColorMode": "NaturalBW"])
        XCTAssertEqual(WhiteBalance.k5000.command(), ["command": "RCWBSet", "WB": "5000"])
    }

    func testDeadCommandsAreDocumentedNotUsed() {
        XCTAssertTrue(DeadCommands.names.contains("RCVideoFormatSet"))
        XCTAssertTrue(DeadCommands.names.contains("StartMovieStream"))
    }
}
