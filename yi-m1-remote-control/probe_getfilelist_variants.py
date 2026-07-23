#!/usr/bin/env python3
"""
Bug #11 (app/ARCHITECTURE.md): GetFileList returns a real camera-side error,
{"code":1502,"data":"get filelist err"}, instead of a file list. Not a transport/parsing
problem - this is what the camera itself sends back.

Tests the leading hypotheses one at a time, in both states (no active RC session, and with
one), so we can tell whether the RC session state matters as well as which parameters matter:
  - bare (no extra fields at all)
  - filetype="all", range 0..0 (today's actual default via CmdFileList() - reproduces the bug)
  - filetype="all", range 0..50
  - filetype="JPG", range 0..50
  - filetype="DNG", range 0..50
  - filetype="ALL" (uppercase - in case the camera is case-sensitive and wants a different string)

Requires this Mac to already be on the camera's Wi-Fi (192.168.0.10 reachable).

Usage:
    cd yi-m1-remote-control
    source venv/bin/activate
    python3 probe_getfilelist_variants.py
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
    print("%-45s -> status=%s body=%s" % (label, status, body))
    return status, body


def run_variants(phase_label):
    print("\n--- %s ---" % phase_label)
    step("GetFileList (bare)", {"command": "GetFileList"})
    step("GetFileList filetype=all range=0..0 (current default)",
         {"command": "GetFileList", "range_start": "0", "range_end": "0", "filetype": "all"})
    step("GetFileList filetype=all range=0..50",
         {"command": "GetFileList", "range_start": "0", "range_end": "50", "filetype": "all"})
    step("GetFileList filetype=JPG range=0..50",
         {"command": "GetFileList", "range_start": "0", "range_end": "50", "filetype": "JPG"})
    step("GetFileList filetype=DNG range=0..50",
         {"command": "GetFileList", "range_start": "0", "range_end": "50", "filetype": "DNG"})
    step("GetFileList filetype=ALL (uppercase) range=0..50",
         {"command": "GetFileList", "range_start": "0", "range_end": "50", "filetype": "ALL"})


def main():
    status, body = step("GetCameraStatus", {"command": "GetCameraStatus"})
    if status != 200:
        print("\nCamera not reachable at %s. Connect this Mac to the camera's Wi-Fi first." % INET_ADDRESS_CAMERA)
        sys.exit(1)

    run_variants("Phase A: before RCStartRemoteCtl (no RC session active)")

    status, body = step("RCStartRemoteCtl", {"command": "RCStartRemoteCtl"})
    if status != 200:
        print("RCStartRemoteCtl failed, skipping phase B.")
        sys.exit(1)

    time.sleep(1.0)
    run_variants("Phase B: with RC session active")

    step("RCStopRemoteCtl", {"command": "RCStopRemoteCtl"})

    print("\nCompare the two phases and the variants above - whichever combination returns")
    print("something other than {'code':1502,...} is the fix for CmdFileList/FileBrowserDialog.")


if __name__ == "__main__":
    main()
