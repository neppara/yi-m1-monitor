// BLE pairing - port of yi-m1-remote-control/prot_ble/ble_keyhack.py's
// trigger_remote_control_closest() / YiBleConnectProtocol.
//
// Exact sequence (see DEVELOPMENT_PLAN.md Part 4.1 for the full protocol writeup):
//   1. Scan (unfiltered - matches the macOS lesson that trusting CoreBluetooth's own service-
//      UUID scan filter produced false positives; verify the UUID in the advertisement
//      ourselves instead), pick strongest RSSI match that advertises YiBLE.serviceM1.
//   2. Connect, discover services + characteristics.
//   3. Read FIRMWARE_INFO -> "proto,body,variant[,lens]"; detect whether UNK_NOTIFY_F exists.
//   4. Pairing: random key, write "proto,key,android" to PAIRING_INIT, subscribe to
//      PAIRING_NOTIF, wait (30s timeout) for a non-empty token (empty = denied).
//   5. Session start: CRC32("1"+key+token), write "proto,key,checksum" to START_SESSION.
//      If UNK_NOTIFY_F exists: subscribe to it + UNK_NOTIFY_0, write "3" to RESUME_RELATED.
//   6. Read WIFI_AP_KEYSHARE -> "ssid,password", write "ON" to WIFI_SWITCH, sleep ~1s.
//   7. Return WiFiCredentials(ssid, password).
// 90s overall ceiling (matches the macOS asyncio.wait_for(..., timeout=90.0)).
//
// NOT verifiable without the real camera - this is the single riskiest file in the whole port
// (see DEVELOPMENT_PLAN.md Part 8 risk #1/#2). It compiles and type-checks against the real
// CoreBluetooth API, but the actual handshake has not been exercised on-device.
import CoreBluetooth
import Foundation

public struct WiFiCredentials: Sendable, Equatable {
    public let ssid: String
    public let password: String
    public init(ssid: String, password: String) {
        self.ssid = ssid
        self.password = password
    }
}

public struct BLEDeviceInfo: Sendable, Equatable {
    public let manufacturer: String
    public let modelNumber: String
    public let firmwareBody: String
    public let isGlobalVariant: Bool
}

public enum BLEPairingError: Error, Sendable, Equatable {
    case bluetoothUnavailable(String)   // carries CBManagerState description
    case noDeviceFound
    case connectionFailed(String)
    case serviceNotFound
    case missingCharacteristic(String)
    case invalidFirmwareInfo
    case pairingDenied
    case pairingTimedOut
    case overallTimedOut
    case invalidWifiCredentials
}

/// One BLE pairing attempt. Not reused across attempts - create a fresh instance per
/// `pairWithClosestCamera()` call (mirrors the Python reference creating a fresh
/// YiBleConnectProtocol + BleakClient per attempt).
public final class BLEPairing: NSObject, @unchecked Sendable {
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var characteristics: [CBUUID: CBCharacteristic] = [:]

    private var stateContinuation: CheckedContinuation<Void, Error>?
    private var discoveryContinuation: CheckedContinuation<CBPeripheral, Error>?
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var serviceDiscoveryContinuation: CheckedContinuation<Void, Error>?
    private var characteristicDiscoveryContinuation: CheckedContinuation<Void, Error>?
    private var readContinuations: [CBUUID: CheckedContinuation<Data, Error>] = [:]
    private var writeContinuations: [CBUUID: CheckedContinuation<Void, Error>] = [:]
    private var notifySetupContinuations: [CBUUID: CheckedContinuation<Void, Error>] = [:]
    private var pairingTokenContinuation: CheckedContinuation<String, Never>?

    private var discovered: [(peripheral: CBPeripheral, rssi: Int)] = []
    private var scanDeadline: Date = .distantPast

    public override init() {
        super.init()
    }

    /// Full handshake with an overall 90s ceiling. Throws a `BLEPairingError` on any failure.
    public func pairWithClosestCamera() async throws -> WiFiCredentials {
        try await withThrowingTaskGroup(of: WiFiCredentials.self) { group in
            group.addTask { try await self.runHandshake() }
            group.addTask {
                try await Task.sleep(nanoseconds: 90_000_000_000)
                throw BLEPairingError.overallTimedOut
            }
            guard let result = try await group.next() else {
                throw BLEPairingError.overallTimedOut
            }
            group.cancelAll()
            return result
        }
    }

