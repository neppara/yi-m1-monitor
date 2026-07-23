import asyncio
import time
from bleak import BleakClient, BleakGATTCharacteristic, BleakScanner
from bleak.exc import BleakError
from random import randint
from .const_ble_uuid import *
from typing import List, Tuple, Optional
from traceback import print_exc
from zlib import crc32

def trim_byte_to_str(data : bytearray) -> str:
    return data.decode('ascii').rstrip('\x00')

class YiBleConnectProtocol():
    def __init__(self):
        self.__firmware_lens : str = ""
        self.__firmware_body : str = "M1"
        self.__is_global_variant : bool = False
        
        self.__ble_protocol : int = 0
        self.__ble_name = ""
        self.__ble_manufacturer = ""
        self.__ble_model_number = ""
        self.__ble_key : str = ""
        self.__ble_token : str = ""

        self.__ble_requires_f_uuid = False

        self.__ble_retrieve_successful = False
        self.__ble_key_negotiated = False
        self.__ble_session_started = False

        self.__wlanSsid = ""
        self.__wlanPwd = ""
        
        self.__state_awaiting_pair = False

    async def retrieve_info(self, client : BleakClient):

        def check_is_global_variant(variant : str, firmware : str) -> bool:
            
            def str_check_china(id : str) -> bool:
                return len(id) == 0 or id in ["M1CN", "M1"] or id != "M1INT"
            
            if len(variant) == 0:
                return not str_check_china(firmware)
            return not str_check_china(variant)

        if not(client.is_connected):
            return
        
        for services in client.services:
            for characteristic in services.characteristics:
                if characteristic.uuid == UUID_CHAR_UNK_NOTIFY_F:
                    self.__ble_requires_f_uuid = True
                    break

        # Some firmware versions (confirmed on 3.2-int) do not expose the standard
        # GATT "Device Name" characteristic. These fields are informational only
        # and unused elsewhere in the pairing flow, so failures here are tolerated.
        try:
            self.__ble_name = trim_byte_to_str(await client.read_gatt_char(UUID_STD_DEVICE_NAME))
        except Exception:
            self.__ble_name = ""
        try:
            self.__ble_manufacturer = trim_byte_to_str(await client.read_gatt_char(UUID_STD_DEVICE_MANUFACTURER))
        except Exception:
            self.__ble_manufacturer = ""
        try:
            self.__ble_model_number = trim_byte_to_str(await client.read_gatt_char(UUID_STD_MODEL_NUMBER))
        except Exception:
            self.__ble_model_number = ""

        firmware_info : List[str] = trim_byte_to_str(await client.read_gatt_char(UUID_CHAR_FIRMWARE_INFO)).split(",")
        if len(firmware_info) >= 3:
            if firmware_info[0].isdigit(): self.__ble_protocol = int(firmware_info[0])
            self.__firmware_body = firmware_info[1]
            self.__is_global_variant = check_is_global_variant(firmware_info[2], self.__firmware_body)

            if len(firmware_info) > 3:
                self.__firmware_lens = firmware_info[3]
        
            self.__ble_retrieve_successful = True
    
    def __debug_on_extra_notify(self, characteristic : BleakGATTCharacteristic, data : bytearray):
        print("Unhandled", characteristic.uuid, data)

    def __on_pair_action(self, _characteristic : BleakGATTCharacteristic, data : bytearray):
        token = trim_byte_to_str(data)
        
        if len(token) == 0:
            self.__state_awaiting_pair = False
            print("\tPairing request denied.")
            return

        self.__ble_token = token
        self.__ble_key_negotiated = True
        self.__state_awaiting_pair = False

        print("\tPairing completed, token %s generated with key %s. Starting session..." % (token, self.__ble_key))

    async def do_pairing(self, client : BleakClient) -> bool:
        if not(client.is_connected and self.__ble_retrieve_successful):
            return False

        print("Attempting key negotiation...")
        self.__ble_key = str(randint(0, 99998))
        params = "%d,%s,android" % (self.__ble_protocol, self.__ble_key)
        print("\tDispatching key. Please press Accept on the camera.")

        await client.start_notify(UUID_CHAR_PAIRING_NOTIF, self.__on_pair_action)
        await client.write_gatt_char(UUID_CHAR_PAIRING_INIT, params.encode('ascii'), response=True)

        self.__state_awaiting_pair = True

    async def do_session_start(self, client : BleakClient):
        response = "1" + self.__ble_key + self.__ble_token
        response = response.encode('ascii')
        checksum = crc32(response)
        params = "%d,%s,%d" % (self.__ble_protocol, self.__ble_key, checksum)
        await client.write_gatt_char(UUID_CHAR_START_SESSION, params.encode('ascii'), response=True)
        
        if (self.__ble_requires_f_uuid):
            await client.start_notify(UUID_CHAR_UNK_NOTIFY_F, self.__debug_on_extra_notify)
            await client.start_notify(UUID_CHAR_UNK_NOTIFY_0, self.__debug_on_extra_notify)
            await client.write_gatt_char(UUID_CHAR_RESUME_RELATED, '3'.encode('ascii'), response=True)
    
    async def start_wifi_connect(self, client : BleakClient) -> Optional[Tuple[str,str]]:
        wlan_credentials = trim_byte_to_str(await client.read_gatt_char(UUID_CHAR_WIFI_AP_KEYSHARE)).split(",")
        if len(wlan_credentials) == 2:
            self.__wlanSsid = wlan_credentials[0]
            self.__wlanPwd = wlan_credentials[1]

            print("Handshake authenticated. WLAN credentials extracted, SSID %s, passkey %s. Enabling Wi-Fi..." % (self.__wlanSsid, self.__wlanPwd))
            await client.write_gatt_char(UUID_CHAR_WIFI_SWITCH, "ON".encode('ascii'))
            print("\tWi-Fi ready for connection. Handshake complete!")

            # TODO - ac,6, sync_time. Sleep to allow any other notifications to arrive
            await asyncio.sleep(1.0)
            return (self.__wlanSsid, self.__wlanPwd)
        return None

    def busy(self):
        return self.__state_awaiting_pair
    
    def can_start_session(self):
        return self.__ble_key_negotiated and not(self.__ble_session_started)

    def get_device_info(self) -> Tuple[str, str, str, str]:
        """Returns (manufacturer, model_number, firmware_body, is_global_variant) gathered during retrieve_info()."""
        return (self.__ble_manufacturer, self.__ble_model_number, self.__firmware_body, self.__is_global_variant)

