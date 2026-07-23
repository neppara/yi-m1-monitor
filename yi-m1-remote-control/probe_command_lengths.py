import json
import os
import socket
import threading
import time
from datetime import datetime
from urllib3 import PoolManager

from prot_ble import trigger_remote_control_closest

INET_ADDRESS_CAMERA = "192.168.0.10"
UDP_PORT_LIVEVIEW = 54321
OUTPUT_ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fable research", "wifi-experiment-results")
OUTPUT_DIR = os.path.join(OUTPUT_ROOT, "run_%s_length_hypothesis" % datetime.now().strftime("%Y%m%d_%H%M%S"))
os.makedirs(OUTPUT_DIR, exist_ok=True)

log_lines = []
def log(msg):
    print(msg, flush=True)
    log_lines.append(msg)

http = PoolManager()

def send(cmd_name, timeout=3.0):
    json_str = json.dumps({"command": cmd_name}, separators=(",", ":"))
    url = "http://%s/?data=%s" % (INET_ADDRESS_CAMERA, json_str)
    try:
        response = http.request("GET", url, timeout=timeout)
        body = response.data.decode("utf-8", errors="replace")
        return response.status, body
    except Exception as e:
        return None, repr(e)

udp_packet_count = 0
udp_keep_listening = True

def udp_listener():
    """Just receive and discard live-view UDP packets. Some evidence suggests the
    camera's RC command dispatcher only marks itself 'ready' once it detects an
    active listener on this port - without this, every RC command may 404
    regardless of content (observed in the previous test run)."""
    global udp_packet_count
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.bind(("", UDP_PORT_LIVEVIEW))
        sock.settimeout(1.0)
        while udp_keep_listening:
            try:
                sock.recvfrom(1024000)
                udp_packet_count += 1
            except socket.timeout:
                continue
            except Exception:
                continue

def pair_via_ble():
    log("=== BLE pairing ===")
    result = trigger_remote_control_closest()
    if result is None:
        log("Pairing failed.")
        raise SystemExit(1)
    ssid, password = result
    log("SSID: %s  Pass: %s" % (ssid, password))
    print("\nSwitch this Mac's Wi-Fi to that network now.")
    input("Press Enter once connected... ")

def main():
    global udp_keep_listening
    pair_via_ble()

    listener_thread = threading.Thread(target=udp_listener, daemon=True)
    listener_thread.start()

    status, body = send("GetCameraStatus")
    log("sanity GetCameraStatus -> %s %s" % (status, body))
    if status != 200:
        log("Camera not reachable, aborting.")
        return

    status, body = send("RCStartRemoteCtl")
    log("RCStartRemoteCtl -> %s %s" % (status, body))

    log("Waiting 4s for UDP live-view stream / readiness flag to settle (packets so far: %d)..." % udp_packet_count)
    time.sleep(4.0)
    log("UDP packets received during wait: %d" % udp_packet_count)

    log("\n=== Sanity re-check: known-working commands (must succeed, or the whole test is inconclusive) ===")
    status, body = send("RCISOSet")  # deliberately no value param - just checking command recognition
    log("RCISOSet (bare) -> %s %s" % (status, body))
    status, body = send("RCImageAspect")
    log("RCImageAspect (bare) -> %s %s" % (status, body))

    # Ordered by length, bracketing the known-failing RCVideoFormatSet (16 chars).
    candidates = [
        "RCEVSet",             # 7  - known working pattern (RC*Set)
        "RCISOSet",            # 8  - CONFIRMED working (baseline)
        "RCImageAspect",       # 13 - CONFIRMED working
        "RCDriveModeSet",      # 14 - untested
        "RCFileFormatSet",     # 15 - untested
        "RCVideoFormatSet",    # 16 - CONFIRMED FAILING (404) - retest
        "RCShutterSpeedSet",   # 17 - untested - KEY hypothesis test
        "RCImageQualitySet",   # 17 - untested - same-length control
        "RCChooseColorMode",   # 17 - untested - same-length control, different naming pattern
        "RCVANoiseReduceSet",  # 18 - CONFIRMED FAILING (404) - retest
    ]

    log("\n=== Length-bracketing probe ===")
    for cmd in candidates:
        status, body = send(cmd)
        log("[len=%2d] %-20s -> status=%s body=%s" % (len(cmd), cmd, status, body[:150]))
        time.sleep(1.0)

    status, body = send("RCStopRemoteCtl")
    log("\nRCStopRemoteCtl -> %s %s" % (status, body))

    udp_keep_listening = False
    log("Total UDP live-view packets received: %d" % udp_packet_count)

    with open(os.path.join(OUTPUT_DIR, "log.txt"), "w") as f:
        f.write("\n".join(log_lines))
    print("\n=== DONE. Results saved to: %s ===" % OUTPUT_DIR)

if __name__ == "__main__":
    main()
