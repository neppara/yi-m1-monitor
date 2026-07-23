#!/usr/bin/env python3
"""
Does an RC "Set" command (ISO/WB/color style/etc, confirmed to work for stills) actually
affect video recording, or only the still-photo pipeline?

Indirect evidence already points to "shared, not separate": the JSON header embedded in every
live-view UDP frame (see app/camera_session.py's _parse_live_metadata) reports photo-only
fields (ImageQuality, Fnumber, FileFormat...) AND video-only fields (VideoFormat, VASwitch...)
together in ONE combined state blob, alongside fields like ISOSetting/WB/ColorMode that don't
have separate "photo" and "video" variants - suggesting one shared camera-state model, not two
isolated ones. But that's circumstantial. This is a direct visual test.

Sets ColorMode to NaturalBW (black & white - a change that's impossible to miss visually,
unlike a subtle ISO difference), records ~3s of video, restores ColorMode to Standard, then
you look at the resulting file: if it's black & white, RC "Set" commands DO affect video, not
just stills. If it's in color, they don't.

Requires this Mac to already be on the camera's Wi-Fi (192.168.0.10 reachable).

Usage:
    cd yi-m1-remote-control
    source venv/bin/activate
    python3 probe_video_param_effect.py

Then check the newest .MP4 on the camera's SD card visually.
"""
import json
import sys
import time

from urllib3 import PoolManager

from prot_http.const_wifi import INET_ADDRESS_CAMERA

http = PoolManager()


def send(command_dict, timeout=3.0):
    json_str = json.dumps(command_dict, separators=(",", ":"))
    url = "http://%s/?data=%s" % (INET_ADDRESS_CAMERA, json_str)
    try:
        response = http.request("GET", url, timeout=timeout)
        return response.status, response.data.decode("utf-8", errors="replace")
    except Exception as e:
        return None, repr(e)


def step(label, command_dict):
    status, body = send(command_dict)
    print("%-28s -> status=%s body=%s" % (label, status, body))
    return status, body


def main():
    status, body = step("GetCameraStatus", {"command": "GetCameraStatus"})
    if status != 200:
        print("\nCamera not reachable at %s. Connect this Mac to the camera's Wi-Fi first." % INET_ADDRESS_CAMERA)
        sys.exit(1)

    status, body = step("RCStartRemoteCtl", {"command": "RCStartRemoteCtl"})
    if status != 200:
        print("RCStartRemoteCtl failed, aborting.")
        sys.exit(1)

    try:
        step("RCChooseColorMode(NaturalBW)", {"command": "RCChooseColorMode", "ColorMode": "NaturalBW"})
        time.sleep(1.0)

        step("VideoRecordingStart", {"command": "VideoRecordingStart"})
        print("  (recording 3s in black & white color mode)")
        time.sleep(3.0)
        step("VideoRecordingStop", {"command": "VideoRecordingStop"})

        step("RCChooseColorMode(Standard) - restoring", {"command": "RCChooseColorMode", "ColorMode": "Standard"})

        print("\nCheck the newest .MP4 on the camera's SD card:")
        print("  - Black & white  -> RC 'Set' commands DO affect video recording, not just stills.")
        print("  - Normal color   -> they only affect the photo pipeline, video ignores them.")

    finally:
        status, body = step("RCStopRemoteCtl", {"command": "RCStopRemoteCtl"})


if __name__ == "__main__":
    main()
