#!/usr/bin/env python3
"""
Follow-up probe: PauseMovieStream/ResumeMovieStream returned HTTP 200 in
probe_movie_stream.py, but had no visible effect on the idle live-view UDP
stream. Hypothesis: "MovieStream" refers to an actual VideoRecordingStart
recording in progress, not the passive live-view preview.

This starts a REAL video recording (writes a file to the SD card, same as
the already-confirmed-working VideoRecordingStart/Stop), tries to pause it
mid-recording, waits, resumes, then stops. If pause genuinely works, the
resulting video file's actual duration will be shorter than the wall-clock
time between VideoRecordingStart and VideoRecordingStop (the paused period
won't be encoded). If pause does nothing, the file duration will match the
full wall-clock elapsed time.

Requires this Mac to already be on the camera's Wi-Fi (192.168.0.10 reachable).

Usage:
    cd yi-m1-remote-control
    source venv/bin/activate
    python3 probe_movie_stream_pause_recording.py

After it finishes, find the newest .MP4 on the camera's SD card and check
its actual duration, e.g.:
    ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1 <file.MP4>
Compare that to the "Wall-clock elapsed" line this script prints.
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

        time.sleep(2.0)
        step("PauseMovieStream", {"command": "PauseMovieStream"})

        print("  (paused - waiting 3s before resuming)")
        time.sleep(3.0)
        step("ResumeMovieStream", {"command": "ResumeMovieStream"})

        time.sleep(2.0)
        step("VideoRecordingStop", {"command": "VideoRecordingStop"})
        t1 = time.time()

        print("\nWall-clock elapsed (Start -> Stop): %.2fs" % (t1 - t0))
        print("If pause genuinely worked, the recorded file's actual duration should be")
        print("meaningfully shorter than this (roughly 4s of real recording vs the ~3s pause")
        print("period not counted). If pause did nothing, file duration should match closely.")

    finally:
        status, body = step("RCStopRemoteCtl", {"command": "RCStopRemoteCtl"})


if __name__ == "__main__":
    main()
