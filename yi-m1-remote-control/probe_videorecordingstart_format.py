#!/usr/bin/env python3
"""
Hypothesis: RCVideoFormatSet is a confirmed dead command (404), but maybe the video
format/resolution parameter is meant to be passed directly on VideoRecordingStart itself
(as a single "start recording in mode X" call), not set ahead of time via a separate command.
VideoRecordingStart has only ever been tested bare (no extra fields) - never with a format
parameter attached.

For each (key, value) candidate, this sends VideoRecordingStart with that extra field, checks
the live-view metadata's "VideoFormat" field ~1s later (a real-time indicator of current
mode), then immediately stops. If none of the quick checks show a change, nothing longer is
recorded. If one looks promising, a final longer (4s) confirmatory recording is made so the
actual resulting file's resolution can be checked with ffprobe afterward.

Requires this Mac to already be on the camera's Wi-Fi (192.168.0.10 reachable).

Usage:
    cd yi-m1-remote-control
    source venv/bin/activate
    python3 probe_videorecordingstart_format.py
"""
import json
import socket
import sys
import time

from urllib3 import PoolManager

from prot_http.const_wifi import INET_ADDRESS_CAMERA, UDP_PORT_LIVEVIEW

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
    print("%-55s -> status=%s body=%s" % (label, status, body))
    return status, body


def read_current_video_format(window=1.5):
    """Listen briefly on the live-view UDP port and pull VideoFormat out of the next frame's
    metadata header, the same way CameraSession._parse_live_metadata does."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("", UDP_PORT_LIVEVIEW))
    sock.settimeout(0.3)
    deadline = time.time() + window
    frame_data = bytearray()
    frame_idx = None
    last_packet = -1
    frame_valid = True
    try:
        while time.time() < deadline:
            try:
                pack, _addr = sock.recvfrom(1024000)
            except socket.timeout:
                continue
            if len(pack) < 12:
                continue
            idx_frame = int.from_bytes(pack[:4], "big")
            len_packet_frame = int.from_bytes(pack[4:8], "big")
            idx_packet_frame = int.from_bytes(pack[8:12], "big")
            if frame_idx != idx_frame:
                frame_data = bytearray()
                frame_idx = idx_frame
                last_packet = -1
                frame_valid = True
            if frame_valid:
                if (idx_packet_frame - 1) == last_packet:
                    frame_data.extend(pack[12:])
                    last_packet = idx_packet_frame
                else:
                    frame_valid = False
                    continue
                if last_packet == len_packet_frame - 1 and len(frame_data) > 2048:
                    header = bytes(frame_data[:2048])
                    try:
                        text = header.split(b"\x00", 1)[0].decode("utf-8", errors="strict")
                        parsed = json.loads(text)
                        return parsed.get("VideoFormat")
                    except Exception:
                        pass
                    frame_data = bytearray()
    finally:
        sock.close()
    return None


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
        baseline_format = read_current_video_format()
        print("\nBaseline VideoFormat (before any test): %r\n" % baseline_format)

        candidates = [
            ("VideoFormat", "4K_30"),
            ("VideoFormat", "2K_30"),
            ("Value", "4K_30"),
            ("Value", "2K_30"),
            ("Mode", "4K_30"),
            ("Mode", "2K_30"),
        ]

        winner = None
        for key, value in candidates:
            label = "VideoRecordingStart + %s=%s" % (key, value)
            status, body = step(label, {"command": "VideoRecordingStart", key: value})
            observed = read_current_video_format()
            print("    -> observed VideoFormat right after: %r" % observed)
            step("  VideoRecordingStop (cleanup)", {"command": "VideoRecordingStop"})
            time.sleep(0.5)
            if observed and observed != baseline_format:
                print("    *** CHANGED from baseline - candidate looks promising ***")
                winner = (key, value, observed)

        if winner:
            key, value, observed = winner
            print("\n=== Promising candidate found: %s=%s (observed VideoFormat=%r) ===" % (key, value, observed))
            print("Recording a longer confirmatory clip now - check its actual resolution with ffprobe afterward.")
            step("VideoRecordingStart + %s=%s (confirmatory)" % (key, value),
                 {"command": "VideoRecordingStart", key: value})
            time.sleep(4.0)
            step("VideoRecordingStop", {"command": "VideoRecordingStop"})
        else:
            print("\nNo candidate changed the reported VideoFormat - parameter-on-start hypothesis not supported "
                  "by any of the tried (key, value) combinations.")

    finally:
        step("RCStopRemoteCtl", {"command": "RCStopRemoteCtl"})


if __name__ == "__main__":
    main()
