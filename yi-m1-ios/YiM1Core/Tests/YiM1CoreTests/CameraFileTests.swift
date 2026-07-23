import XCTest
@testable import YiM1Core

final class CameraFileTests: XCTestCase {
    // Real captured response shape (2026-07-07, bug #11 in macOS ARCHITECTURE.md) - `data` is a
    // bare array, not nested under file_list/files/list.
    func testParsesRealResponseShape() throws {
        let body = Data("""
        {"code":200,"data":[
            {"path":"/DCIM/100YICAM/P5260258.JPG","date":"1779777547","filetype":"picture","protectStatus":false},
            {"path":"/DCIM/100YICAM/P7060642.MP4","date":"1783374739","filetype":"video","protectStatus":false},
            {"path":"/DCIM/100YICAM/P7060632.DNG","date":"1783374480","filetype":"raw","protectStatus":false}
        ]}
        """.utf8)
        guard case .ok(let files) = FileListResponse.parse(status: 200, body: body) else {
            XCTFail("expected .ok"); return
        }
        XCTAssertEqual(files.count, 3)
        XCTAssertEqual(files[0].filename, "P5260258.JPG")
        XCTAssertEqual(files[0].filetype, "picture")
        XCTAssertNotNil(files[0].date)
        XCTAssertFalse(files[0].isProtected)
    }

    func testCameraErrorCode1502() {
        // Bug #11: a zero-width range (range_end=0) triggers this camera-side error - this is
        // an HTTP 200 with an error *body*, not an HTTP error status, so it must NOT be silently
        // treated as success just because status==200.
        let body = Data("""
        {"code":1502,"data":"get filelist err"}
        """.utf8)
        guard case .unrecognized = FileListResponse.parse(status: 200, body: body) else {
            XCTFail("expected .unrecognized for the {code:1502} camera error shape"); return
        }
    }

    func testHTTPErrorStatus() {
        guard case .httpError(let status, _) = FileListResponse.parse(status: 404, body: Data()) else {
            XCTFail("expected .httpError"); return
        }
        XCTAssertEqual(status, 404)
    }

    func testEmptyFileList() {
        let body = Data(#"{"code":200,"data":[]}"#.utf8)
        guard case .ok(let files) = FileListResponse.parse(status: 200, body: body) else {
            XCTFail("expected .ok"); return
        }
        XCTAssertTrue(files.isEmpty)
    }
}