    private func runHandshake() async throws -> WiFiCredentials {
        let manager = CBCentralManager(delegate: self, queue: DispatchQueue(label: "com.yim1.ble"))
        central = manager

        try await waitForPoweredOn()

        let found = try await scanForClosestCamera(timeout: 10.0)
        peripheral = found
        found.delegate = self

        try await connect(to: found)
        try await discoverServices(on: found)
        try await discoverCharacteristics(on: found)

        // Informational reads - tolerate failures, matching the Python reference (these fields
        // are unused elsewhere in the flow; some firmware, incl. the one this was built
        // against, doesn't expose the standard Device Name characteristic at all).
        _ = try? await readString(YiBLE.stdDeviceName)
        _ = try? await readString(YiBLE.stdDeviceManufacturer)
        _ = try? await readString(YiBLE.stdModelNumber)

        guard let firmwareInfoRaw = try? await readString(YiBLE.charFirmwareInfo) else {
            throw BLEPairingError.invalidFirmwareInfo
        }
        let parts = firmwareInfoRaw.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3, let proto = Int(parts[0]) else {
            throw BLEPairingError.invalidFirmwareInfo
        }
        let requiresFUuid = characteristics[YiBLE.charUnkNotifyF] != nil

        // --- Pairing ---
        let key = String(Int.random(in: 0...99998))
        // The literal "android" is intentional, not a copy-paste artifact: it's part of the
        // proven-working handshake (the reference impl mimics the official Android app), and
        // it's unverified whether the firmware special-cases this token at all. Don't change
        // it to "ios" without confirming live that the firmware doesn't care.
        let pairingParams = "\(proto),\(key),android"
        try await setNotify(YiBLE.charPairingNotif, enabled: true)
        try await write(YiBLE.charPairingInit, string: pairingParams)

        let token = try await withTimeout(seconds: 30, error: .pairingTimedOut) {
            await withCheckedContinuation { continuation in
                self.pairingTokenContinuation = continuation
            }
        }
        guard !token.isEmpty else {
            throw BLEPairingError.pairingDenied
        }

        // --- Session start ---
        let checksumInput = "1" + key + token
        let checksum = CRC32.checksum(Data(checksumInput.utf8))
        let sessionParams = "\(proto),\(key),\(checksum)"
        try await write(YiBLE.charStartSession, string: sessionParams)

        if requiresFUuid {
            try? await setNotify(YiBLE.charUnkNotifyF, enabled: true)
            try? await setNotify(YiBLE.charUnkNotify0, enabled: true)
            try? await write(YiBLE.charResumeRelated, string: "3")
        }

        // --- Wi-Fi credentials ---
        guard let credsRaw = try? await readString(YiBLE.charWifiApKeyshare) else {
            throw BLEPairingError.invalidWifiCredentials
        }
        let credParts = credsRaw.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard credParts.count == 2 else {
            throw BLEPairingError.invalidWifiCredentials
        }
        try await write(YiBLE.charWifiSwitch, string: "ON")
        try await Task.sleep(nanoseconds: 1_000_000_000) // let any trailing notifications settle

        // Explicit BLE teardown (added 2026-07-11): the link previously only died implicitly
        // when this object deallocated after the connect flow finished. Making it deterministic
        // matters because Bluetooth and Wi-Fi share the phone's 2.4GHz antenna - ANY lingering
        // BLE activity steals radio time from the camera's Wi-Fi stream (the live-view
        // radio-away investigation is what surfaced this). The credentials are already in hand;
        // nothing BLE remains to do this session.
        if let peripheral {
            central?.cancelPeripheralConnection(peripheral)
        }
        central?.stopScan()

        return WiFiCredentials(ssid: credParts[0], password: credParts[1])
    }

    // MARK: - Small async helpers

    private func withTimeout<T>(seconds: TimeInterval, error: BLEPairingError, _ body: @escaping () async -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { await body() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw error
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func waitForPoweredOn() async throws {
        if central?.state == .poweredOn { return }
        try await withCheckedThrowingContinuation { continuation in
            self.stateContinuation = continuation
        }
    }

    private func scanForClosestCamera(timeout: TimeInterval) async throws -> CBPeripheral {
        discovered = []
        central?.scanForPeripherals(withServices: nil, options: nil)
        try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        central?.stopScan()
        guard let best = discovered.max(by: { $0.rssi < $1.rssi }) else {
            throw BLEPairingError.noDeviceFound
        }
        return best.peripheral
    }

    private func connect(to peripheral: CBPeripheral) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.connectContinuation = continuation
            self.central?.connect(peripheral, options: nil)
        }
    }

