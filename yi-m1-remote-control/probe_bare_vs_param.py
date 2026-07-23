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
OUTPUT_DIR = os.path.join(OUTPUT_ROOT, "run_%s_bare_vs_param" % datetime.now().strftime("%Y%m%d_%H%M%S"))
os.makedirs(OUTPUT_DIR, exist_ok=True)

log_lines = []
def log(msg):
    print(msg, flush=True)
    log_lines.append(msg)

http = PoolManager()

def send(cmd_dict, timeout=3.0):
    json_str = json.dumps(cmd_dict, separators=(",", ":"))
    url = "http://%s/?data=%s" % (INET_ADDRESS_CAMERA, json_str)
    try:
        response = http.request("GET", url, timeout=timeout)
        return response.status, response.data.decode("utf-8", errors="replace")
    except Exception as e:
        return None, repr(e)

udp_packet_count = 0
udp_keep_listening = True

def udp_listener():
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

    status, body = send({"command": "GetCameraStatus"})
    log("GetCameraStatus (pre-RC) -> %s %s" % (status, body))

    status, body = send({"command": "RCStartRemoteCtl"})
    log("RCStartRemoteCtl -> %s %s" % (status, body))

    time.sleep(4.0)
    log("UDP packets so far: %d" % udp_packet_count)

    log("\n=== Decisive test: known-good commands WITH their required parameter ===")
    status, body = send({"command": "RCISOSet", "ISO": "Auto"})
    log("RCISOSet + ISO=Auto -> %s %s" % (status, body))

    status, body = send({"command": "RCImageAspect", "ImageAspect": "4:3"})
    log("RCImageAspect + ImageAspect=4:3 -> %s %s" % (status, body))

    log("\n=== Same commands, bare (no parameter), for direct comparison ===")
    status, body = send({"command": "RCISOSet"})
    log("RCISOSet (bare) -> %s %s" % (status, body))

    status, body = send({"command": "RCImageAspect"})
    log("RCImageAspect (bare) -> %s %s" % (status, body))

    log("\n=== If the param-based ones worked, retry RCVideoFormatSet with a parameter too ===")
    for key in ["VideoFormat", "Value", "Mode"]:
        status, body = send({"command": "RCVideoFormatSet", key: "FHD_30"})
        log("RCVideoFormatSet + %s=FHD_30 -> %s %s" % (key, status, body))
        time.sleep(1.0)

    status, body = send({"command": "RCStopRemoteCtl"})
    log("\nRCStopRemoteCtl -> %s %s" % (status, body))

    udp_keep_listening = False
    log("Total UDP packets: %d" % udp_packet_count)

    with open(os.path.join(OUTPUT_DIR, "log.txt"), "w") as f:
        f.write("\n".join(log_lines))
    print("\n=== DONE. Results saved to: %s ===" % OUTPUT_DIR)

if __name__ == "__main__":
    main()
