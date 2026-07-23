import XCTest
@testable import YiM1Core

final class CameraMetadataTests: XCTestCase {
    // Real captured metadata sample (see fable research/wifi-experiment-results/run_20260702_232157/
    // frame_001_232158.txt) - the exact JSON that was directly observed embedded in a live-view
    // UDP frame's first 2048 bytes.
    private let sampleJSON = """
    {"ExposureMode":"S","MeteringMode":"CenterWeighted","ImageQuality":"20","ImageAspect":"4:3","DriveMode":"Single","DelayShootCnt":"1","FileFormat":"RAWJ-L","Fnumber":"0.0","FnumberMin":"0.0","FnumberMax":"0.0","ShutterSpeed":"1/50s","EV":"0.0","ISOSetting":"200","ISOAutoValue":"200","WB":"Cloudy","ColorMode":"Standard","LensStatus":"0","BatteryLevel":"75","FocusMode":"MF","FocusSupport":"1","VideoFormat":"FHD_30","VASwitch":"ON","VAVol":"5","VANR":"OFF","VideoEis":"OFF","SurplusPhotoCnts":"691"}
    """

    private func paddedHeader(_ json: String) -> Data {
        var data = Data(json.utf8)
        data.append(Data(repeating: 0, count: 2048 - data.count))
        return data
    }

    func testParsesRealCapturedFrame() throws {
        let header = paddedHeader(sampleJSON)
        let metadata = try XCTUnwrap(CameraMetadata.parse(headerBytes: header))
        XCTAssertEqual(metadata[.iso], "200")
        XCTAssertEqual(metadata[.exposureMode], "S")
        XCTAssertEqual(metadata[.whiteBalance], "Cloudy")
        XCTAssertEqual(metadata.videoFormat, "FHD_30")
        XCTAssertEqual(metadata.videoAudioSwitch, "ON")
        XCTAssertEqual(metadata.videoEis, "OFF")
    }

    func testGarbageHeaderReturnsNilNotCrash() {
        let garbage = Data(repeating: 0xFF, count: 2048)
        XCTAssertNil(CameraMetadata.parse(headerBytes: garbage))
    }

    func testAllZeroHeaderReturnsNil() {
        XCTAssertNil(CameraMetadata.parse(headerBytes: Data(repeating: 0, count: 2048)))
    }

    func testCameraStatusParsing() throws {
        let body = Data("""
        {"code":200,"data":{"batteryLevel":"50","SurplusPhotoCnts":"1119","lenVer":"0.0","lenType":""}}
        """.utf8)
        let status = try XCTUnwrap(CameraStatus.parse(responseBody: body))
        XCTAssertEqual(status.batteryLevel, "50")
        XCTAssertEqual(status.shotsLeft, "1119")
    }
}
