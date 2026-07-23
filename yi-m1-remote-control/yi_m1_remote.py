#!/usr/bin/env python3
"""
Interactive remote control CLI for the YI M1 mirrorless camera.

Built on protocol reverse-engineering from bullbin/xiaoyi_m1_re_liveview
(BLE pairing + Wi-Fi HTTP command set), with fixes for macOS Bluetooth
reliability issues and commands confirmed working through live testing
against firmware 3.2-int (see ../fable research/live-testing-findings.md).

Usage: run from a normal Terminal.app window (not through an automation
sandbox) so macOS can grant Bluetooth permission. Requires the camera to
be powered on and its BLE pairing prompt to be answered on-camera.

    python3 -m venv venv && source venv/bin/activate
    pip install -r requirements.txt
    python3 yi_m1_remote.py
"""
import sys
import time
from urllib3 import PoolManager
from urllib3.exceptions import TimeoutError as UrllibTimeoutError

from prot_ble import trigger_remote_control_closest
from prot_http.const_wifi import INET_ADDRESS_CAMERA
from prot_http.command_http import (
    YiHttpCmd, RcCmdStart, RcCmdStop, RcCmdSetIso, RcCmdSetWhiteBalanceMode,
    RcCmdSetShutterSpeed, RcCmdSetFStop, RcCmdSetExposureValueOffset,
    RcCmdSetCameraMode, RcCmdSetImageQuality, RcCmdSetImageAspect,
    RcCmdSetImageFormat, RcCmdSetDriveMode, RcCmdShootPhoto, RcCmdTriggerFocus,
)
from prot_http.const_http_cmd_rc_params import (
    RcIso, RcWhiteBalance, RcShutterSpeed, RcFStop, RcEvOffset, RcExposureMode,
    RcImageQuality, RcImageAspect, RcFileFormat, RcDriveMode, RcTriggerFocusMode,
)

http = PoolManager()


class RawCmd(YiHttpCmd):
    """For commands not wrapped by the upstream library (confirmed working via manual testing)."""
    def __init__(self, command_name):
        self.__command_name = command_name

    def to_json(self):
        return {"command": self.__command_name}


def send(cmd: YiHttpCmd, timeout=3.0):
    json_str = str(cmd.to_json()).replace("'", '"').replace(' "', '"')
    url = "http://%s/?data=%s" % (INET_ADDRESS_CAMERA, json_str)
    try:
        response = http.request("GET", url, timeout=timeout)
        return response.status, response.data.decode("utf-8", errors="replace")
    except UrllibTimeoutError:
        return None, "timeout"
    except Exception as e:
        return None, repr(e)


class Cancelled(Exception):
    pass


def prompt_choice(label, enum_cls):
    options = list(enum_cls)
    print("\n%s:" % label)
    for i, opt in enumerate(options):
        print("  [%d] %s" % (i, opt.name))
    raw = input("Choose number: ").strip()
    try:
        return options[int(raw)]
    except (ValueError, IndexError):
        print("Invalid choice, cancelled.")
        raise Cancelled()


def send_or_cancelled(build_cmd):
    try:
        return send(build_cmd())
    except Cancelled:
        return None


def pair_via_ble():
    print("=== BLE pairing ===")
    print("Make sure the camera is powered on and nearby.")
    print("If macOS asks for Bluetooth permission, allow it.")
    result = trigger_remote_control_closest()
    if result is None:
        print("Pairing failed. Try again, or reduce distance to the camera.")
        sys.exit(1)
    ssid, password = result
    print("\n=== Wi-Fi credentials received ===")
    print("SSID: %s" % ssid)
    print("Pass: %s" % password)
    print("\nSwitch this Mac's Wi-Fi to that network now.")
    input("Press Enter once connected... ")


def main():
    pair_via_ble()

    status, body = send(RawCmd("GetCameraStatus"))
    print("\nGetCameraStatus -> %s %s" % (status, body))
    if status != 200:
        print("Camera not reachable at %s. Check Wi-Fi connection." % INET_ADDRESS_CAMERA)
        sys.exit(1)

    status, body = send(RcCmdStart())
    print("RCStartRemoteCtl -> %s %s" % (status, body))

    menu = {
        "1": ("Get camera status", lambda: send(RawCmd("GetCameraStatus"))),
        "2": ("Set ISO", lambda: send_or_cancelled(lambda: RcCmdSetIso(prompt_choice("ISO", RcIso)))),
        "3": ("Set white balance", lambda: send_or_cancelled(lambda: RcCmdSetWhiteBalanceMode(prompt_choice("White balance", RcWhiteBalance)))),
        "4": ("Set shutter speed", lambda: send_or_cancelled(lambda: RcCmdSetShutterSpeed(prompt_choice("Shutter speed", RcShutterSpeed)))),
        "5": ("Set aperture (F-stop)", lambda: send_or_cancelled(lambda: RcCmdSetFStop(prompt_choice("F-stop", RcFStop)))),
        "6": ("Set EV offset", lambda: send_or_cancelled(lambda: RcCmdSetExposureValueOffset(prompt_choice("EV offset", RcEvOffset)))),
        "7": ("Set exposure mode (P/A/S/M)", lambda: send_or_cancelled(lambda: RcCmdSetCameraMode(prompt_choice("Exposure mode", RcExposureMode)))),
        "8": ("Set image quality", lambda: send_or_cancelled(lambda: RcCmdSetImageQuality(prompt_choice("Image quality", RcImageQuality)))),
        "9": ("Set image aspect", lambda: send_or_cancelled(lambda: RcCmdSetImageAspect(prompt_choice("Image aspect", RcImageAspect)))),
        "10": ("Set file format (RAW/JPEG)", lambda: send_or_cancelled(lambda: RcCmdSetImageFormat(prompt_choice("File format", RcFileFormat)))),
        "11": ("Set drive mode", lambda: send_or_cancelled(lambda: RcCmdSetDriveMode(prompt_choice("Drive mode", RcDriveMode)))),
        "12": ("Trigger autofocus", lambda: send(RcCmdTriggerFocus(RcTriggerFocusMode.Auto))),
        "13": ("Take photo", lambda: send(RcCmdShootPhoto())),
        "14": ("Start video recording", lambda: send(RawCmd("VideoRecordingStart"))),
        "15": ("Stop video recording", lambda: send(RawCmd("VideoRecordingStop"))),
        "0": ("Exit (stop remote control session)", None),
    }

    while True:
        print("\n=== YI M1 Remote Control ===")
        for key in sorted(menu.keys(), key=lambda k: int(k)):
            print("  [%s] %s" % (key, menu[key][0]))
        choice = input("Choose: ").strip()

        if choice == "0":
            break
        action = menu.get(choice)
        if action is None:
            print("Invalid choice.")
            continue

        result = action[1]()
        if result is not None:
            status, body = result
            print("-> status=%s body=%s" % (status, body))

    status, body = send(RcCmdStop())
    print("RCStopRemoteCtl -> %s %s" % (status, body))


if __name__ == "__main__":
    main()