    private func discoverServices(on peripheral: CBPeripheral) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.serviceDiscoveryContinuation = continuation
            peripheral.discoverServices([YiBLE.serviceM1])
        }
    }

    private func discoverCharacteristics(on peripheral: CBPeripheral) async throws {
        guard let service = peripheral.services?.first(where: { $0.uuid == YiBLE.serviceM1 }) else {
            throw BLEPairingError.serviceNotFound
        }
        try await withCheckedThrowingContinuation { continuation in
            self.characteristicDiscoveryContinuation = continuation
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    private func readString(_ uuid: CBUUID) async throws -> String {
        guard let characteristic = characteristics[uuid] else {
            throw BLEPairingError.missingCharacteristic(uuid.uuidString)
        }
        let data = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            self.readContinuations[uuid] = continuation
            self.peripheral?.readValue(for: characteristic)
        }
        // Trim trailing NUL padding, matching the Python reference's trim_byte_to_str.
        let trimmed = data.split(separator: 0, maxSplits: 1, omittingEmptySubsequences: false).first ?? Data()
        return String(data: trimmed, encoding: .ascii) ?? ""
    }

    private func write(_ uuid: CBUUID, string: String) async throws {
        guard let characteristic = characteristics[uuid] else {
            throw BLEPairingError.missingCharacteristic(uuid.uuidString)
        }
        let data = Data(string.utf8)
        let type: CBCharacteristicWriteType = characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        if type == .withoutResponse {
            peripheral?.writeValue(data, for: characteristic, type: .withoutResponse)
            return
        }
        try await withCheckedThrowingContinuation { continuation in
            self.writeContinuations[uuid] = continuation
            self.peripheral?.writeValue(data, for: characteristic, type: .withResponse)
        }
    }

    private func setNotify(_ uuid: CBUUID, enabled: Bool) async throws {
        guard let characteristic = characteristics[uuid] else {
            throw BLEPairingError.missingCharacteristic(uuid.uuidString)
        }
        try await withCheckedThrowingContinuation { continuation in
            self.notifySetupContinuations[uuid] = continuation
            self.peripheral?.setNotifyValue(enabled, for: characteristic)
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEPairing: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            stateContinuation?.resume()
            stateContinuation = nil
        } else if central.state != .unknown, central.state != .resetting {
            // Human-readable reason (I5, 2026-07-12: permission-denied paths should say what to
            // do, not just fail generically) - CBManagerState has no CustomStringConvertible
            // conformance worth showing a user, so map the cases we actually expect explicitly.
            let reason: String
            switch central.state {
            case .poweredOff: reason = "Bluetooth is turned off"
            case .unauthorized: reason = "This app isn't allowed to use Bluetooth"
            case .unsupported: reason = "Bluetooth isn't available on this device"
            default: reason = "Bluetooth is unavailable"
            }
            stateContinuation?.resume(throwing: BLEPairingError.bluetoothUnavailable(reason))
            stateContinuation = nil
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                advertisementData: [String: Any], rssi RSSI: NSNumber) {
        // Verify the service UUID is actually advertised, rather than trusting a scan filter -
        // mirrors the macOS lesson (a filtered scan once returned an unrelated nearby device).
        let advertisedUUIDs = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        guard advertisedUUIDs.contains(YiBLE.serviceM1) else { return }
        discovered.append((peripheral: peripheral, rssi: RSSI.intValue))
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectContinuation?.resume()
        connectContinuation = nil
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectContinuation?.resume(throwing: BLEPairingError.connectionFailed(error?.localizedDescription ?? "unknown"))
        connectContinuation = nil
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        // No action needed here for the happy path (we disconnect implicitly by dropping the
        // CBCentralManager reference once the handshake completes) - present for completeness /
        // future diagnostics.
    }
}

// MARK: - CBPeripheralDelegate

extension BLEPairing: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            serviceDiscoveryContinuation?.resume(throwing: error)
        } else {
            serviceDiscoveryContinuation?.resume()
        }
        serviceDiscoveryContinuation = nil
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            characteristicDiscoveryContinuation?.resume(throwing: error)
            characteristicDiscoveryContinuation = nil
            return
        }
        for characteristic in service.characteristics ?? [] {
            characteristics[characteristic.uuid] = characteristic
        }
        characteristicDiscoveryContinuation?.resume()
        characteristicDiscoveryContinuation = nil
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        // Pairing notification: a value arriving on PAIRING_NOTIF after we subscribed is the
        // token (or empty = denied) - see YiBleConnectProtocol.__on_pair_action.
        if characteristic.uuid == YiBLE.charPairingNotif, let continuation = pairingTokenContinuation {
            pairingTokenContinuation = nil
            let data = characteristic.value ?? Data()
            let trimmed = data.split(separator: 0, maxSplits: 1, omittingEmptySubsequences: false).first ?? Data()
            let token = String(data: trimmed, encoding: .ascii) ?? ""
            continuation.resume(returning: token)
            return
        }
        // A regular read (readValue(for:)) response.
        if let continuation = readContinuations[characteristic.uuid] {
            readContinuations[characteristic.uuid] = nil
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume(returning: characteristic.value ?? Data())
            }
        }
        // Other notify characteristics (UNK_NOTIFY_0/F) are intentionally not awaited on beyond
        // subscription - matches the Python reference's __debug_on_extra_notify (logged only).
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let continuation = writeContinuations[characteristic.uuid] else { return }
        writeContinuations[characteristic.uuid] = nil
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard let continuation = notifySetupContinuations[characteristic.uuid] else { return }
        notifySetupContinuations[characteristic.uuid] = nil
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }
}