def get_mac_address_cameras() -> List[str]:
    """Get MAC addresses of possible cameras.

    Cameras are detected by whether the required Bluetooth LE main service is available. This may not be accurate.

    Returns:
        List[str]: MAC addresses sorted by signal strength, descending.
    """

    async def get_mac_address_cameras_internal() -> List[str]:
        scanner = BleakScanner(service_uuids=[UUID_SERVICE_M1])
        devices = await scanner.discover(return_adv=True)
        devices = [(d.address,a.rssi) for d,a in devices.values() if a.rssi >= -50]     # Filter on signal strength
        devices = sorted(devices, key=lambda x: x[1], reverse=True)   # Sort by signal strength, highest is better
        return [a for a,_r in devices]

    return asyncio.run(get_mac_address_cameras_internal())

def trigger_remote_control(mac_address_camera : str) -> Optional[Tuple[str,str]]:
    """Connect and negotiate Wi-Fi keys with a camera at the specified MAC address.

    Handshaking occurs over Bluetooth LE and emulates the pipeline in the final firmware and version of the Yi Mirrorless app. Pairing keys are randomized so limited interaction will be needed with the camera to complete the authentication. Connection is terminated once Wi-Fi is enabled.
    
    Not all components are emulated; time syncing is not applied and pairing is not wiped after connection.

    Args:
        mac_address_camera (str): MAC address encoded as hex bytes with colon dividers.

    Returns:
        Optional[Tuple[str,str]]: (SSID, Passkey) if successful; None if not.
    """

    async def trigger_remote_control_internal(mac_address_camera : str) -> Optional[Tuple[str,str]]:
        try:
            async with BleakClient(mac_address_camera) as client:
                debug = YiBleConnectProtocol()
                await debug.retrieve_info(client)
                await debug.do_pairing(client)      # TODO - If we have valid token, we skip pairing and start session immediately.
                                                    #        The camera is capable of storing only one key. The app will warn you
                                                    #        that the camera does not remember your device and needs to repair.
                while debug.busy():
                    await asyncio.sleep(2.0)

                if debug.can_start_session():
                    await debug.do_session_start(client)
                    output = await debug.start_wifi_connect(client)
                    return output
                
        except Exception as _e:
            print("Communication error. Camera connection failed.")
            print_exc()

        return None
    
    return asyncio.run(trigger_remote_control_internal(mac_address_camera))

