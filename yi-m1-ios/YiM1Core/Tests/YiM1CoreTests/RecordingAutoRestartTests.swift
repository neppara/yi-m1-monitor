import XCTest
@testable import YiM1Core

final class RecordingAutoRestartTests: XCTestCase {
    func testRestartIntervalPicksFourKForPrefixedFormats() {
        XCTAssertEqual(RecordingAutoRestart.restartInterval(forVideoFormat: "4K_30"), RecordingAutoRestart.fourKRestartInterval)
        XCTAssertEqual(RecordingAutoRestart.restartInterval(forVideoFormat: "4K_24"), RecordingAutoRestart.fourKRestartInterval)
    }

    func testRestartIntervalPerFormatTiers() {
        XCTAssertEqual(RecordingAutoRestart.restartInterval(forVideoFormat: "FHD_30"), RecordingAutoRestart.fhdRestartInterval)
        XCTAssertEqual(RecordingAutoRestart.restartInterval(forVideoFormat: "2K_30"), RecordingAutoRestart.twoKRestartInterval)
        XCTAssertEqual(RecordingAutoRestart.restartInterval(forVideoFormat: nil), RecordingAutoRestart.defaultRestartInterval)
    }

    func testIsRestartDueRespectsThePerFormatThreshold() {
        XCTAssertFalse(RecordingAutoRestart.isRestartDue(elapsed: 7 * 60, videoFormat: "4K_30"))
        XCTAssertTrue(RecordingAutoRestart.isRestartDue(elapsed: 7 * 60 + 23, videoFormat: "4K_30"))
        XCTAssertFalse(RecordingAutoRestart.isRestartDue(elapsed: 29 * 60 + 50, videoFormat: "FHD_30"))
        XCTAssertTrue(RecordingAutoRestart.isRestartDue(elapsed: 29 * 60 + 55, videoFormat: "FHD_30"))
        XCTAssertFalse(RecordingAutoRestart.isRestartDue(elapsed: 29 * 60 + 45, videoFormat: "2K_30"))
        XCTAssertTrue(RecordingAutoRestart.isRestartDue(elapsed: 29 * 60 + 50, videoFormat: "2K_30"))
        XCTAssertTrue(RecordingAutoRestart.isRestartDue(elapsed: 29 * 60 + 55, videoFormat: nil))
    }
}
