"""
Background session thread for the YI M1 monitor app.

Owns the full connection lifecycle: BLE pairing -> Wi-Fi switch -> RC session ->
live-view UDP stream -> periodic status polling. Talks to the UI only via Qt
signals (thread-safe) and a request queue (for outgoing commands).
"""
import io
import json
import os
import queue
import socket
import subprocess
import time
from typing import Optional

from PySide6.QtCore import QThread, Signal
from PySide6.QtGui import QImage
from urllib3 import PoolManager

from prot_ble import trigger_remote_control_closest
from prot_http.const_wifi import INET_ADDRESS_CAMERA, UDP_PORT_LIVEVIEW
from prot_http.command_http import CmdFileList, CmdFileGet
from prot_http.const_http_enum_extra import CmdEnumFileQuality


def log(msg):
    """Terminal-visible logging for this module. The UI only shows the latest status via Qt
    signals (see MainWindow._on_* handlers) - this is for diagnosing what's actually
    happening step by step from Terminal.app, since that's the only place these prints go."""
    print("[session] %s" % msg, flush=True)


def get_wifi_device() -> Optional[str]:
    """Find the macOS network device name for the Wi-Fi hardware port (e.g. en0, en1).

    Not hardcoded because this differs between Macs (e.g. Mac mini vs MacBook)."""
    try:
        out = subprocess.check_output(["networksetup", "-listallhardwareports"], text=True)
    except Exception:
        return None
    lines = out.splitlines()
    for i, line in enumerate(lines):
        if line.strip() == "Hardware Port: Wi-Fi":
            for j in range(i + 1, min(i + 3, len(lines))):
                if lines[j].startswith("Device: "):
                    return lines[j].split("Device: ", 1)[1].strip()
    return None


def get_current_wifi_ssid(device: str) -> Optional[str]:
    try:
        out = subprocess.check_output(["networksetup", "-getairportnetwork", device], text=True)
        if ":" in out:
            return out.split(":", 1)[1].strip()
    except Exception:
        pass
    return None


def get_current_wifi_ssid_via_system_profiler() -> Optional[str]:
    """CoreWLAN-free current-SSID detection (M5, 2026-07-12). `get_current_wifi_ssid` above
    (networksetup -getairportnetwork) requires Location Services authorization on modern macOS
    and silently reports "You are not associated with an AirPort network" without it - live
    testing (bug #8) showed it reporting that for 35+ seconds while the Mac's own Wi-Fi menu
    clearly showed a real connection the whole time.

    `system_profiler SPAirPortDataType -json` needs no such permission - empirically confirmed
    on a real Mac (2026-07-12): a plain unprivileged process gets the actual joined SSID back at
    `SPAirPortDataType[0].spairport_airport_interfaces[0].spairport_current_network_information._name`.
    Used as the PRIMARY auto-detect now; `get_current_wifi_ssid` and the manual "restore to"
    setting are both kept as fallbacks for whenever this doesn't work (a different macOS
    version, no Wi-Fi interface present, etc.) - see _do_connect's capture chain."""
    try:
        out = subprocess.check_output(
            ["system_profiler", "SPAirPortDataType", "-json"], text=True, timeout=5.0,
        )
        data = json.loads(out)
        interfaces = data.get("SPAirPortDataType", [{}])[0].get("spairport_airport_interfaces", [])
        if not interfaces:
            return None
        current = interfaces[0].get("spairport_current_network_information")
        if not isinstance(current, dict):
            return None
        name = current.get("_name")
        return name if isinstance(name, str) and name else None
    except Exception:
        return None


def is_camera_success(status: Optional[int], body: str) -> bool:
    """The camera signals command failures as HTTP 200 + `{"code":<err>}` in the JSON body, not
    via HTTP status - checking transport status alone lets a body-level failure look like
    success. Ported from the iOS app's `HTTPClient.Response.isCameraSuccess` (M1, 2026-07-12;
    see yi-m1-ios/DEVELOPMENT_PLAN.md's 2026-07-09 recording-desync fix, which found this exact
    bug over there first: 1515 "rc only one", 1502 "get filelist err", and a rapid record
    start/stop cycle wedging the camera while this app's `status == 200` check kept reporting
    success). Semantics mirror iOS exactly: transport 200 is required; a body that isn't a JSON
    object, or has no "code" field, counts as success (matches responses like the raw-bytes
    GetFile download body, which is never JSON)."""
    if status != 200:
        return False
    try:
        obj = json.loads(body)
    except Exception:
        return True
    if not isinstance(obj, dict):
        return True
    code = obj.get("code")
    if isinstance(code, int):
        return code == 200
    if isinstance(code, str):
        try:
            return int(code) == 200
        except ValueError:
            return True
    return True


