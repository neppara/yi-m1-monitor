#!/usr/bin/env python3
"""
One-off probe for StartMovieStream / PauseMovieStream / ResumeMovieStream /
StopMovieStream - never tested against the real camera before (see
"fable research/ghidra-disassembly-findings.md" dispatch table, and the
GUI-app command inventory discussion). These are action-type commands (no
"Set" value, same shape as RCDoShooting/VideoRecordingStart which are
confirmed to work bare), so a bare {"command": "..."} body should be
conclusive - no need to guess parameter names like RCVideoFormatSet.

Requires this Mac to already be on the camera's Wi-Fi network (192.168.0.10
reachable). Run the GUI app and click Connect first, or join manually.

Usage:
    cd yi-m1-remote-control
    source venv/bin/activate
    python3 probe_movie_stream.py
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


def count_udp_packets(seconds):
    """Count UDP live-view packets and total bytes arriving in a window, so we can see
    whether a movie-stream command actually changes what's coming in on this port (more
    data = real video stream, no change = command is a no-op or targets something else)."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("", UDP_PORT_LIVEVIEW))
    sock.settimeout(0.3)
    deadline = time.time() + seconds
    packets = 0
    total_bytes = 0
    try:
        while time.time() < deadline:
            try:
                pack, _addr = sock.recvfrom(1024000)
                packets += 1
                total_bytes += len(pack)
            except socket.timeout:
                continue
    finally:
        sock.close()
    return packets, total_bytes


def step(label, command_dict=None, udp_window=3.0):
    print("\n=== %s ===" % label)
    if command_dict is not None:
        status, body = send(command_dict)
        print("  -> status=%s body=%s" % (status, body[:300] if isinstance(body, str) else body))
    packets, total_bytes = count_udp_packets(udp_window)
    print("  UDP port %d over %.1fs: %d packets, %d bytes" % (UDP_PORT_LIVEVIEW, udp_window, packets, total_bytes))
    return packets, total_bytes


def main():
    print("Checking camera reachability...")
    status, body = send({"command": "GetCameraStatus"})
    print("GetCameraStatus -> %s %s" % (status, body[:200] if isinstance(body, str) else body))
    if status != 200:
        print("\nCamera not reachable at %s. Connect this Mac to the camera's Wi-Fi first "
              "(run the GUI app and click Connect, or join manually), then re-run this script." % INET_ADDRESS_CAMERA)
        sys.exit(1)

    status, body = send({"command": "RCStartRemoteCtl"})
    print("RCStartRemoteCtl -> %s %s" % (status, body))
    if status != 200:
        print("RCStartRemoteCtl failed, aborting.")
        sys.exit(1)

    try:
        # Baseline: what does the UDP port look like with no movie-stream command sent at all,
        # in whatever state the camera is already in (e.g. still image live view)?
        step("Baseline (before any MovieStream command)")

        step("StartMovieStream", {"command": "StartMovieStream"})
        step("... still watching after StartMovieStream")

        step("PauseMovieStream", {"command": "PauseMovieStream"})

        step("ResumeMovieStream", {"command": "ResumeMovieStream"})

        step("StopMovieStream", {"command": "StopMovieStream"})
        step("... still watching after StopMovieStream")

    finally:
        status, body = send({"command": "RCStopRemoteCtl"})
        print("\nRCStopRemoteCtl -> %s %s" % (status, body))


if __name__ == "__main__":
    main()
