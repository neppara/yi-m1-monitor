// Standard CRC-32 (the zlib/PNG/CRC-32B variant - polynomial 0xEDB88320, reflected, init/xorout
// 0xFFFFFFFF), matching Python's `zlib.crc32()` exactly. Needed for the BLE session-start
// checksum - see BLEPairing.swift, which replicates
// yi-m1-remote-control/prot_ble/ble_keyhack.py's `do_session_start`:
//   response = ("1" + key + token).encode('ascii'); checksum = zlib.crc32(response)
import Foundation

public enum CRC32 {
    private static let table: [UInt32] = {
        (0...255).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()

    public static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = table[index] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}
