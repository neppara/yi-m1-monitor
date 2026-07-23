// BLE GATT UUIDs - exact port of yi-m1-remote-control/prot_ble/const_ble_uuid.py.
import CoreBluetooth

public enum YiBLE {
    public static let serviceM1 = CBUUID(string: "41106dd9-25ad-477b-a884-5038b6de4649")

    public static let charPairingInit = CBUUID(string: "41106da0-25ad-477b-a884-5038b6de4649")
    public static let charPairingNotif = CBUUID(string: "41106da7-25ad-477b-a884-5038b6de4649")
    public static let charPairingForget = CBUUID(string: "41106da9-25ad-477b-a884-5038b6de4649") // unused in the pairing flow, kept for parity
    public static let charResponseToken = CBUUID(string: "41106da1-25ad-477b-a884-5038b6de4649") // unused in the flow
    public static let charFirmwareInfo = CBUUID(string: "41106da2-25ad-477b-a884-5038b6de4649")
    public static let charStartSession = CBUUID(string: "41106da4-25ad-477b-a884-5038b6de4649")
    public static let charWifiSwitch = CBUUID(string: "41106da5-25ad-477b-a884-5038b6de4649")
    public static let charWifiApKeyshare = CBUUID(string: "41106da6-25ad-477b-a884-5038b6de4649")
    public static let charSyncTime = CBUUID(string: "41106dac-25ad-477b-a884-5038b6de4649") // unused (not applied in the reference either)

    public static let charUnkNotify0 = CBUUID(string: "41106dae-25ad-477b-a884-5038b6de4649") // lens info
    public static let charUnkNotifyF = CBUUID(string: "41106daf-25ad-477b-a884-5038b6de4649")
    public static let charResumeRelated = CBUUID(string: "41106dad-25ad-477b-a884-5038b6de4649")

    public static let stdModelNumber = CBUUID(string: "00002a24-0000-1000-8000-00805f9b34fb")
    public static let stdDeviceName = CBUUID(string: "00002a00-0000-1000-8000-00805f9b34fb")
    public static let stdDeviceManufacturer = CBUUID(string: "00002a29-0000-1000-8000-00805f9b34fb")
}
