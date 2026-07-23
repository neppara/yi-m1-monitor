#!/usr/bin/env python3
"""
Control experiment for probe_movie_stream_pause_recording.py: same overall
timing (Start, wait ~7s, Stop) but WITHOUT sending PauseMovieStream/
ResumeMovieStream in between. Needed because the relationship between
"wall-clock time between our Start/Stop commands" and "actual recorded file
duration" is already known to be non-trivial (an earlier test: a ~0.6s gap
between commands produced a 1.001s file - longer than the gap, not equal to
it). Without this control, a 7s file from the paused run is not meaningful
on its own - it could equally mean "pause trimmed the file" or "this is just
the normal relationship with no pause effect at all".

Requires this Mac to already be on the camera's Wi-Fi (192.168.0.10 reachable).

Usage:
    cd yi-m1-remote-control
    source venv/bin/activate
    python3 probe_video_duration_baseline.py

Then check the resulting file's duration the same way as before and compare
directly against the paused run's file duration (7s) and this run's
"Wall-clock elapsed" number.
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
    print("%-22s -> status=%s body=%s" % (label, status, body))
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
        t0 = time.time()
        status, body = step("VideoRecordingStart", {"command": "VideoRecordingStart"})
        if status != 200:
            print("VideoRecordingStart failed, aborting.")
            return

        print("  (recording continuously for 7s, no pause commands sent)")
        time.sleep(7.0)

        step("VideoRecordingStop", {"command": "VideoRecordingStop"})
        t1 = time.time()

        print("\nWall-clock elapsed (Start -> Stop): %.2fs" % (t1 - t0))
        print("Compare the resulting file's duration to this number AND to the 7s file")
        print("from the paused run - that three-way comparison is what tells us whether")
        print("Pause/Resume actually did anything.")

    finally:
        status, body = step("RCStopRemoteCtl", {"command": "RCStopRemoteCtl"})


if __name__ == "__main__":
    main()