class CameraSession(QThread):
    paired = Signal(str, str)              # ssid, password
    wifiSwitched = Signal()
    connected = Signal()                    # RCStartRemoteCtl succeeded, live view starting
    frameReady = Signal(QImage)
    statusUpdated = Signal(dict)            # parsed GetCameraStatus "data" dict
    liveMetadataUpdated = Signal(dict)      # parsed JSON header embedded in each live-view UDP frame
    commandResult = Signal(str, int, str)   # command name, HTTP status (0 on transport error), body
    fileDownloaded = Signal(str, bool, str) # save path, success, message
    fileDownloadProgress = Signal(int, int) # bytes downloaded so far, total (-1 if unknown) - for FileBrowserDialog
    # File-browser parity with iOS (2026-07-19): per-row thumbnails and a double-click preview,
    # both fetched in-memory (no disk write) through the same serial request queue.
    thumbReady = Signal(str, QImage)        # camera file path, decoded Thumbnail-quality image
    previewReady = Signal(str, QImage)      # camera file path, decoded MidThumb-quality image
    photoReviewProgress = Signal(int, int)  # bytes downloaded so far, total (-1 if unknown)
    photoReviewReady = Signal(QImage)       # decoded preview of the just-taken photo
    photoReviewFailed = Signal(str)         # reason (shown briefly, not a hard error)
    recordingStateChanged = Signal(bool)
    # Clip N of the current recording session (M6, 2026-07-12) - 1 for the first clip,
    # incremented on each successful auto-restart.
    recordingClipNumberChanged = Signal(int)
    errorOccurred = Signal(str)
    disconnected = Signal()
    # Distinct from errorOccurred+disconnected (M2, 2026-07-12): those two firing back-to-back
    # let _on_disconnected's generic "Disconnected" status clobber the specific reason that was
    # just set by _on_error, since both are separate slots run in emission order. One combined
    # signal sidesteps that ordering fragility entirely - see MainWindow._on_connection_lost.
    connectionLost = Signal(str)

    # Held after every record command (start/stop/force-stop) - the firmware needs a beat to
    # finalize a file before the next one; the iOS app wedged the real camera by cycling faster
    # than this (2026-07-09), which is what this cooldown was ported from (M1, 2026-07-12).
    RECORD_COMMAND_COOLDOWN = 1.5

    # Consecutive GetCameraStatus failures (timeout, unreachable, bad response) tolerated in
    # run()'s 5s poll before declaring the connection lost (M2, 2026-07-12, ported from the iOS
    # app) - the camera has no way to notify us when it drops (powered off, out of range,
    # screen-locked, etc.), so this poll doubles as the only signal available. 3 tries at the 5s
    # interval (~15s) tolerates a brief Wi-Fi blip without flapping on a transient hiccup.
    CONSECUTIVE_STATUS_FAILURES_LIMIT = 3

    # Recording auto-restart per-format intervals (M6, 2026-07-12, ported from the iOS app's
    # RecordingAutoRestart - same values, same reasoning; margins tightened by the user after
    # the first confirmed-working field run, the fps-signature detector is the safety net):
    # - FHD: 5s under the ~30-min general recording cap.
    # - 4K: 6s under the field-measured 7:29/~4096MB stop (4GB FAT32 file ceiling).
    # - 2K (2048x1536, 4:3 full-sensor downscale): 10s under the general 30-min cap - the only
    #   limit documented for it; if its (unmeasured) bitrate exceeds ~18 Mbit/s the 4GB ceiling
    #   arrives before 30 minutes and this timer misses it - the fps detector covers that case.
    RECORDING_AUTO_RESTART_FHD_INTERVAL = 29 * 60 + 55
    RECORDING_AUTO_RESTART_4K_INTERVAL = 7 * 60 + 23
    RECORDING_AUTO_RESTART_2K_INTERVAL = 29 * 60 + 50

    def __init__(self):
        super().__init__()
        self._http = PoolManager()
        self._requests: "queue.Queue[tuple]" = queue.Queue()
        # Low-priority side queue for file-browser thumbnails - see request_file_thumbnail.
        self._thumb_requests: "queue.Queue[str]" = queue.Queue()
        self._running = False
        self._previous_ssid: Optional[str] = None
        self._wifi_device: Optional[str] = None
        self._is_recording = False
        self._metadata_parse_failed_once = False
        self._last_record_command_at = 0.0
        # User-configured fallback for the previous-Wi-Fi-network capture (M5, 2026-07-12) -
        # only consulted when the auto-detects (system_profiler, then networksetup) both fail.
        # Set by MainWindow right after construction from a QSettings-persisted value.
        self.manual_restore_ssid: Optional[str] = None
        # Recording auto-restart (M6, 2026-07-12) - user toggle (default off, set by MainWindow's
        # checkable menu action), current clip number (1 for the first clip, incremented per
        # restart), wall-clock start of the CURRENT clip (monotonic, reset on each restart), and
        # the last VideoFormat seen in live-view metadata (drives which per-format interval
        # applies - see _recording_restart_interval).
        self.auto_restart_recording: bool = False
        self.recording_clip_number: int = 1
        self._recording_started_at: Optional[float] = None
        self._last_video_format: Optional[str] = None
        # Camera-self-stop detection via the live-view fps signature (2026-07-12, ported from
        # the iOS app; field-confirmed camera fact: while recording, the camera throttles live
        # view to ~7.5fps, jumping back to ~30 the instant recording ends). The detector ARMS
        # only after two consecutive slow 5s samples while recording (proof that THIS format
        # actually throttles - self-calibrating, a non-throttling format can never
        # false-trigger), then fires after two consecutive fast samples.
        self._recording_throttle_armed = False
        self._slow_samples_while_recording = 0
        self._fast_samples_while_recording = 0

    # ---- public API, called from the UI thread ----

    def request_connect(self):
        self._requests.put(("connect",))

    def request_connect_direct(self):
        """Skip BLE pairing and the Wi-Fi switch entirely and go straight to talking HTTP to
        192.168.0.10. For when the Mac is *already* joined to the camera's Wi-Fi network (e.g.
        the app was restarted, or the user joined it manually) - in that state a fresh BLE
        pairing attempt is unnecessary and may not even work, since the camera appears to stop
        answering/advertising over BLE while it already has an active Wi-Fi client (observed
        during testing - see app/ARCHITECTURE.md bug #8's side note)."""
        self._requests.put(("connect_direct",))

    def request_disconnect(self):
        self._requests.put(("disconnect",))

    def request_command(self, command_dict: dict):
        self._requests.put(("send", command_dict))

    def request_file_download(self, command_dict: dict, save_path: str):
        """Like request_command, but for GetFile: preserves raw response bytes instead of
        decoding them as UTF-8 text (regular _send() would corrupt binary image/video data -
        see _do_download for why this needs its own code path)."""
        self._requests.put(("download", command_dict, save_path))

    def request_file_thumbnail(self, path: str):
        """Fetch a Thumbnail-quality image of a camera file in-memory (a few KB) - for the file
        browser's per-row icons (2026-07-19, iOS parity). Thumbnails go through their OWN
        low-priority queue (2026-07-19 audit find): the browser queues one per listed file, and
        in the main queue a user command (record toggle!) issued right after opening the
        browser would have sat behind the whole batch. The live-view loop services at most one
        thumbnail per pass, only after the main queue has been fully drained."""
        self._thumb_requests.put(path)

    def cancel_pending_thumbnails(self):
        """Called when the file browser closes - whatever thumbnails are still queued would be
        fetched into a void (the dialog's signal connections are gone)."""
        while True:
            try:
                self._thumb_requests.get_nowait()
            except queue.Empty:
                return

    def request_file_preview(self, path: str):
        """Fetch a MidThumb-quality image (~228KB, confirmed vs ~32MB originals) in-memory -
        for the file browser's double-click preview (2026-07-19, iOS parity)."""
        self._requests.put(("preview", path))

    def request_toggle_recording(self):
        self._requests.put(("toggle_recording",))

    def request_force_stop_recording(self):
        """Escape hatch for a desynced camera (M1, 2026-07-12, ported from the iOS app's
        `forceStopRecording()`): sends VideoRecordingStop regardless of what `_is_recording`
        believes, and trusts the caller - the flag is cleared even if the camera answers with an
        error (which it will, harmlessly, if it genuinely wasn't recording)."""
        self._requests.put(("force_stop",))

    def request_shoot_with_review(self):
        """Take a photo (RCDoShooting), then find and download a quick preview of it for a
        brief "chimp review" - see _do_shoot_and_review for the full flow."""
        self._requests.put(("shoot_review",))

    def stop(self):
        self._running = False
        self._requests.put(("quit",))

    # ---- internal helpers (run on this thread only) ----

    def _send(self, command_dict: dict, timeout=3.0):
        json_str = json.dumps(command_dict, separators=(",", ":"))
        url = "http://%s/?data=%s" % (INET_ADDRESS_CAMERA, json_str)
        try:
            response = self._http.request("GET", url, timeout=timeout)
            body = response.data.decode("utf-8", errors="replace")
            return response.status, body
        except Exception as e:
            return None, repr(e)

    def _parse_live_metadata(self, header_bytes: bytes) -> Optional[dict]:
        """The first 2048 bytes of every assembled live-view frame are a fixed-size,
        null-padded JSON header (current ISO/WB/exposure mode/etc - confirmed by direct
        inspection during the 2026-07-02 test run, see fable research/live-testing-findings.md)
        that used to be discarded entirely before the JPEG bytes were extracted. Parsing it
        lets the settings panel show/sync the camera's actual current values instead of only
        ever showing what we last *sent*, which matters given some commands (RCVideoFormatSet
        and friends) silently do nothing despite returning 200/404 - this is a way to notice
        that from the UI instead of just trusting the HTTP response."""
        try:
            text = header_bytes.split(b"\x00", 1)[0].decode("utf-8", errors="strict")
            return json.loads(text)
        except Exception:
            if not self._metadata_parse_failed_once:
                self._metadata_parse_failed_once = True
                log("_parse_live_metadata: could not parse frame header as JSON (logged once, "
                    "will not spam this on every frame) - header preview: %r" % header_bytes[:120])
            return None

    def _do_connect(self):
        log("_do_connect: starting")
        self._wifi_device = get_wifi_device()
        log("_do_connect: wifi device = %r" % self._wifi_device)
        if self._wifi_device:
            # Capture chain (M5, 2026-07-12): system_profiler first (works without Location
            # Services - see get_current_wifi_ssid_via_system_profiler's doc comment), then the
            # older CoreWLAN-touching method as a bonus in case it happens to work, then the
            # user's manually-configured "restore to" network as the last resort.
            self._previous_ssid = get_current_wifi_ssid_via_system_profiler()
            if self._previous_ssid is None:
                self._previous_ssid = get_current_wifi_ssid(self._wifi_device)
            if self._previous_ssid is None and self.manual_restore_ssid:
                self._previous_ssid = self.manual_restore_ssid
            log("_do_connect: current SSID before switch = %r" % self._previous_ssid)

        log("_do_connect: calling trigger_remote_control_closest() - watch for [BLE] lines below")
        result = trigger_remote_control_closest()
        log("_do_connect: trigger_remote_control_closest() returned %r" % (result,))
        if result is None:
            self.errorOccurred.emit("BLE pairing failed. Make sure the camera is on and nearby, and try again.")
            return
        ssid, password = result
        self.paired.emit(ssid, password)

        if not self._wifi_device:
            self.errorOccurred.emit("Could not find the Wi-Fi hardware device name on this Mac.")
            return

        # The camera's Wi-Fi password is randomized per session (same SSID every time). If this
        # Mac already has a saved (now-stale) password for that SSID, macOS can silently keep
        # trying the old one instead of the new one we were just given. Forget it first so the
        # explicit -setairportnetwork call below is a clean join with the fresh password.
        log("_do_connect: forgetting any saved password for %r, then joining with the fresh one" % ssid)
        remove_result = subprocess.run(
            ["networksetup", "-removepreferredwirelessnetwork", self._wifi_device, ssid],
            capture_output=True, text=True,
        )
        log("_do_connect: -removepreferredwirelessnetwork -> rc=%s stdout=%r stderr=%r" % (
            remove_result.returncode, remove_result.stdout.strip(), remove_result.stderr.strip()))
        time.sleep(0.5)

        # networksetup -setairportnetwork frequently returns exit code 0 even when the join
        # hasn't actually completed (its exit status just means "request accepted"). We used
        # to try to verify this by re-reading the associated SSID via `networksetup
        # -getairportnetwork` / `get_current_wifi_ssid()` - that turned out to be unreliable
        # on its own: live testing showed it reporting "You are not associated with an
        # AirPort network" for 35+ seconds straight while the macOS Wi-Fi menu clearly showed
        # us connected to the camera's network the whole time. This is a known macOS quirk -
        # querying the *current* Wi-Fi SSID via these APIs can require Location Services
        # authorization for the calling process, and without it some tools report bogus
        # "not associated" regardless of actual state, rather than erroring out cleanly.
        #
        # Fix: stop trying to ask the OS "are we on the right SSID?" at all. We don't
        # actually care about the SSID as such - we care whether we can reach the camera,
        # which is both the *actual* thing we need and doesn't require any special
        # permission. So: issue the join command, then poll `GetCameraStatus` directly.
        log("_do_connect: issuing Wi-Fi join command...")
        join_result = subprocess.run(
            ["networksetup", "-setairportnetwork", self._wifi_device, ssid, password],
            capture_output=True, text=True,
        )
        log("_do_connect: -setairportnetwork -> rc=%s stdout=%r stderr=%r" % (
            join_result.returncode, join_result.stdout.strip(), join_result.stderr.strip()))
        self.wifiSwitched.emit()

        def poll_camera(seconds: float):
            deadline = time.time() + seconds
            while time.time() < deadline:
                s, b = self._send({"command": "GetCameraStatus"}, timeout=2.0)
                log("_do_connect: GetCameraStatus poll -> status=%s body=%s" % (s, b))
                if s == 200:
                    return s, b
                time.sleep(1.0)
            return None, None

        status, body = poll_camera(25.0)
        if status != 200:
            # No response in 25s - try issuing the join once more (in case the first
            # request never made it / was superseded) before giving up entirely.
            log("_do_connect: camera unreachable after 25s, retrying the join command once...")
            subprocess.run(
                ["networksetup", "-setairportnetwork", self._wifi_device, ssid, password],
                capture_output=True, text=True,
            )
            status, body = poll_camera(15.0)

        if status != 200:
            self.errorOccurred.emit(
                "Camera not reachable after ~40s (status=%s). Check the Wi-Fi menu bar - if "
                "it shows '%s' as connected but this still fails, the camera's Wi-Fi may not "
                "have an active DHCP lease yet; if it's still on a different network, join "
                "'%s' manually - password: %s" % (status, ssid, ssid, password)
            )
            return

        status, body = self._send({"command": "RCStartRemoteCtl"})
        log("_do_connect: RCStartRemoteCtl -> status=%s body=%s" % (status, body))
        if not is_camera_success(status, body):
            self.errorOccurred.emit("RCStartRemoteCtl failed (status=%s body=%s)." % (status, body))
            return

        self._running = True
        log("_do_connect: done, session is now running")
        self.connected.emit()

    def _do_connect_direct(self):
        """Same as the tail end of _do_connect (reachability check + RCStartRemoteCtl), but
        without any BLE pairing or Wi-Fi switching - for when the Mac is already on the
        camera's Wi-Fi network.

        Wi-Fi restore in this path (revised for M5, 2026-07-12): the AUTO-detects are useless
        here by definition - the Mac is already on the camera's network, so "current SSID"
        would capture the camera itself and Disconnect would pointlessly rejoin it. But the
        user still got onto the camera's network by manually leaving their own, so the
        manually-configured restore network (the M5 fallback field), when set, is exactly what
        Disconnect should return them to. Without it set, behavior stays as before: nothing to
        restore to."""
        log("_do_connect_direct: starting (assuming Mac is already on the camera's Wi-Fi)")
        if self.manual_restore_ssid:
            self._wifi_device = get_wifi_device()
            self._previous_ssid = self.manual_restore_ssid if self._wifi_device else None
            log("_do_connect_direct: will restore Wi-Fi to %r on disconnect (manual setting)"
                % self._previous_ssid)

        status, body = self._send({"command": "GetCameraStatus"}, timeout=3.0)
        log("_do_connect_direct: GetCameraStatus -> status=%s body=%s" % (status, body))
        if status != 200:
            self.errorOccurred.emit(
                "Camera not reachable at %s (status=%s). Make sure this Mac's Wi-Fi is "
                "actually joined to the camera's network first." % (INET_ADDRESS_CAMERA, status)
            )
            return

        status, body = self._send({"command": "RCStartRemoteCtl"})
        log("_do_connect_direct: RCStartRemoteCtl -> status=%s body=%s" % (status, body))
        if not is_camera_success(status, body):
            self.errorOccurred.emit("RCStartRemoteCtl failed (status=%s body=%s)." % (status, body))
            return

        self._running = True
        log("_do_connect_direct: done, session is now running")
        self.connected.emit()

    def _handle_connection_lost(self, reason: str):
        """The camera dropping off on its own end (powered off, out of Wi-Fi range, etc.) has no
        notification of its own - this is what actually detects it, via run()'s consecutive
        GetCameraStatus-failure counter (M2, 2026-07-12, ported from the iOS app's
        `handleConnectionLost`). Distinct from `_do_disconnect`: there's nothing reachable to
        send VideoRecordingStop/RCStopRemoteCtl to, so this skips those and just tears down
        local state - but still attempts the previous-Wi-Fi restore, since that's a purely
        local action independent of the camera being reachable."""
        log("_handle_connection_lost: %s" % reason)
        if self._is_recording:
            self._is_recording = False
            self._recording_started_at = None
            self.recording_clip_number = 1
            self.recordingStateChanged.emit(False)
        self._running = False
        if self._wifi_device and self._previous_ssid:
            try:
                subprocess.check_call(
                    ["networksetup", "-setairportnetwork", self._wifi_device, self._previous_ssid],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                )
            except Exception:
                pass
        self.connectionLost.emit(reason)

    def _do_disconnect(self):
        log("_do_disconnect: starting")
        if self._is_recording:
            self._send({"command": "VideoRecordingStop"})
            self._is_recording = False
            self._recording_started_at = None
            self.recording_clip_number = 1
            self.recordingStateChanged.emit(False)
        self._send({"command": "RCStopRemoteCtl"})
        self._running = False
        if self._wifi_device and self._previous_ssid:
            try:
                subprocess.check_call(
                    ["networksetup", "-setairportnetwork", self._wifi_device, self._previous_ssid],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                )
            except Exception:
                pass
        log("_do_disconnect: done")
        self.disconnected.emit()

    def _do_download(self, command_dict: dict, save_path: str):
        """GetFile's response body is not necessarily text (JPEG/DNG/MP4 bytes) - _send()
        would mangle it via .decode("utf-8", errors="replace"). Request it separately here,
        streaming it in chunks (rather than one blocking read) so fileDownloadProgress can
        report progress for large files - real camera files can be tens of MB (a real DNG
        downloaded this way was ~32MB, see ARCHITECTURE.md bug #11) and this used to just block
        silently until done. Response-shape assumptions (raw binary in the body vs. some JSON
        wrapper) are confirmed correct against the real camera (bug #11 - downloaded DNG
        verified intact via exiftool/sips).
        """
        json_str = json.dumps(command_dict, separators=(",", ":"))
        url = "http://%s/?data=%s" % (INET_ADDRESS_CAMERA, json_str)
        try:
            response = self._http.request("GET", url, timeout=30.0, preload_content=False)
        except Exception as e:
            log("_do_download: request failed: %r" % (e,))
            self.fileDownloaded.emit(save_path, False, repr(e))
            return

        if response.status != 200:
            preview = response.read(200)
            # Only 200 bytes of the error body were read - drain the rest (see
            # _drain_and_release) instead of handing a half-read socket back.
            self._drain_and_release(response)
            preview_text = preview.decode("utf-8", errors="replace")
            log("_do_download: status=%s body_preview=%r" % (response.status, preview_text))
            self.fileDownloaded.emit(save_path, False, "HTTP %s: %s" % (response.status, preview_text))
            return

        try:
            total = int(response.headers.get("Content-Length", -1))
        except (TypeError, ValueError):
            total = -1

        bytes_written = 0
        try:
            with open(save_path, "wb") as f:
                for chunk in response.stream(65536):
                    f.write(chunk)
                    bytes_written += len(chunk)
                    self.fileDownloadProgress.emit(bytes_written, total)
        except Exception as e:
            # Review finding 2026-07-24: this used to release_conn() a HALF-READ response, the
            # same mistake that made video previews kill the session (bug #18). If the write
            # fails partway - disk full, permissions - the camera is still sending; handing that
            # socket back to the pool wedges the next request. Drain first, then release.
            self._drain_and_release(response)
            # A partially written file is worse than none: it looks valid in Finder and will
            # fail to open. Remove it so the failure is visible where it happened.
            try:
                os.remove(save_path)
            except OSError:
                pass
            self.fileDownloaded.emit(save_path, False, repr(e))
            return
        self._drain_and_release(response)

        log("_do_download: wrote %d bytes to %s" % (bytes_written, save_path))
        self.fileDownloaded.emit(save_path, True, "%d bytes" % bytes_written)

    def _do_shoot_and_review(self):
        """Take a photo, then locate and download a quick preview of it so the UI can flash it
        briefly (a "chimp review", like a real camera's post-shot playback). GetFileList's
        response shape (path/date/filetype/protectStatus per entry) is confirmed from bug #11
        testing, so "the file with the highest date" reliably identifies the just-taken shot
        without needing a before/after diff. GetFile with a thumbnail-quality parameter
        (CmdEnumFileQuality.Medium="MidThumb") is UNVERIFIED against the real camera - only
        "Original" quality has ever been tested (see bug #11 in ARCHITECTURE.md) - if MidThumb
        turns out not to be honored, the download will just be slower (full-size file) rather
        than silently wrong, since the same generic download path is used either way."""
        shoot_time = time.time()
        status, body = self._send({"command": "RCDoShooting"})
        self.commandResult.emit("RCDoShooting", status or 0, body)
        log("_do_shoot_and_review: RCDoShooting -> status=%s body=%s" % (status, body))
        if not is_camera_success(status, body):
            self.photoReviewFailed.emit("RCDoShooting failed (status=%s body=%s)" % (status, body))
            return

        new_path = None
        deadline = time.time() + 8.0
        while time.time() < deadline:
            list_cmd = CmdFileList(permit_raw=True, permit_jpg=True, id_start=0, id_end=9999)
            status, body = self._send(list_cmd.to_json())
            if status == 200:
                try:
                    data = json.loads(body).get("data")
                except Exception:
                    data = None
                if isinstance(data, list) and data:
                    newest = max(
                        (e for e in data if isinstance(e, dict) and "date" in e),
                        key=lambda e: int(e["date"]), default=None,
                    )
                    if newest is not None and int(newest["date"]) >= int(shoot_time) - 5:
                        new_path = newest.get("path")
                        break
            time.sleep(0.5)

        if new_path is None:
            log("_do_shoot_and_review: could not find the new photo after %.1fs" % (time.time() - shoot_time))
            self.photoReviewFailed.emit("Could not find the new photo on the camera after shooting.")
            return

        log("_do_shoot_and_review: new file is %r, downloading preview" % new_path)
        self._download_preview_with_progress(new_path)

    def _download_preview_with_progress(self, path: str):
        get_cmd = CmdFileGet(path, CmdEnumFileQuality.Medium)
        json_str = json.dumps(get_cmd.to_json(), separators=(",", ":"))
        url = "http://%s/?data=%s" % (INET_ADDRESS_CAMERA, json_str)
        try:
            response = self._http.request("GET", url, timeout=15.0, preload_content=False)
        except Exception as e:
            log("_download_preview_with_progress: request failed: %r" % (e,))
            self.photoReviewFailed.emit(repr(e))
            return

        if response.status != 200:
            self._drain_and_release(response)
            self.photoReviewFailed.emit("GetFile failed (status=%s)" % response.status)
            return

        try:
            total = int(response.headers.get("Content-Length", -1))
        except (TypeError, ValueError):
            total = -1

        data = bytearray()
        try:
            for chunk in response.stream(65536):
                data.extend(chunk)
                self.photoReviewProgress.emit(len(data), total)
        except Exception as e:
            self.photoReviewFailed.emit("Download interrupted: %r" % (e,))
            return
        finally:
            # Reached on the interrupted-read path too, where the camera is still writing -
            # drain before releasing or the next request inherits a wedged socket.
            self._drain_and_release(response)

        if total > 0 and len(data) != total:
            log("_download_preview_with_progress: WARNING got %d bytes but Content-Length said "
                "%d - download may be truncated" % (len(data), total))
        elif total > 0:
            log("_download_preview_with_progress: got exactly the %d bytes Content-Length promised" % len(data))
        else:
            log("_download_preview_with_progress: got %d bytes (no Content-Length to compare against)" % len(data))

        img = QImage.fromData(bytes(data))
        if img.isNull():
            log("_download_preview_with_progress: %d bytes did not decode as an image" % len(data))
            self.photoReviewFailed.emit("Downloaded %d bytes but could not decode as an image." % len(data))
            return

        log("_download_preview_with_progress: decoded %dx%d preview from %d bytes" % (
            img.width(), img.height(), len(data)))
        self.photoReviewReady.emit(img)

    # A thumbnail/preview response should be small - photo MidThumb measured ~228 KB against
    # ~32 MB originals. Anything past this is the camera ignoring the quality parameter and
    # streaming the whole file, which is exactly what happens for VIDEO (see _do_fetch_image).
    MAX_PREVIEW_BYTES = 4 * 1024 * 1024

    @staticmethod
    def _drain_and_release(response):
        """Finish a streamed response cleanly before letting go of the socket.

        The camera serves one client at a time. Releasing a half-read response hands a socket
        back to the pool while the camera is still writing into it, which wedges every request
        that follows - that is exactly how a video preview used to take the whole session down
        (bug #18). Draining costs a moment; not draining costs the connection."""
        if response is None:
            return
        try:
            response.drain_conn()
        except Exception:
            pass
        try:
            response.release_conn()
        except Exception:
            pass

    def _do_fetch_image(self, path: str, quality, signal):
        """Shared in-memory image fetch for thumbnails/previews (2026-07-19). Failures are
        silent by design - a missing thumbnail just leaves the generic row icon, matching the
        iOS ThumbnailStore's failed-path behavior.

        BUG FIX 2026-07-24 - previewing a VIDEO dropped the whole connection. The camera does
        not honour the thumbnail/MidThumb quality parameter for video files: it starts streaming
        the ENTIRE clip (hundreds of MB). This used to be a plain `request(...)` with
        preload_content left on, so urllib3 tried to buffer all of it, blew the 15 s timeout
        mid-transfer and tore the socket down with the camera still writing. The camera serves
        one client at a time, so it was left mid-response, the following GetCameraStatus polls
        failed, and after three of them the camera-vanished detector disconnected the app. That
        is why photos were fine and videos killed the session.

        Now the body is streamed with a hard cap: past MAX_PREVIEW_BYTES we stop, drain the
        rest of the response so the camera can finish writing cleanly, and give up on the
        preview. Draining rather than slamming the socket shut is the part that keeps the
        session alive."""
        get_cmd = CmdFileGet(path, quality)
        json_str = json.dumps(get_cmd.to_json(), separators=(",", ":"))
        url = "http://%s/?data=%s" % (INET_ADDRESS_CAMERA, json_str)
        response = None
        try:
            response = self._http.request("GET", url, timeout=15.0, preload_content=False)
            if response.status != 200:
                log("_do_fetch_image: %s (%s) -> status=%s" % (path, quality, response.status))
                return
            chunks = []
            total = 0
            oversized = False
            for chunk in response.stream(64 * 1024):
                chunks.append(chunk)
                total += len(chunk)
                if total > self.MAX_PREVIEW_BYTES:
                    oversized = True
                    break
            if oversized:
                log("_do_fetch_image: %s (%s) exceeded %d bytes - the camera is streaming the "
                    "whole file instead of a thumbnail (expected for video). Aborting preview."
                    % (path, quality, self.MAX_PREVIEW_BYTES))
                return
            img = QImage.fromData(b"".join(chunks))
            if not img.isNull():
                signal.emit(path, img)
        except Exception as e:
            log("_do_fetch_image: %s (%s) failed: %r" % (path, quality, e))
        finally:
            self._drain_and_release(response)

    def _do_toggle_recording(self):
        if time.time() - self._last_record_command_at < self.RECORD_COMMAND_COOLDOWN:
            log("_do_toggle_recording: ignored - within the %.1fs post-command cooldown" %
                self.RECORD_COMMAND_COOLDOWN)
            return
        cmd = "VideoRecordingStop" if self._is_recording else "VideoRecordingStart"
        status, body = self._send({"command": cmd})
        self._last_record_command_at = time.time()
        log("_do_toggle_recording: %s -> status=%s body=%s" % (cmd, status, body))
        # is_camera_success, not just status == 200: the camera signals failure as HTTP 200 +
        # {"code":<err>} - flipping on transport status alone is exactly what desynced the iOS
        # app's UI from a still-recording camera (see is_camera_success's doc comment).
        if is_camera_success(status, body):
            self._is_recording = not self._is_recording
            if self._is_recording:
                # Fresh recording (not a restart) - M6, 2026-07-12: reset the clip counter and
                # start the auto-restart monitor's elapsed-time clock.
                self._recording_started_at = time.monotonic()
                self.recording_clip_number = 1
                self._reset_self_stop_detector()
                self.recordingClipNumberChanged.emit(1)
            else:
                self._recording_started_at = None
            self.recordingStateChanged.emit(self._is_recording)
        else:
            self.errorOccurred.emit("%s failed (status=%s body=%s)" % (cmd, status, body))

    def _do_force_stop_recording(self):
        if time.time() - self._last_record_command_at < self.RECORD_COMMAND_COOLDOWN:
            log("_do_force_stop_recording: ignored - within the %.1fs post-command cooldown" %
                self.RECORD_COMMAND_COOLDOWN)
            return
        status, body = self._send({"command": "VideoRecordingStop"})
        self._last_record_command_at = time.time()
        log("_do_force_stop_recording: VideoRecordingStop -> status=%s body=%s" % (status, body))
        self._is_recording = False
        self._recording_started_at = None
        self.recordingStateChanged.emit(False)

    def _reset_self_stop_detector(self):
        """Must run on EVERY recording (re)start, not just on stop (2026-07-19 audit find): a 5s
        stats window spanning an auto-restart's inter-clip gap reads the camera's full-rate
        stream as a "fast" sample, and with the armed flag surviving the restart, two such
        windows in a row would false-fire the detector right after a successful restart -
        flipping the flag to not-recording and sending a doomed extra Start."""
        self._recording_throttle_armed = False
        self._slow_samples_while_recording = 0
        self._fast_samples_while_recording = 0

    def _check_camera_self_stop(self, in_fps: float):
        """Camera-self-stop detection via the live-view fps signature (2026-07-12, ported from
        the iOS app - see the __init__ state comment for the arming mechanism). Runs on the 5s
        log cadence in _run_live_view_loop."""
        if self._is_recording and in_fps > 0:
            if in_fps < 12:
                self._fast_samples_while_recording = 0
                self._slow_samples_while_recording += 1
                if self._slow_samples_while_recording >= 2:
                    self._recording_throttle_armed = True
            elif in_fps > 20:
                self._slow_samples_while_recording = 0
                if self._recording_throttle_armed:
                    self._fast_samples_while_recording += 1
                    if self._fast_samples_while_recording >= 2:
                        self._handle_camera_self_stopped_recording()
            else:
                self._fast_samples_while_recording = 0
        else:
            self._reset_self_stop_detector()

    def _handle_camera_self_stopped_recording(self):
        """The camera ended the recording on its own (its ~7.5-min 4K / ~30-min limit) - resync
        the UI to the truth, and when auto-restart is on, start the next clip immediately (no
        VideoRecordingStop needed, the camera already stopped itself)."""
        log("_handle_camera_self_stopped_recording: fps signature says the camera stopped on its own")
        self._reset_self_stop_detector()
        self._is_recording = False
        self._recording_started_at = None
        self.recordingStateChanged.emit(False)
        if not self.auto_restart_recording:
            return
        if time.time() - self._last_record_command_at < self.RECORD_COMMAND_COOLDOWN:
            return  # a record command just happened - don't stack another on top of it
        status, body = self._send({"command": "VideoRecordingStart"})
        self._last_record_command_at = time.time()
        log("_handle_camera_self_stopped_recording: VideoRecordingStart -> status=%s body=%s" % (status, body))
        if is_camera_success(status, body):
            self.recording_clip_number += 1
            self._recording_started_at = time.monotonic()
            self._is_recording = True
            self.recordingStateChanged.emit(True)
            self.recordingClipNumberChanged.emit(self.recording_clip_number)

    def _recording_restart_interval(self) -> float:
        """Picks the auto-restart interval for the last-seen VideoFormat metadata string, using
        the same prefix-match convention as the iOS port (e.g. "4K_24" matches "4K").

        UNMEASURED CASE - FHD_60 (2026-07-24). These intervals were calibrated when the format
        could only be set on the camera body and the user in practice shot FHD_30 / 4K_30. Now
        that RCVideoFormatSet works ("Resolution" key), FHD_60 is one tap away, and its higher
        bitrate may well hit the 4 GB file ceiling BEFORE this 29:55 timer fires - measured
        FHD_30 is ~15.5 Mbit/s, and if 60p roughly doubles that, 4 GB arrives at roughly 17 min.
        Nobody has timed a real FHD_60 clip yet, so no number is invented here. Consequence of
        being wrong is bounded: the fps self-stop detector (the reactive layer) still catches the
        camera stopping on its own and starts the next clip, it just reacts ~10-15 s later than a
        correct proactive timer would. If someone times an FHD_60 clip to its natural end, add
        the case here. Same caveat, in the opposite direction, for 4K_30_LOW: a lower bitrate
        means 7:23 fires earlier than it needs to - safe, just wasteful."""
        fmt = (self._last_video_format or "").upper()
        if fmt.startswith("4K"):
            return self.RECORDING_AUTO_RESTART_4K_INTERVAL
        if fmt.startswith("2K"):
            return self.RECORDING_AUTO_RESTART_2K_INTERVAL
        return self.RECORDING_AUTO_RESTART_FHD_INTERVAL

    def _maybe_auto_restart_recording(self):
        """Checked once a second from _run_live_view_loop (M6, 2026-07-12, ported from the iOS
        app's per-second monitor tick) - restarts recording near-instantly just under the
        camera's own recording-length limit, for near-continuous capture. Near-continuous, not
        truly nonstop: true nonstop recording is impossible on this camera (see
        DEVELOPMENT_PLAN.md's researched-not-tested backlog notes) - app-side restart with a
        small gap is the achievable ceiling."""
        if not (self.auto_restart_recording and self._is_recording and self._recording_started_at is not None):
            return
        if time.time() - self._last_record_command_at < self.RECORD_COMMAND_COOLDOWN:
            return  # a record command (manual or a just-finished restart) is still cooling down
        elapsed = time.monotonic() - self._recording_started_at
        if elapsed >= self._recording_restart_interval():
            self._perform_auto_restart()

    def _perform_auto_restart(self):
        """Stop -> cooldown -> start through the same command semantics as a manual toggle
        (M6, 2026-07-12, ported from the iOS app's performAutoRestart) - never bypasses the
        firmware-needs-a-beat cooldown between commands, since rapid cycling is what wedged the
        real camera during the 2026-07-09 desync bug. The cooldown sleep blocks this thread (the
        same one that also does UDP recvfrom) for RECORD_COMMAND_COOLDOWN seconds - acceptable
        here because an auto-restart is rare (once per 8-30 minutes) and the live view legitimately
        glitches during the camera's own stop/start transition regardless of our code."""
        log("_perform_auto_restart: restarting recording (clip %d -> %d)" % (
            self.recording_clip_number, self.recording_clip_number + 1))
        stop_status, stop_body = self._send({"command": "VideoRecordingStop"})
        self._last_record_command_at = time.time()
        if not is_camera_success(stop_status, stop_body):
            log("_perform_auto_restart: VideoRecordingStop failed (status=%s body=%s) - "
                "will retry next tick" % (stop_status, stop_body))
            return
        self._is_recording = False
        self._recording_started_at = None
        self.recordingStateChanged.emit(False)

        time.sleep(self.RECORD_COMMAND_COOLDOWN)

        start_status, start_body = self._send({"command": "VideoRecordingStart"})
        self._last_record_command_at = time.time()
        if is_camera_success(start_status, start_body):
            self.recording_clip_number += 1
            self._recording_started_at = time.monotonic()
            self._is_recording = True
            self._reset_self_stop_detector()  # the inter-clip gap poisons the fps samples
            self.recordingStateChanged.emit(True)
            self.recordingClipNumberChanged.emit(self.recording_clip_number)
        else:
            log("_perform_auto_restart: VideoRecordingStart failed (status=%s body=%s)" % (
                start_status, start_body))
            # isRecording/_recording_started_at stay cleared above - matches reality (the camera
            # isn't recording) instead of the UI claiming otherwise.

    def _drain_requests_nonblocking(self):
        while True:
            try:
                item = self._requests.get_nowait()
            except queue.Empty:
                return
            kind = item[0]
            if kind == "connect":
                # Guard against duplicate "connect" requests (e.g. a double-click, or one
                # queued while an earlier one is still being processed). Without this, a
                # second connect mid-session would re-run the whole BLE pairing + Wi-Fi
                # switch flow *while already connected*, switching to a brand-new random
                # camera Wi-Fi password and yanking the just-established connection out
                # from under itself - this was the cause of the "Wi-Fi switch doesn't
                # work" symptom reported after the first test run.
                if self._running:
                    log("_drain_requests_nonblocking: ignoring duplicate 'connect' - already running")
                    continue
                self._do_connect()
            elif kind == "connect_direct":
                if self._running:
                    log("_drain_requests_nonblocking: ignoring duplicate 'connect_direct' - already running")
                    continue
                self._do_connect_direct()
            elif kind == "disconnect":
                self._do_disconnect()
            elif kind == "toggle_recording":
                self._do_toggle_recording()
            elif kind == "force_stop":
                self._do_force_stop_recording()
            elif kind == "shoot_review":
                self._do_shoot_and_review()
            elif kind == "send":
                command_dict = item[1]
                status, body = self._send(command_dict)
                self.commandResult.emit(command_dict.get("command", "?"), status or 0, body)
            elif kind == "download":
                self._do_download(item[1], item[2])
            elif kind == "preview":
                self._do_fetch_image(item[1], CmdEnumFileQuality.Medium, self.previewReady)
            elif kind == "quit":
                self._running = False
                return

    def run(self):
        log("run(): thread started, waiting for a request")
        # NOTE: do NOT drain/discard queue contents here before the blocking get() below.
        # An earlier version of this code did exactly that ("clean up stale requests from a
        # previous failed run") and it introduced a *worse* race: the UI calls
        # session.start() immediately followed by session.request_connect() from the GUI
        # thread. Those two calls can easily both complete (native thread scheduling delay)
        # before this run() method gets its first timeslice - meaning the real, brand-new
        # "connect" request is often *already sitting in the queue* the moment run() starts.
        # A drain step here would silently swallow that legitimate first request, leaving
        # this thread blocked on get() forever waiting for a second request that never
        # comes (observed as: "thread started" logged, then nothing - the whole app hangs
        # and aborts on quit with "QThread: Destroyed while thread is still running").
        # Stale-item cleanup (for the case this run() is a *retry* after a previous run()
        # exited early - see the `if not self._running` block below) is done at the point
        # where we know a request is actually stale, not blindly at thread startup.
        item = self._requests.get()
        if item[0] == "quit":
            return
        if item[0] == "connect":
            self._do_connect()
        elif item[0] == "connect_direct":
            self._do_connect_direct()

        if not self._running:
            # Connect failed (or was a no-op). Discard any other request that might have
            # been queued during this same failed attempt (e.g. a duplicate "connect" from
            # a double-click) so it isn't wrongly picked up by the *next* run()'s first
            # blocking get() above.
            while True:
                try:
                    self._requests.get_nowait()
                except queue.Empty:
                    break
            return

        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.bind(("", UDP_PORT_LIVEVIEW))
        sock.settimeout(0.5)

        # Bigger kernel receive buffer (M4, 2026-07-12, ported from the iOS app - default is a
        # few tens of KB) so a brief stall on our end doesn't make the OS itself start silently
        # dropping datagrams before this thread even reads them. Best-effort: if the OS clamps
        # it lower, that's just less headroom, not a correctness requirement. Deliberately NOT
        # porting iOS's Wi-Fi keep-alive uplink / SO_NET_SERVICE_TYPE - those exist specifically
        # to fight iOS's aggressive Wi-Fi power-save duty-cycling, which the iOS stability
        # investigation (DEVELOPMENT_PLAN.md, 2026-07-11) confirmed doesn't apply here: the Mac
        # has never shown the equivalent stutter, and unnecessary uplink traffic would just be
        # noise. Read back what the kernel actually granted, same as iOS, so a too-small buffer
        # is visible in the log below instead of silently assumed away.
        try:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1_048_576)
        except OSError:
            pass
        try:
            actual_rcvbuf = sock.getsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF)
        except OSError:
            actual_rcvbuf = 0

        try:
            self._run_live_view_loop(sock, actual_rcvbuf)
        finally:
            sock.close()

    def _run_live_view_loop(self, sock: socket.socket, actual_rcvbuf: int = 0):
        """The main receive loop: periodic GetCameraStatus poll + camera-vanished detection (M2)
        + reorder-tolerant two-frame-window UDP reassembly (M4) + a periodic forensic log +
        the recording auto-restart monitor tick (M6). Factored out of run() (M4, 2026-07-12) so
        it's testable independent of the BLE/Wi-Fi connect handshake - construct a
        CameraSession, bind any already-connected UDP socket (doesn't have to be
        UDP_PORT_LIVEVIEW), set self._running = True, and call this directly with synthetic
        packets sent to that socket."""
        last_status_poll = 0.0
        consecutive_status_failures = 0
        last_liveview_log = 0.0
        last_auto_restart_check = 0.0

        # Reorder-tolerant TWO-frame-window reassembly (M4, 2026-07-12, ported from the iOS
        # app's v3 LiveViewReceiver - see yi-m1-ios/YiM1Core/Sources/YiM1Core/
        # LiveViewReceiver.swift's doc comment for the full v1->v3 evolution this is based on).
        # UDP guarantees delivery, not order - the original code here treated mere reordering as
        # loss (any out-of-sequence packet killed the whole frame). Keeping up to two frames in
        # assembly simultaneously lets a straggler packet for the previous frame complete it even
        # after the next frame has started arriving (Wi-Fi MAC-layer retransmission routinely
        # causes this) - a frame is dropped only when a third frame index shows up while it's
        # still incomplete (evicted - by then its packets are genuinely not coming), or a newer
        # frame completes first (the older one would be stale on screen anyway).
        #
        # Each pending entry: {"frame_idx", "expected", "pieces" (list, None until received),
        # "received_count", "byte_count"}. `pending` is a list in arrival order, at most 2 long.
        pending = []
        MAX_REASONABLE_PACKET_COUNT = 1024  # sanity bound - real frames are ~30-40 packets
        last_started_for_fps = 0

        valid_frame_count = 0
        dropped_frame_count = 0
        frames_started_count = 0
        dropped_frames_missing_packets = 0
        dropped_frames_expected_packets = 0
        max_recv_gap_ms = 0.0
        recv_gaps_over_50ms_count = 0
        last_recv_time = None

        def evict(frame):
            nonlocal dropped_frame_count, dropped_frames_missing_packets, dropped_frames_expected_packets
            dropped_frame_count += 1
            dropped_frames_missing_packets += frame["expected"] - frame["received_count"]
            dropped_frames_expected_packets += frame["expected"]

        while self._running:
            self._drain_requests_nonblocking()
            if not self._running:
                break

            now = time.time()
            if now - last_status_poll > 5.0:
                status, body = self._send({"command": "GetCameraStatus"})
                # Review finding 2026-07-24: this used to test `status == 200`, so a camera that
                # answered HTTP 200 with an error body (`{"code":<err>}`) counted as healthy and
                # the consecutive-failure counter reset. The camera-vanished detector could then
                # never fire for a camera that is reachable but wedged - precisely the state a
                # half-read response leaves it in (bug #18). is_camera_success checks the body.
                if is_camera_success(status, body):
                    consecutive_status_failures = 0
                    try:
                        self.statusUpdated.emit(json.loads(body).get("data", {}))
                    except Exception:
                        pass
                else:
                    consecutive_status_failures += 1
                    if consecutive_status_failures >= self.CONSECUTIVE_STATUS_FAILURES_LIMIT:
                        self._handle_connection_lost(
                            "Lost connection to the camera (camera off or out of range)")
                        break
                last_status_poll = now

            # Periodic forensic log (M4) - matching iOS's "[liveview] ..." line, invaluable
            # if the Mac ever shows live-view stutter (it hasn't so far, but now there'd be
            # numbers to look at instead of just eyeballing it). NOTE when reading it: ~7.5fps
            # incoming + high gap counts DURING RECORDING is normal camera behavior (it
            # throttles live view to feed the encoder), not radio trouble.
            if now - last_liveview_log > 5.0:
                missing_percent = (
                    100 * dropped_frames_missing_packets // dropped_frames_expected_packets
                    if dropped_frames_expected_packets > 0 else 0
                )
                elapsed_since_log = now - last_liveview_log if last_liveview_log > 0 else 0.0
                in_fps = ((frames_started_count - last_started_for_fps) / elapsed_since_log
                          if elapsed_since_log > 0 else 0.0)
                last_started_for_fps = frames_started_count
                log("[liveview] in=%.1f fps | valid=%d dropped=%d started=%d | dropped frames "
                    "missing %d%% of their packets | maxgap=%dms gaps>50ms=%d | rcvbuf=%dKB" % (
                        in_fps, valid_frame_count, dropped_frame_count, frames_started_count,
                        missing_percent, max_recv_gap_ms, recv_gaps_over_50ms_count,
                        actual_rcvbuf // 1024))
                max_recv_gap_ms = 0.0  # peak-since-last-log, like iOS's resetPeakGap
                last_liveview_log = now
                self._check_camera_self_stop(in_fps)

            # Recording auto-restart monitor tick (M6, 2026-07-12) - checked once a second,
            # matching the iOS app's per-second cadence, so toggling auto_restart_recording
            # mid-recording takes effect within a second rather than only on the next clip.
            if now - last_auto_restart_check > 1.0:
                self._maybe_auto_restart_recording()
                last_auto_restart_check = now

            # Low-priority thumbnails (2026-07-19 audit find): at most ONE per loop pass, and
            # only when the main request queue is empty - so a batch of dozens queued by the
            # file browser can neither starve user commands nor block this thread (which also
            # does the UDP recvfrom below) long enough to freeze live view.
            if self._requests.empty():
                try:
                    thumb_path = self._thumb_requests.get_nowait()
                except queue.Empty:
                    pass
                else:
                    self._do_fetch_image(thumb_path, CmdEnumFileQuality.Fast, self.thumbReady)

            try:
                pack, _addr = sock.recvfrom(1024000)
            except socket.timeout:
                continue
            except OSError:
                break

            if len(pack) < 12:
                continue

            # Direct radio-away detector: gap since the previous successful datagram - ~1ms
            # is normal mid-stream, tens/hundreds of ms means something (radio, OS scheduling)
            # wasn't listening. Only gaps above 5ms are tracked; normal cadence never nears it.
            recv_time = time.monotonic()
            if last_recv_time is not None:
                gap_ms = (recv_time - last_recv_time) * 1000.0
                if gap_ms > 5.0:
                    if gap_ms > max_recv_gap_ms:
                        max_recv_gap_ms = gap_ms
                    if gap_ms > 50.0:
                        recv_gaps_over_50ms_count += 1
            last_recv_time = recv_time

            idx_frame = int.from_bytes(pack[:4], "big")
            len_packet_frame = int.from_bytes(pack[4:8], "big")
            idx_packet_frame = int.from_bytes(pack[8:12], "big")
            payload = pack[12:]

            frame = next((f for f in pending if f["frame_idx"] == idx_frame), None)
            if frame is not None:
                if (0 <= idx_packet_frame < len(frame["pieces"])
                        and frame["pieces"][idx_packet_frame] is None):
                    frame["pieces"][idx_packet_frame] = payload
                    frame["received_count"] += 1
                    frame["byte_count"] += len(payload)
            else:
                expected = len_packet_frame
                if expected <= 0 or expected > MAX_REASONABLE_PACKET_COUNT:
                    continue
                new_frame = {
                    "frame_idx": idx_frame, "expected": expected,
                    "pieces": [None] * expected, "received_count": 0, "byte_count": 0,
                }
                if 0 <= idx_packet_frame < expected:
                    new_frame["pieces"][idx_packet_frame] = payload
                    new_frame["received_count"] = 1
                    new_frame["byte_count"] = len(payload)
                pending.append(new_frame)
                frames_started_count += 1
                if len(pending) > 2:
                    # The oldest in-flight frame has now survived two newer frames starting -
                    # its missing packets are genuinely gone, not just late.
                    evict(pending.pop(0))

            completed_idx = next(
                (i for i, f in enumerate(pending) if f["received_count"] == f["expected"]), None)
            if completed_idx is None:
                continue
            completed = pending.pop(completed_idx)
            # Anything older than the completed frame is stale now (it may only complete
            # after a newer frame has already been shown) - drop it here.
            if completed_idx > 0 and pending:
                evict(pending.pop(0))

            frame_data = b"".join(completed["pieces"])
            if len(frame_data) <= 2048:
                continue
            valid_frame_count += 1
            header_bytes = frame_data[:2048]
            jpeg_bytes = frame_data[2048:]

            metadata = self._parse_live_metadata(header_bytes)
            if metadata is not None:
                # M6, 2026-07-12: tracked so _recording_restart_interval can pick the right
                # per-format auto-restart timer without needing a round-trip through MainWindow.
                video_format = metadata.get("VideoFormat")
                if isinstance(video_format, str) and video_format:
                    self._last_video_format = video_format
                self.liveMetadataUpdated.emit(metadata)

            img = QImage.fromData(jpeg_bytes, "JPG")
            if not img.isNull():
                self.frameReady.emit(img)
