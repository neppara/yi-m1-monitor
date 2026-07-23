import XCTest
@testable import YiM1Core

final class CRC32Tests: XCTestCase {
    func testKnownVector() {
        // Standard CRC-32/ISO-HDLC check value (matches Python's zlib.crc32(b"123456789")).
        let result = CRC32.checksum(Data("123456789".utf8))
        XCTAssertEqual(result, 0xCBF4_3926)
    }

    func testEmptyInput() {
        XCTAssertEqual(CRC32.checksum(Data()), 0)
    }

    func testMatchesBLEPairingSessionStartFormat() {
        // Mirrors ble_keyhack.py's do_session_start: checksum = crc32(("1"+key+token).encode())
        let payload = "1" + "42" + "abc123"
        let checksum = CRC32.checksum(Data(payload.utf8))
        XCTAssertGreaterThan(checksum, 0)
        // Deterministic - same input always produces the same checksum.
        XCTAssertEqual(checksum, CRC32.checksum(Data(payload.utf8)))
    }
}