def trigger_remote_control_closest() -> Optional[Tuple[str,str]]:
    """Scan for and connect to the closest camera in a single BLE session, then negotiate Wi-Fi keys.

    On macOS, scanning and connecting in separate asyncio.run() calls (as the original two-step
    get_mac_address_cameras() + trigger_remote_control() does) is unreliable: each call spins up a
    new CBCentralManager that does not always retain devices found by a previous scan, leading to
    "device not found" or connection timeouts. Scanning and connecting within one session, using the
    discovered device object directly, is far more reliable. This also verifies the service UUID is
    actually present in the advertisement data rather than trusting BleakScanner's own filtering,
    which was observed to occasionally return unrelated nearby devices (e.g. a phone) as false positives.

    Returns:
        Optional[Tuple[str,str]]: (SSID, Passkey) if successful; None if not.
    """
    target_uuid = UUID_SERVICE_M1.lower()

    def log(msg):
        # print() defaults to line-buffering only when stdout is a real tty; under some
        # launch conditions (observed: output not appearing in Terminal.app at all while
        # the app was stuck) it silently block-buffers instead, so force a flush every time.
        print(msg, flush=True)

    async def internal() -> Optional[Tuple[str, str]]:
        # Everything below (including scanner creation - the "Bluetooth device is turned off"
        # BleakError is commonly raised right here on the *first* call after macOS grants
        # Bluetooth permission, before CoreBluetooth's state has settled) must be inside this
        # try/except. Previously it wasn't, so that transient error would propagate uncaught
        # out of asyncio.run() and crash the calling QThread's run() entirely (observed as
        # "Error calling Python override of QThread::run()"). Callers should just retry.
        try:
            # Scanner creation is retried (2026-07-20): bleak waits only 1 SECOND for
            # CoreBluetooth to report its state and then hard-fails with "Bluetooth device is
            # turned off" - which is exactly what happens on the first connect attempt from a
            # freshly-launched .app, where the CoreBluetooth stack (TCC grant settling, the XPC
            # connection to bluetoothd) hasn't warmed up yet. The adapter is genuinely ON in
            # that case; a second attempt a moment later succeeds. Symptom this fixes, as the
            # user reported it: "press connect -> a few seconds -> error, and Bluetooth never
            # searches again".
            scanner = None
            last_state_error = None
            for attempt in range(1, 6):
                try:
                    log("[BLE] Creating scanner (attempt %d/5)..." % attempt)
                    scanner = BleakScanner()
                    break
                except BleakError as e:
                    if "not authorized" in str(e):
                        raise  # a real permission problem - retrying can't help
                    last_state_error = e
                    log("[BLE] CoreBluetooth not ready yet (%s) - waiting 1s and retrying." % e)
                    await asyncio.sleep(1.0)
            if scanner is None:
                log("[BLE] CoreBluetooth never reported a powered-on adapter after 5 attempts. "
                    "If Bluetooth really is on, check System Settings > Privacy & Security > "
                    "Bluetooth for this app. Last error: %s" % last_state_error)
                return None
            log("[BLE] Scanning for 10s (unfiltered, so we can see every nearby BLE device)...")
            devices = await scanner.discover(timeout=10.0, return_adv=True)

            log("[BLE] Scan complete. Saw %d BLE device(s) total:" % len(devices))
            matches = []
            for d, a in devices.values():
                uuids = [u.lower() for u in (a.service_uuids or [])]
                is_match = target_uuid in uuids
                flag = "  <-- MATCHES YI M1 service UUID" if is_match else ""
                log("  %s  rssi=%s  name=%r  uuids=%s%s" % (d.address, a.rssi, d.name, uuids, flag))
                if is_match:
                    matches.append((d, a.rssi))

            if not matches:
                log("[BLE] No device advertised the YI M1 service UUID (%s)." % UUID_SERVICE_M1)
                log("[BLE] If the camera isn't in the list above at all: it may be asleep/off, "
                    "out of range, or already connected to something else (phone app, etc.) - "
                    "the camera only accepts one BLE client at a time. Wake the camera screen "
                    "and make sure the official app isn't connected, then try again.")
                return None

            matches.sort(key=lambda x: x[1], reverse=True)
            device, rssi = matches[0]
            log("[BLE] Using match: %s (rssi=%s). Connecting..." % (device.address, rssi))

            async with BleakClient(device, timeout=20.0) as client:
                log("[BLE] Connected. Reading firmware info characteristic...")
                debug = YiBleConnectProtocol()
                await debug.retrieve_info(client)
                manufacturer, model, firmware_body, is_global = debug.get_device_info()
                log("[BLE] Device info: manufacturer=%s model=%s firmware=%s global=%s" % (manufacturer, model, firmware_body, is_global))

                log("[BLE] Sending pairing request. *** CHECK THE CAMERA SCREEN NOW for an Accept prompt. ***")
                await debug.do_pairing(client)
                # Bound the wait - there was previously no timeout here at all, so if the
                # camera never shows/answers the on-screen "Accept" prompt (screen asleep,
                # BLE notification lost, etc.) this loop blocked the whole QThread forever
                # with no way for the UI to recover short of force-killing the thread.
                pairing_deadline = time.time() + 30.0
                while debug.busy():
                    if time.time() > pairing_deadline:
                        log("[BLE] Timed out after 30s waiting for pairing confirmation on the camera.")
                        break
                    await asyncio.sleep(1.0)

                if debug.can_start_session():
                    log("[BLE] Pairing accepted. Starting session and reading Wi-Fi credentials...")
                    await debug.do_session_start(client)
                    result = await debug.start_wifi_connect(client)
                    log("[BLE] Handshake finished, result=%r" % (result,))
                    return result
                log("[BLE] Pairing was not completed (denied or timed out).")
                return None
        except Exception:
            log("[BLE] Communication error. Camera connection failed. Full traceback below:")
            print_exc()
            return None

    async def internal_with_ceiling():
        # Hard overall ceiling so a hang in *any* step (scan, connect, retrieve_info,
        # session start, wifi read - not just the pairing-confirmation wait, which has
        # its own 30s timeout above) can't block the calling thread forever.
        try:
            return await asyncio.wait_for(internal(), timeout=90.0)
        except asyncio.TimeoutError:
            log("[BLE] Overall BLE handshake timed out after 90s.")
            return None

    log("[BLE] trigger_remote_control_closest() starting.")
    result = asyncio.run(internal_with_ceiling())
    log("[BLE] trigger_remote_control_closest() returning: %r" % (result,))
    return result