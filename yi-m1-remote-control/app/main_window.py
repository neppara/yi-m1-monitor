"""
Main window for the YI M1 Monitor app.

Camera-app-style layout (redesign approved 2026-07-07, see app/ARCHITECTURE.md
roadmap): live view centered, Photo/Video segmented toggle on top, a
shutter/record circle bottom-center with Files to its left and three guide
toggles (Crop / Thirds / Diagonals) to its right, a mode-aware settings strip at
the bottom, and connection collapsed into a titlebar status chip + menu.

The camera backend (camera_session.CameraSession) is unchanged - this file only
owns presentation and wiring. Visual tokens come from theme.py (the shared design
system, mirrored later in the iOS port).
"""
import json
import os
import time
from datetime import datetime
from typing import Optional

from PySide6.QtCore import Qt, QRectF, QSize, Signal, QTimer, QSettings
from PySide6.QtGui import (
    QImage, QPainter, QPainterPath, QPen, QColor, QFont, QIcon, QPixmap, QTransform,
)

# Focus peaking (2026-07-19, iOS parity) needs only numpy since 2026-07-20. It used to use
# cv2.Canny, but inside the frozen .app cv2 fails to import outright ("recursion is detected
# during loading of cv2 binary extensions" - a known OpenCV/PyInstaller incompatibility in its
# self-reimporting loader), which silently left the Peaking button disabled. Edge detection for
# peaking is a ~10-line Sobel in numpy, so dropping cv2 fixes the app AND removes ~100MB and a
# fragile dependency from the bundle. Catch Exception (not just ImportError) and keep the reason
# so the button's tooltip and the log can explain themselves.
_PEAKING_IMPORT_ERROR = ""
try:
    import numpy as np
    _PEAKING_AVAILABLE = True
except Exception as _peaking_exc:  # noqa: BLE001 - deliberately broad, see above
    _PEAKING_AVAILABLE = False
    _PEAKING_IMPORT_ERROR = "%s: %s" % (type(_peaking_exc).__name__, _peaking_exc)
from PySide6.QtWidgets import (
    QMainWindow, QWidget, QVBoxLayout, QHBoxLayout, QGridLayout, QPushButton, QLabel, QComboBox,
    QDialog, QListWidget, QListWidgetItem, QFileDialog, QMessageBox, QProgressBar, QMenu,
    QInputDialog,
)

import theme
import icons
from camera_session import CameraSession, is_camera_success
from prot_http.command_http import (
    RcCmdSetCameraMode, RcCmdSetMeteringMode, RcCmdSetFocusingMode, RcCmdSetImageQuality,
    RcCmdSetImageAspect, RcCmdSetImageFormat, RcCmdSetDriveMode, RcCmdSetFStop,
    RcCmdSetShutterSpeed, RcCmdSetExposureValueOffset, RcCmdSetColorStyle,
    RcCmdSetWhiteBalanceMode, RcCmdSetIso, RcCmdTriggerFocus, RcCmdSetVideoFormat,
    CmdFileList, CmdFileGet, CmdFileDelete,
)
from prot_http.const_http_cmd_rc_params import (
    RcExposureMode, RcMeteringMode, RcFocusMode, RcImageQuality, RcImageAspect, RcFileFormat,
    RcDriveMode, RcFStop, RcShutterSpeed, RcEvOffset, RcColorStyle, RcWhiteBalance, RcIso,
    RcTriggerFocusMode, RcVideoFormat,
)
from prot_http.const_http_enum_extra import CmdEnumFileQuality


def log(msg):
    """Terminal-visible logging for this module, matching camera_session.py's [session]
    convention - added to diagnose the bug #12 ImageAspect-reset investigation (2026-07-07)."""
    print("[settings] %s" % msg, flush=True)


# How long _on_live_metadata suppresses syncing a field after the user manually changes it
# (see bug #10/#12 in ARCHITECTURE.md). Most settings are simple gain/mode values that the
# camera echoes back within a frame or two.
SETTING_CONFIRM_TIMEOUT = {}
DEFAULT_SETTING_CONFIRM_TIMEOUT = 5.0

# Live-tested 2026-07-07 (see bug #12 in ARCHITECTURE.md): the live-view metadata's
# "ImageAspect" field appears to always report "4:3" no matter what aspect is actually
# requested/active - it likely reflects the last-taken photo (or some other lagging snapshot)
# rather than the pending setting. We've independently confirmed via the tripod crop
# measurements (fable research/live-testing-findings.md) that RCImageAspect genuinely does
# change what gets captured, so for these keys we trust our own last-requested value
# indefinitely instead of ever "giving up" and reverting the UI to a metadata value that may
# just never update.
NEVER_EXPIRE_METADATA_KEYS = {"ImageAspect"}


# Real measured crop rectangles (x0, y0, w, h as fractions of the full 4:3 sensor frame), from
# a tripod session (2026-07-07): a 4:3 reference photo plus one recording per video resolution
# and one photo per aspect, each smaller frame located within the reference via OpenCV
# multi-scale template matching (methodology + confidence scores in
# fable research/live-testing-findings.md section 10). Video keyed by "VideoFormat" prefix,
# photo by exact "ImageAspect" value.
MEASURED_VIDEO_CROPS = {
    "2K": (0.0000, 0.0000, 1.0000, 1.0000),   # 2048x1536, 4:3 - full sensor, just downscaled
    "FHD": (0.0004, 0.1268, 0.9961, 0.7472),  # 1920x1080, 16:9 - same geometry as the 16:9 photo aspect crop
    "4K": (0.1294, 0.2230, 0.7409, 0.5558),   # 3840x2160, 16:9 - real ~74%x56% crop, near-native pixel readout
}
MEASURED_PHOTO_CROPS = {
    "4:3": (0.0000, 0.0000, 1.0000, 1.0000),
    "3:2": (0.0000, 0.0556, 1.0000, 0.8889),
    "16:9": (0.0000, 0.1247, 1.0000, 0.7510),
    "1:1": (0.1250, 0.0000, 0.7500, 1.0000),
}

# Which settings belong to which mode's strip. Shared = confirmed to affect both photo and
# video (the NaturalBW video test, ARCHITECTURE.md); Photo-only = about the still file. Video
# has its own read-only display chips (format/audio/EIS) built separately since HTTP can't set
# them. Keyed by metadata field name.
SHARED_SETTING_KEYS = ["ExposureMode", "ISOSetting", "ShutterSpeed", "Fnumber", "EV", "WB",
                       "MeteringMode", "FocusMode", "ColorMode"]
PHOTO_SETTING_KEYS = ["ImageQuality", "ImageAspect", "FileFormat", "DriveMode"]
# VideoFormat became SETTABLE on 2026-07-24 (RCVideoFormatSet, parameter key "Resolution" -
# see 'fable research/rcvideoformatset-solved.md'). It used to sit in the read-only list
# below because the command was believed unreachable. Audio/EIS stay read-only for now: their
# handlers exist too, but we have not recovered their parameter keys yet.
VIDEO_SETTING_KEYS = ["VideoFormat"]
VIDEO_READONLY_KEYS = ["VASwitch", "VideoEis"]

# How many columns the settings grid uses. ~7 gives two rows for the photo strip (9 shared + 4
# photo = 13) and video strip (9 + 3 = 12), so no horizontal scrolling.
SETTINGS_COLUMNS = 7

# Human-friendly dropdown labels. The enum *value* (what's sent to the camera) is left
# untouched - this only changes what's *displayed*, mapping the terse enum member names/values
# (e.g. "I200", "SF100", "N5p0", "MP50_Int", "CenterWeighted") to readable UI text. Per-key
# explicit maps for values that don't prettify by a simple rule; the rest fall through to the
# formatter in _display_label.
_PRETTY_LABELS = {
    "ExposureMode": {"Auto": "Auto", "P": "Program", "A": "Aperture", "S": "Shutter",
                     "M": "Manual", "C": "Master"},
    "MeteringMode": {"Multi": "Multi", "Spot": "Spot", "CenterWeighted": "Center"},
    "FocusMode": {"C-AF": "C-AF", "S-AF": "S-AF", "MF": "Manual"},
    "FileFormat": {"RAW": "RAW", "JPG-S": "JPEG S", "JPG-M": "JPEG M", "JPG-L": "JPEG L",
                   "RAWJ-S": "RAW+S", "RAWJ-M": "RAW+M", "RAWJ-L": "RAW+L"},
    "DriveMode": {"Single": "Single", "Continuous": "Continuous",
                  "2SDelay": "2s timer", "10SDelay": "10s timer"},
    "ColorMode": {"Standard": "Standard", "Portrait": "Portrait", "Vivid": "Vivid",
                  "NaturalBW": "B&W soft", "HContrastBW": "B&W hard"},
    # 4K_24 / FHD_24 are marked because they exist ONLY through this command - the
    # camera's own menus never offer 24p.
    "VideoFormat": {"4K_30": "4K 30p", "4K_24": "4K 24p \u2605", "4K_30_LOW": "4K 30p (low)",
                    "2K_30": "2K 30p", "FHD_60": "1080 60p", "FHD_30": "1080 30p",
                    "FHD_24": "1080 24p \u2605"},
}


def _display_label(metadata_key: str, value: str) -> str:
    """Map an enum value to a readable dropdown label (display only - the API value is
    unchanged). See _PRETTY_LABELS."""
    explicit = _PRETTY_LABELS.get(metadata_key)
    if explicit is not None and value in explicit:
        return explicit[value]
    if metadata_key == "Fnumber":
        return "f/" + value
    if metadata_key == "EV":
        return value if (value.startswith("-") or value.startswith("0")) else "+" + value
    if metadata_key == "WB":
        return value + "K" if value.isdigit() else value
    if metadata_key == "ImageQuality":
        return value + " MP" if value.isdigit() else value
    return value


def _qcolor(hex_str, alpha=255):
    c = QColor(hex_str)
    c.setAlpha(alpha)
    return c


class ShutterButton(QWidget):
    """The central capture control. Photo mode: a white shutter ring + disc. Video mode: a red
    ring + dot that becomes a red rounded square while recording. Drawn by hand so all three
    states render cleanly (a stylesheet can't do the ring/gap/inner-shape combination)."""

    clicked = Signal()
    # Escape hatch for a desynced camera (M1, 2026-07-12, ported from the iOS app's long-press
    # force-stop gesture): held for LONG_PRESS_MS while enabled, in video mode, over the button.
    longPressed = Signal()
    LONG_PRESS_MS = 1000

    def __init__(self):
        super().__init__()
        self.setFixedSize(76, 76)
        self.mode = "photo"      # "photo" | "video"
        self.recording = False
        self.setCursor(Qt.CursorShape.PointingHandCursor)
        self._long_press_timer = QTimer(self)
        self._long_press_timer.setSingleShot(True)
        self._long_press_timer.setInterval(self.LONG_PRESS_MS)
        self._long_press_timer.timeout.connect(self._on_long_press_timeout)
        self._long_press_fired = False

    def set_mode(self, mode: str):
        if mode != self.mode:
            self.mode = mode
            self.update()

    def set_recording(self, recording: bool):
        if recording != self.recording:
            self.recording = recording
            self.update()

    def mousePressEvent(self, event):
        # Video mode only: the long-press escape hatch doesn't exist in photo mode, and arming
        # the timer there anyway would silently swallow the click (= no photo taken) whenever
        # the button is held past LONG_PRESS_MS - the iOS gesture equivalent never suppresses
        # the photo tap, so neither should this.
        if self.isEnabled() and self.mode == "video":
            self._long_press_fired = False
            self._long_press_timer.start()

    def _on_long_press_timeout(self):
        self._long_press_fired = True
        self.longPressed.emit()

    def mouseReleaseEvent(self, event):
        self._long_press_timer.stop()
        if (self.isEnabled() and not self._long_press_fired
                and self.rect().contains(event.position().toPoint())):
            self.clicked.emit()
        self._long_press_fired = False

    def paintEvent(self, event):
        p = QPainter(self)
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        cx, cy = self.width() / 2, self.height() / 2
        enabled = self.isEnabled()

        if self.mode == "photo":
            ring = _qcolor(theme.Color.TEXT if enabled else theme.Color.TEXT_3)
        else:
            ring = _qcolor(theme.Color.RECORD if enabled else theme.Color.TEXT_3)

        pen = QPen(ring)
        pen.setWidth(3)
        p.setPen(pen)
        r = self.width() / 2 - 4
        p.drawEllipse(QRectF(cx - r, cy - r, 2 * r, 2 * r))

        p.setPen(Qt.PenStyle.NoPen)
        if self.mode == "photo":
            p.setBrush(_qcolor(theme.Color.TEXT if enabled else theme.Color.TEXT_3))
            ir = self.width() * 0.36
            p.drawEllipse(QRectF(cx - ir, cy - ir, 2 * ir, 2 * ir))
        else:
            p.setBrush(_qcolor(theme.Color.RECORD if enabled else theme.Color.TEXT_3))
            if self.recording:
                s = self.width() * 0.30
                p.drawRoundedRect(QRectF(cx - s / 2, cy - s / 2, s, s), 4, 4)
            else:
                ir = self.width() * 0.21
                p.drawEllipse(QRectF(cx - ir, cy - ir, 2 * ir, 2 * ir))


class LiveViewWidget(QWidget):
    """Displays the latest live-view JPEG frame, scaled to fit, with optional overlays.

    Crop guide is mode-aware (crop_mode "photo"|"video") and unified into one toggle - see the
    redesign notes. Thirds/diagonals draw inside the crop rect when the crop is on, else across
    the full frame."""

    focusRequested = Signal(int, int)  # click position in live-view image pixel space

    def __init__(self):
        super().__init__()
        self.setMinimumSize(640, 420)
        self.setStyleSheet("background-color: %s;" % theme.Color.LIVE_BG)
        self._image: Optional[QImage] = None
        self.show_thirds = False
        self.show_diagonals = False
        self.show_crop = False
        self.crop_mode = "photo"                 # which measured crop the guide draws
        self.current_video_format: Optional[str] = None
        self.current_image_aspect: Optional[str] = None
        self.is_recording = False
        # > 1 once auto-restart (M6, 2026-07-12) has kicked in at least once for the current
        # recording session - shown in the recording note below.
        self.recording_clip_number = 1
        # Recording elapsed timer (2026-07-19, iOS parity) - counts locally from set_recording
        # (the camera doesn't report duration); the QTimer just forces a repaint each second so
        # the note's mm:ss stays current.
        self._recording_started_at: Optional[float] = None
        self._recording_tick = QTimer(self)
        self._recording_tick.setInterval(1000)
        self._recording_tick.timeout.connect(self.update)
        # Manual live-view rotation for vertical shooting (2026-07-19, iOS parity) - 0/90/-90
        # degrees, cycled by MainWindow's rotate button. Display-only: _last_display_image stays
        # sensor-oriented so tap-to-focus can inverse-map, and guide crop fractions go through
        # _visual_fractions.
        self.view_rotation = 0
        # Focus peaking overlay (2026-07-19, iOS parity) - same pixel dims as the raw frame it
        # was computed from, so it goes through the exact same crop/rotate/scale path.
        self._peaking_overlay: Optional[QImage] = None
        # Photo "chimp review" state - at most one of _review_image/_download_progress is
        # meaningful at a time; both take over the whole frame in paintEvent.
        self._review_image: Optional[QImage] = None
        self._download_progress: Optional[tuple] = None  # (bytes_read, total_or_-1)
        self._review_timer = QTimer(self)
        self._review_timer.setSingleShot(True)
        self._review_timer.timeout.connect(self.clear_review)
        # Set in paintEvent, reused by mousePressEvent to map a click back into image pixel
        # space (the image is letterboxed/scaled to fit the widget).
        self._last_image_rect: Optional[QRectF] = None
        # The image as actually displayed last paint (recording letterbox bars may be cropped
        # off) - mousePressEvent maps tap coordinates against THIS, not the raw frame.
        self._last_display_image: Optional[QImage] = None

    def set_image(self, image: QImage):
        self._image = image
        self.update()

    def show_download_progress(self, bytes_read: int, total: int):
        self._download_progress = (bytes_read, total)
        self.update()

    def show_photo_review(self, image: QImage, duration_ms: int = 2000):
        """Flash the just-taken photo over the live view for a short "chimp review", then
        automatically go back to normal live view (2s per user feedback - 500ms was too short)."""
        self._download_progress = None
        self._review_image = image
        self.update()
        self._review_timer.start(duration_ms)

    def clear_review(self):
        self._review_image = None
        self._download_progress = None
        self.update()

    # Any of these three overlays needs a repaint on a crop-geometry change (M3, 2026-07-12):
    # thirds/diagonals now follow the computed crop rect even when the dashed outline itself
    # (show_crop) is off, so gating repaints on show_crop alone would leave them stale.
    @property
    def _any_guide_visible(self) -> bool:
        return self.show_crop or self.show_thirds or self.show_diagonals

    def set_crop_mode(self, mode: str):
        if mode != self.crop_mode:
            self.crop_mode = mode
            if self._any_guide_visible:
                self.update()

    def set_video_format(self, video_format: Optional[str]):
        if video_format != self.current_video_format:
            self.current_video_format = video_format
            if self._any_guide_visible and self.crop_mode == "video":
                self.update()

    def set_image_aspect(self, image_aspect: Optional[str]):
        if image_aspect != self.current_image_aspect:
            self.current_image_aspect = image_aspect
            if self._any_guide_visible and self.crop_mode == "photo":
                self.update()

    def set_recording(self, is_recording: bool):
        # Once VideoRecordingStart takes effect the live-view feed itself switches to the real
        # cropped/exposed recording frame (observed 2026-07-07), so the crop rectangle is
        # redundant - hide it and show a note instead.
        if is_recording != self.is_recording:
            self.is_recording = is_recording
            if is_recording:
                self._recording_started_at = time.monotonic()
                self._recording_tick.start()
            else:
                self._recording_started_at = None
                self._recording_tick.stop()
            self.update()

    def cycle_view_rotation(self) -> int:
        """0 -> 90 -> -90 -> 0; returns the new rotation (for the button label)."""
        self.view_rotation = {0: 90, 90: -90, -90: 0}[self.view_rotation]
        self.update()
        return self.view_rotation

    def set_peaking_overlay(self, overlay: Optional[QImage]):
        self._peaking_overlay = overlay
        self.update()

    def set_recording_clip_number(self, clip_number: int):
        """M6, 2026-07-12 - see camera_session.py's recording auto-restart."""
        if clip_number != self.recording_clip_number:
            self.recording_clip_number = clip_number
            if self.is_recording:
                self.update()

    def _recording_display_image(self, image: QImage) -> QImage:
        """During 16:9 video recording the camera bakes black letterbox bars INTO the stream (a
        4:3 frame with the 16:9 recording content centered inside). Crop them off at display
        time (user request 2026-07-12, same as the iOS app): reclaims the wasted space and fixes
        the guides - thirds/diagonals span the visible frame during recording, which with the
        bars included was 4:3, not the real 16:9 capture area. 2K is deliberately excluded (its
        measured crop is the full sensor frame; whether its stream is letterboxed is
        unverified)."""
        if not (self.is_recording and self.current_video_format
                and self.current_video_format.upper().startswith(("FHD", "4K"))):
            return image
        width = image.width()
        height = image.height()
        content_height = int(width * 9 / 16)
        if content_height >= height - 2:
            return image  # already 16:9 (or wider) - nothing to crop
        return image.copy(0, (height - content_height) // 2, width, content_height)

    def mousePressEvent(self, event):
        if self._image is None or self._last_image_rect is None:
            return
        rect = self._last_image_rect
        pos = event.position() if hasattr(event, "position") else event.localPos()
        if not rect.contains(pos):
            return
        # Map from widget pixels to image pixel space (Posx/Posy convention unverified - see
        # ARCHITECTURE.md; assumes image-pixel coordinates). Uses the DISPLAYED image (which may
        # have the recording letterbox bars cropped off) so coordinates match what was tapped,
        # inverse-rotating first when the manual view rotation is active (2026-07-19 parity -
        # _last_display_image is deliberately kept sensor-oriented).
        source = self._last_display_image if self._last_display_image is not None else self._image
        rel_x = (pos.x() - rect.left()) / rect.width()
        rel_y = (pos.y() - rect.top()) / rect.height()
        if self.view_rotation == 90:
            rel_x, rel_y = rel_y, 1 - rel_x
        elif self.view_rotation == -90:
            rel_x, rel_y = 1 - rel_y, rel_x
        img_x = int(rel_x * source.width())
        img_y = int(rel_y * source.height())
        self.focusRequested.emit(img_x, img_y)

    def paintEvent(self, event):
        painter = QPainter(self)
        painter.fillRect(self.rect(), _qcolor(theme.Color.LIVE_BG))

        if self._image is None:
            self._last_image_rect = None
            painter.setPen(_qcolor(theme.Color.TEXT_3))
            painter.setFont(QFont(theme.Font.FAMILY, 14))
            painter.drawText(self.rect(), Qt.AlignmentFlag.AlignCenter, "Not connected")
            return

        display_image = self._recording_display_image(self._image)
        # _last_display_image stays SENSOR-oriented (pre-rotation) - mouse mapping inverse-
        # transforms through view_rotation back into this image's pixel space.
        self._last_display_image = display_image
        painted = display_image
        if self.view_rotation != 0:
            painted = display_image.transformed(QTransform().rotate(self.view_rotation),
                                                Qt.TransformationMode.SmoothTransformation)
        scaled = painted.scaled(
            self.size(), Qt.AspectRatioMode.KeepAspectRatio, Qt.TransformationMode.SmoothTransformation
        )
        x = (self.width() - scaled.width()) // 2
        y = (self.height() - scaled.height()) // 2
        painter.drawImage(x, y, scaled)

        if self._peaking_overlay is not None:
            # Same crop/rotate/scale pipeline as the live frame itself, so edges land exactly
            # on the features they belong to. Fast (nearest) scaling - it's a 1px edge mask,
            # smooth interpolation would just gray it out.
            ov = self._recording_display_image(self._peaking_overlay)
            if self.view_rotation != 0:
                ov = ov.transformed(QTransform().rotate(self.view_rotation))
            ov_scaled = ov.scaled(scaled.size(), Qt.AspectRatioMode.IgnoreAspectRatio,
                                  Qt.TransformationMode.FastTransformation)
            painter.drawImage(x, y, ov_scaled)

        frame = QRectF(x, y, scaled.width(), scaled.height())
        self._last_image_rect = frame

        # Chimp review / download progress take over the whole frame - skip the guides.
        if self._review_image is not None:
            review_scaled = self._review_image.scaled(
                frame.size().toSize(), Qt.AspectRatioMode.KeepAspectRatio, Qt.TransformationMode.SmoothTransformation
            )
            rx = frame.left() + (frame.width() - review_scaled.width()) / 2
            ry = frame.top() + (frame.height() - review_scaled.height()) / 2
            painter.fillRect(frame, _qcolor("#000000"))
            painter.drawImage(int(rx), int(ry), review_scaled)
            painter.setPen(_qcolor(theme.Color.TEXT))
            painter.setFont(QFont(theme.Font.FAMILY, 11))
            painter.drawText(int(frame.left()) + 8, int(frame.top()) + 20, "Review")
            return

        if self._download_progress is not None:
            bytes_read, total = self._download_progress
            bar_w = frame.width() * 0.6
            bar_h = 14
            bar_x = frame.left() + (frame.width() - bar_w) / 2
            bar_y = frame.top() + frame.height() / 2 - bar_h / 2
            painter.setPen(_qcolor(theme.Color.TEXT))
            painter.setFont(QFont(theme.Font.FAMILY, 11))
            painter.drawText(int(bar_x), int(bar_y) - 8, "Downloading photo preview...")
            painter.setPen(QPen(_qcolor(theme.Color.TEXT_2), 1))
            painter.drawRect(QRectF(bar_x, bar_y, bar_w, bar_h))
            if total > 0:
                fraction = min(1.0, bytes_read / total)
                painter.fillRect(QRectF(bar_x, bar_y, bar_w * fraction, bar_h), _qcolor(theme.Color.ACCENT))
                label = "%d%%" % int(fraction * 100)
            else:
                painter.fillRect(QRectF(bar_x, bar_y, bar_w, bar_h), _qcolor(theme.Color.ACCENT, 70))
                label = "%.1f KB" % (bytes_read / 1024)
            painter.setPen(_qcolor(theme.Color.TEXT))
            painter.drawText(int(bar_x + bar_w) + 8, int(bar_y + bar_h - 2), label)
            return

        # Thirds/diagonals ALWAYS follow the effective capture area, independent of whether the
        # dashed Crop outline is shown (M3, 2026-07-12, ported from the iOS app's cropCGRect/
        # drawCropOutline split - see DEVELOPMENT_PLAN.md's 2026-07-09 guide-semantics fix for
        # the original reasoning: FHD/4K record 16:9, so guides drawn across the full 4:3-ish
        # preview were compositionally wrong whenever Crop happened to be off).
        if self.is_recording:
            # Once recording starts the live-view feed itself switches to show the real
            # cropped/exposed frame (set_recording's doc comment) - the full visible frame
            # already IS the effective capture area, so guide_rect stays `frame`; only the now-
            # redundant dashed outline is suppressed (replaced by this note).
            guide_rect = frame
            painter.setPen(_qcolor(theme.Color.RECORD))
            painter.setFont(QFont(theme.Font.FAMILY, 10))
            note = "● Recording"
            if self._recording_started_at is not None:
                total = int(time.monotonic() - self._recording_started_at)
                elapsed = ("%d:%02d:%02d" % (total // 3600, total % 3600 // 60, total % 60)
                           if total >= 3600 else "%02d:%02d" % (total // 60, total % 60))
                note += " · " + elapsed  # 2026-07-19, iOS parity (RecordingTimerChip)
            if self.recording_clip_number > 1:
                note += " · clip %d" % self.recording_clip_number  # M6, 2026-07-12
            note += " - live view now shows the actual crop & exposure"
            painter.drawText(int(frame.left()) + 8, int(frame.top()) + 20, note)
        else:
            # Guide semantics revised 2026-07-19 (user feedback, same change as iOS): in VIDEO
            # mode the crop is a fact of the camera (FHD/4K always record 16:9, format not
            # remotely changeable) - overlay always on, guides follow it; the 2K exception
            # records the full 4:3 sensor, its rect equals the frame and nothing draws. In
            # PHOTO mode the toggle governs both the overlay AND the guide span: off -> guides
            # across the whole visible frame.
            crop_shown = self.crop_mode == "video" or self.show_crop
            guide_rect = self._compute_guide_rect(frame) if crop_shown else frame
            if crop_shown:
                if guide_rect != frame:
                    # Dim everything OUTSIDE the capture area (user request 2026-07-12, same as
                    # the iOS app).
                    outside = QPainterPath()
                    outside.addRect(QRectF(frame))
                    inner = QPainterPath()
                    inner.addRect(QRectF(guide_rect))
                    painter.fillPath(outside.subtracted(inner), QColor(0, 0, 0, 115))
                # The outline draws even when the crop IS the full frame in PHOTO mode (4:3):
                # the toggle is tappable there, and a click with zero visible change reads as
                # broken (user feedback 2026-07-19). Video has no tappable toggle, so its
                # full-frame case (2K) stays clean. Also covers the "aspect not known yet"
                # note, which _draw_crop_outline itself handles.
                if self.crop_mode == "photo" or guide_rect != frame:
                    self._draw_crop_outline(painter, guide_rect)

        if self.show_thirds:
            pen = QPen(_qcolor(theme.Color.TEXT, 150))
            pen.setWidth(1)
            painter.setPen(pen)
            for i in (1, 2):
                fx = guide_rect.left() + guide_rect.width() * i / 3
                painter.drawLine(int(fx), int(guide_rect.top()), int(fx), int(guide_rect.bottom()))
                fy = guide_rect.top() + guide_rect.height() * i / 3
                painter.drawLine(int(guide_rect.left()), int(fy), int(guide_rect.right()), int(fy))

        if self.show_diagonals:
            pen = QPen(_qcolor(theme.Color.TEXT, 120))
            pen.setWidth(1)
            painter.setPen(pen)
            painter.drawLine(guide_rect.topLeft(), guide_rect.bottomRight())
            painter.drawLine(guide_rect.topRight(), guide_rect.bottomLeft())

    def _visual_fractions(self, fractions):
        """Transforms sensor-space crop fractions (x, y, w, h) into visual (rotated, on-screen)
        space - same mapping as the iOS app's visualCrop (2026-07-19 rotation parity). Identity
        when unrotated."""
        x, y, w, h = fractions
        if self.view_rotation == 90:
            return (1 - y - h, x, h, w)
        if self.view_rotation == -90:
            return (y, 1 - x - w, h, w)
        return fractions

    def _compute_guide_rect(self, frame) -> QRectF:
        """The effective capture-area rectangle thirds/diagonals should always follow (M3,
        2026-07-12) - geometry only, no drawing. Falls back to the full frame when no measured
        crop is available yet for the current mode/format/aspect (matches the old code's
        fallback, just no longer gated on the Crop toggle). Fractions are sensor-space and go
        through _visual_fractions so guides stay correct under manual rotation."""
        fractions = None
        if self.crop_mode == "video":
            if self.current_video_format:
                for prefix, rect_fractions in MEASURED_VIDEO_CROPS.items():
                    if self.current_video_format.upper().startswith(prefix):
                        fractions = rect_fractions
                        break
            if fractions is None:
                # No measured data yet - approximate: video is 16:9 centered in the 4:3 sensor,
                # which in sensor fractions is exactly (0, 0.125, 1, 0.75).
                fractions = (0.0, 0.125, 1.0, 0.75)
        else:
            fractions = MEASURED_PHOTO_CROPS.get(self.current_image_aspect)
            if fractions is None:
                return frame
        x0, y0, w, h = self._visual_fractions(fractions)
        return QRectF(frame.left() + x0 * frame.width(), frame.top() + y0 * frame.height(),
                      w * frame.width(), h * frame.height())

    def _draw_crop_outline(self, painter, rect: QRectF):
        """Draws the dashed outline + label for `rect` (already computed by
        `_compute_guide_rect`) - purely visual, independently controlled by the Crop toggle
        (M3, 2026-07-12: split out of the old `_draw_crop`, which used to compute geometry AND
        draw in one step, coupling the outline's visibility to whether thirds/diagonals could
        follow the real capture area at all)."""
        if self.crop_mode == "video":
            label = ("video crop · %s" % self.current_video_format if self.current_video_format
                      else "~16:9 video crop (approx)")
        else:
            if self.current_image_aspect is None or self.current_image_aspect not in MEASURED_PHOTO_CROPS:
                painter.setPen(_qcolor(theme.Color.ACCENT))
                painter.setFont(QFont(theme.Font.FAMILY, 10))
                painter.drawText(int(rect.left()) + 8, int(rect.bottom()) - 8,
                                 "photo aspect not known yet")
                return
            label = "photo crop · %s" % self.current_image_aspect

        pen = QPen(_qcolor(theme.Color.ACCENT, 230))
        pen.setWidth(2)
        pen.setStyle(Qt.PenStyle.DashLine)
        painter.setPen(pen)
        painter.drawRect(rect)
        painter.setPen(_qcolor(theme.Color.ACCENT))
        painter.setFont(QFont(theme.Font.FAMILY, 10))
        painter.drawText(int(rect.left()) + 6, int(rect.top()) + 16, label)


class FileBrowserDialog(QDialog):
    """Browse/download/delete files on the camera's SD card over Wi-Fi.

    GetFileList/GetFile/DeleteFile confirmed working live (2026-07-07). GetFileList needs a
    non-zero-width id range or the camera errors {"code":1502,...} (bug #11). Parsing keeps a
    raw-data fallback in case a future response shape differs from what was observed
    (path/date/filetype/protectStatus per entry)."""

    def __init__(self, session: CameraSession, parent=None):
        super().__init__(parent)
        self.setWindowTitle("Camera files")
        self.resize(560, 440)
        self.session = session

        layout = QVBoxLayout(self)

        self.list_widget = QListWidget()
        # 2026-07-19, iOS parity: multi-select for batch download/delete, per-row thumbnails,
        # double-click opens a MidThumb preview.
        self.list_widget.setSelectionMode(QListWidget.SelectionMode.ExtendedSelection)
        self.list_widget.setIconSize(QSize(56, 42))
        self.list_widget.itemDoubleClicked.connect(self._on_item_double_clicked)
        layout.addWidget(self.list_widget, stretch=1)

        btns = QHBoxLayout()
        refresh_btn = QPushButton("Refresh")
        refresh_btn.clicked.connect(self._refresh)
        btns.addWidget(refresh_btn)

        download_btn = QPushButton("Download selected")
        download_btn.clicked.connect(self._download_selected)
        btns.addWidget(download_btn)

        delete_btn = QPushButton("Delete selected")
        delete_btn.clicked.connect(self._delete_selected)
        btns.addWidget(delete_btn)

        layout.addLayout(btns)

        self.progress_bar = QProgressBar()
        self.progress_bar.setVisible(False)
        layout.addWidget(self.progress_bar)

        self._items_by_path = {}       # camera path -> QListWidgetItem (for thumbnail delivery)
        self._thumb_cache = {}         # camera path -> QIcon (2026-07-19: Refresh after a
                                       # delete re-lists everything - without this every
                                       # remaining file's thumbnail would be re-fetched)
        self._batch_remaining = 0      # >0 while a multi-file download is in flight
        self._batch_total = 0
        self._batch_failures = []

        self.session.commandResult.connect(self._on_command_result)
        self.session.fileDownloaded.connect(self._on_file_downloaded)
        self.session.fileDownloadProgress.connect(self._on_download_progress)
        self.session.thumbReady.connect(self._on_thumb_ready)
        self.session.previewReady.connect(self._on_preview_ready)

        self._refresh()

    def closeEvent(self, event):
        # Whatever thumbnails are still queued would be fetched into a void after the
        # disconnects below - drop them so the session thread doesn't waste serial HTTP time.
        self.session.cancel_pending_thumbnails()
        try:
            self.session.commandResult.disconnect(self._on_command_result)
            self.session.fileDownloaded.disconnect(self._on_file_downloaded)
            self.session.fileDownloadProgress.disconnect(self._on_download_progress)
            self.session.thumbReady.disconnect(self._on_thumb_ready)
            self.session.previewReady.disconnect(self._on_preview_ready)
        except Exception:
            pass
        event.accept()

    def _refresh(self):
        self.list_widget.clear()
        self.list_widget.addItem("Loading...")
        # id_end must NOT be 0 (bug #11): a zero-width range (0..0) is rejected by the camera
        # with {"code":1502,...}. Any real range works regardless of filetype/RC-session state.
        cmd = CmdFileList(permit_raw=True, permit_jpg=True, id_start=0, id_end=9999)
        self.session.request_command(cmd.to_json())

    def _selected_paths(self) -> list:
        paths = []
        for item in self.list_widget.selectedItems():
            path = item.data(Qt.ItemDataRole.UserRole)
            if path:
                paths.append(path)
        return paths

    def _download_selected(self):
        paths = self._selected_paths()
        if not paths:
            QMessageBox.warning(self, "No selection", "Select a file first.")
            return
        if len(paths) == 1:
            suggested_name = paths[0].rsplit("/", 1)[-1]
            save_path, _ = QFileDialog.getSaveFileName(self, "Save file as", suggested_name)
            if not save_path:
                return
            targets = [(paths[0], save_path)]
        else:
            # Batch (2026-07-19, iOS parity with batch Save to Photos - the Mac equivalent is
            # a folder): pick a directory once, keep the original filenames, queue everything -
            # the session's serial queue downloads them one after another.
            directory = QFileDialog.getExistingDirectory(self, "Save %d files to..." % len(paths))
            if not directory:
                return
            targets = [(p, os.path.join(directory, p.rsplit("/", 1)[-1])) for p in paths]
        self._batch_remaining = len(targets)
        self._batch_total = len(targets)
        self._batch_failures = []
        self.progress_bar.setVisible(True)
        self.progress_bar.setRange(0, 0)  # indeterminate until the first progress update
        self.progress_bar.setFormat("Downloading...")
        for path, save_path in targets:
            cmd = CmdFileGet(path, CmdEnumFileQuality.Best)
            self.session.request_file_download(cmd.to_json(), save_path)

    def _on_download_progress(self, bytes_read: int, total: int):
        kb = bytes_read // 1024
        if total > 0:
            self.progress_bar.setRange(0, total)
            self.progress_bar.setValue(bytes_read)
            self.progress_bar.setFormat("%%p%% (%d KB)" % kb)
        else:
            self.progress_bar.setFormat("%d KB downloaded..." % kb)

    def _delete_selected(self):
        paths = self._selected_paths()
        if not paths:
            QMessageBox.warning(self, "No selection", "Select a file first.")
            return
        # DeleteFile's wire format takes an array of paths - one command either way (same fact
        # the iOS batch delete relies on), so multi-select delete is a single request.
        if len(paths) == 1:
            question = "Delete %s from the camera? This cannot be undone." % paths[0]
        else:
            question = "Delete %d files from the camera? This cannot be undone." % len(paths)
        confirm = QMessageBox.question(self, "Delete files", question)
        if confirm != QMessageBox.StandardButton.Yes:
            return
        cmd = CmdFileDelete(paths)
        self.session.request_command(cmd.to_json())

    def _on_item_double_clicked(self, item: QListWidgetItem):
        path = item.data(Qt.ItemDataRole.UserRole)
        if path:
            self.session.request_file_preview(path)

    def _on_thumb_ready(self, path: str, image: QImage):
        icon = QIcon(QPixmap.fromImage(image))
        self._thumb_cache[path] = icon
        item = self._items_by_path.get(path)
        if item is not None:
            item.setIcon(icon)

    def _on_preview_ready(self, path: str, image: QImage):
        dialog = QDialog(self)
        dialog.setWindowTitle(path.rsplit("/", 1)[-1])
        v = QVBoxLayout(dialog)
        label = QLabel()
        label.setPixmap(QPixmap.fromImage(image).scaled(
            720, 540, Qt.AspectRatioMode.KeepAspectRatio, Qt.TransformationMode.SmoothTransformation))
        v.addWidget(label)
        dialog.exec()

    def _on_command_result(self, command: str, status: int, body: str):
        if command == "GetFileList":
            self._populate_from_list_response(status, body)
        elif command == "DeleteFile":
            # is_camera_success, not status == 200 (M1, 2026-07-12) - the camera signals failure
            # as HTTP 200 + {"code":<err>}, same body-code shape ported from the iOS app's
            # equivalent fix.
            if is_camera_success(status, body):
                self._refresh()
            else:
                QMessageBox.warning(self, "Delete failed", "status=%s body=%s" % (status, body))

    def _populate_from_list_response(self, status: int, body: str):
        self.list_widget.clear()
        self._items_by_path = {}
        if status != 200:
            self.list_widget.addItem("GetFileList failed: status=%s body=%s" % (status, body[:200]))
            return
        try:
            parsed = json.loads(body)
        except Exception:
            self.list_widget.addItem("Could not parse response as JSON: %s" % body[:300])
            return

        data = parsed.get("data") if isinstance(parsed, dict) else None
        candidates = None
        for key in ("file_list", "files", "list"):
            if isinstance(data, dict) and key in data:
                candidates = data[key]
                break
        if candidates is None and isinstance(data, list):
            candidates = data
        if candidates is None:
            self.list_widget.addItem("Unrecognized response shape, raw: %s" % json.dumps(parsed)[:300])
            return
        if not candidates:
            self.list_widget.addItem("(no files)")
            return

        for entry in candidates:
            if isinstance(entry, str):
                path, display = entry, entry
            elif isinstance(entry, dict):
                path = entry.get("path") or entry.get("name") or entry.get("file") or json.dumps(entry)
                # Confirmed real shape (2026-07-07): path/date (unix)/filetype/protectStatus.
                filetype = entry.get("filetype", "")
                date_str = ""
                raw_date = entry.get("date")
                if raw_date is not None:
                    try:
                        date_str = datetime.fromtimestamp(int(raw_date)).strftime("%Y-%m-%d %H:%M")
                    except (ValueError, TypeError, OSError):
                        date_str = str(raw_date)
                filename = path.rsplit("/", 1)[-1]
                display = "  ".join(p for p in (filetype, date_str, filename) if p) or path
            else:
                path, display = str(entry), str(entry)
            item = QListWidgetItem(display)
            item.setData(Qt.ItemDataRole.UserRole, path)
            self.list_widget.addItem(item)
            self._items_by_path[path] = item
        # Thumbnails (2026-07-19, iOS parity): queued AFTER the list is already usable - the
        # session's serial queue fetches them one per live-view-loop pass (so frames keep
        # flowing), and _on_thumb_ready fills the icons in as they land. Cached ones apply
        # immediately and aren't re-fetched.
        for path, item in self._items_by_path.items():
            cached = self._thumb_cache.get(path)
            if cached is not None:
                item.setIcon(cached)
            else:
                self.session.request_file_thumbnail(path)

    def _on_file_downloaded(self, save_path: str, success: bool, message: str):
        if not success:
            self._batch_failures.append("%s: %s" % (save_path, message))
        if self._batch_remaining > 1:
            self._batch_remaining -= 1
            self.progress_bar.setRange(0, 0)
            self.progress_bar.setFormat("Downloading... (%d left)" % self._batch_remaining)
            return
        self._batch_remaining = 0
        self.progress_bar.setVisible(False)
        if self._batch_failures:
            QMessageBox.warning(self, "Download finished with errors", "\n".join(self._batch_failures))
        elif success and self._batch_total > 1:
            QMessageBox.information(self, "Download complete",
                                    "Downloaded %d files to %s" % (self._batch_total, os.path.dirname(save_path)))
        elif success:
            QMessageBox.information(self, "Download complete", "Saved to %s (%s)" % (save_path, message))
        self._batch_failures = []
        self._batch_total = 0


class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("YI M1 Monitor")
        self.resize(940, 760)

        # M5, 2026-07-12: persists the manual "network to restore after disconnect" fallback
        # (see _set_restore_wifi_network) across app launches.
        self._settings = QSettings("YiM1Monitor", "App")

        self.session: Optional[CameraSession] = None
        # Every session ever created, incl. ones abandoned by _reset_connection - see closeEvent.
        self._all_sessions: list[CameraSession] = []
        self._make_and_wire_session()

        self._connected = False
        self._mode = "photo"  # "photo" | "video"
        self._setting_combos = {}       # metadata_key -> (combo, enum_cls)
        self._pending_setting_values = {}
        self._setting_chips = {}        # metadata_key -> chip QWidget (for show/hide by mode)
        self._video_readonly = {}       # metadata_key -> value QLabel

        central = QWidget()
        root = QVBoxLayout(central)
        root.setContentsMargins(0, 0, 0, 0)
        root.setSpacing(0)

        root.addWidget(self._build_titlebar())
        root.addWidget(self._build_mode_toggle())

        self.live_view = LiveViewWidget()
        self.live_view.focusRequested.connect(self._on_focus_requested)
        root.addWidget(self.live_view, stretch=1)

        root.addWidget(self._build_control_row())
        root.addWidget(self._build_settings_strip())

        self.setCentralWidget(central)

        self._set_mode("photo")
        self._set_controls_enabled(False)
        self._refresh_connection_ui()

    # ---- construction helpers ----

    def _build_titlebar(self) -> QWidget:
        bar = QWidget()
        h = QHBoxLayout(bar)
        h.setContentsMargins(theme.Space.LG, theme.Space.MD, theme.Space.LG, theme.Space.SM)

        title = QLabel("YI M1 Monitor")
        title.setProperty("tier", "secondary")
        h.addWidget(title)
        h.addStretch(1)

        self.status_chip = QLabel()
        self.status_chip.setTextFormat(Qt.TextFormat.RichText)
        self.status_chip.setStyleSheet(theme.status_chip_qss())
        h.addWidget(self.status_chip)

        self.menu_btn = QPushButton("Connection")
        menu = QMenu(self.menu_btn)
        # Menu grouping reworked 2026-07-20 (user: "пункты странно распределены"): two clean
        # groups - the connect/disconnect ACTIONS, then SETTINGS. "Auto-restart recording" was
        # dropped from here entirely: since 2026-07-19 it's a first-class chip in the video
        # settings strip, and having it in both places (checkable menu item + chip) was the
        # main thing making this menu look like a junk drawer.
        self.act_connect = menu.addAction("Connect (Bluetooth)", self._connect_ble)
        self.act_connect_direct = menu.addAction("Connect (already on camera Wi-Fi)", self._connect_direct)
        menu.addSeparator()
        self.act_disconnect = menu.addAction("Disconnect", self._disconnect)
        self.act_reset = menu.addAction("Reset connection", self._reset_connection)
        menu.addSeparator()
        # M5, 2026-07-12: fallback for when the automatic previous-network detection
        # (system_profiler, then networksetup) can't determine it - see camera_session.py's
        # get_current_wifi_ssid_via_system_profiler and _do_connect's capture chain.
        menu.addAction("Set network to restore on disconnect...", self._set_restore_wifi_network)
        self.menu_btn.setMenu(menu)
        h.addWidget(self.menu_btn)
        return bar

    def _build_mode_toggle(self) -> QWidget:
        wrap = QWidget()
        h = QHBoxLayout(wrap)
        h.setContentsMargins(0, theme.Space.SM, 0, theme.Space.SM)
        h.addStretch(1)

        seg = QWidget()
        seg.setObjectName("modeToggle")
        seg.setStyleSheet(theme.mode_toggle_qss())
        sh = QHBoxLayout(seg)
        sh.setContentsMargins(3, 3, 3, 3)
        sh.setSpacing(0)

        self.photo_mode_btn = QPushButton("Photo")
        self.photo_mode_btn.setCheckable(True)
        self.photo_mode_btn.setAutoExclusive(True)
        self.photo_mode_btn.setIcon(icons.icon("camera", 16))
        self.photo_mode_btn.setIconSize(QSize(16, 16))
        self.photo_mode_btn.clicked.connect(lambda: self._set_mode("photo"))
        sh.addWidget(self.photo_mode_btn)

        self.video_mode_btn = QPushButton("Video")
        self.video_mode_btn.setCheckable(True)
        self.video_mode_btn.setAutoExclusive(True)
        self.video_mode_btn.setIcon(icons.icon("video", 16))
        self.video_mode_btn.setIconSize(QSize(16, 16))
        self.video_mode_btn.clicked.connect(lambda: self._set_mode("video"))
        sh.addWidget(self.video_mode_btn)

        h.addWidget(seg)
        h.addStretch(1)
        return wrap

    def _build_control_row(self) -> QWidget:
        row = QWidget()
        h = QHBoxLayout(row)
        h.setContentsMargins(theme.Space.XL, theme.Space.MD, theme.Space.XL, theme.Space.MD)

        # Left: Files
        left = QHBoxLayout()
        left.addStretch(1)
        self.files_btn = QPushButton("Files")
        self.files_btn.setIcon(icons.icon("folder", 16))
        self.files_btn.setIconSize(QSize(16, 16))
        self.files_btn.setMinimumWidth(96)
        self.files_btn.clicked.connect(self._open_file_browser)
        left.addWidget(self.files_btn)
        left.addStretch(2)
        h.addLayout(left, stretch=1)

        # Center: shutter / record
        self.shutter = ShutterButton()
        self.shutter.clicked.connect(self._on_shutter)
        self.shutter.longPressed.connect(self._on_shutter_long_press)
        h.addWidget(self.shutter, stretch=0)

        # Right: guide toggles + view tools (peaking/rotate added 2026-07-19, iOS parity)
        right = QHBoxLayout()
        right.addStretch(2)
        self.crop_btn = self._make_guide_toggle("Crop", "crop", self._on_crop_toggled)
        self.thirds_btn = self._make_guide_toggle("Thirds", "thirds", self._on_thirds_toggled)
        self.diag_btn = self._make_guide_toggle("Diagonals", "diagonals", self._on_diagonals_toggled)
        right.addWidget(self.crop_btn)
        right.addWidget(self.thirds_btn)
        right.addWidget(self.diag_btn)

        self.peaking_btn = QPushButton("Peaking")
        self.peaking_btn.setCheckable(True)
        self.peaking_btn.setEnabled(_PEAKING_AVAILABLE)
        if not _PEAKING_AVAILABLE:
            self.peaking_btn.setToolTip("Focus peaking unavailable - %s" % _PEAKING_IMPORT_ERROR)
        log("focus peaking available: %s%s" % (
            _PEAKING_AVAILABLE, "" if _PEAKING_AVAILABLE else " (%s)" % _PEAKING_IMPORT_ERROR))
        self._style_plain_toggle(self.peaking_btn, False)
        self.peaking_btn.toggled.connect(self._on_peaking_toggled)
        right.addWidget(self.peaking_btn)

        self.rotate_btn = QPushButton("Rotate 0°")
        self._style_plain_toggle(self.rotate_btn, False)
        self.rotate_btn.clicked.connect(self._on_rotate_clicked)
        right.addWidget(self.rotate_btn)

        right.addStretch(1)
        h.addLayout(right, stretch=1)
        return row

    def _make_guide_toggle(self, text: str, icon_name: str, slot) -> QPushButton:
        btn = QPushButton(text)
        btn.setCheckable(True)
        btn.setIconSize(QSize(16, 16))
        btn._icon_name = icon_name
        self._style_guide_btn(btn, False)
        btn.toggled.connect(slot)
        return btn

    def _style_guide_btn(self, btn: QPushButton, active: bool):
        btn.setStyleSheet("QPushButton{%s border-radius:8px; padding:7px 12px; font-size:12px;}"
                          % theme.guide_toggle_qss(active))
        color = theme.Color.ACCENT if active else theme.Color.TEXT_2
        btn.setIcon(icons.icon(btn._icon_name, 16, color))

    def _style_plain_toggle(self, btn: QPushButton, active: bool):
        """Guide-toggle look for text-only buttons (peaking/rotate have no hand-drawn icon)."""
        btn.setStyleSheet("QPushButton{%s border-radius:8px; padding:7px 12px; font-size:12px;}"
                          % theme.guide_toggle_qss(active))

    def _build_settings_strip(self) -> QWidget:
        setting_defs = {
            "ExposureMode": ("Mode", RcExposureMode, RcCmdSetCameraMode),
            "MeteringMode": ("Metering", RcMeteringMode, RcCmdSetMeteringMode),
            "FocusMode": ("Focus", RcFocusMode, RcCmdSetFocusingMode),
            "ImageQuality": ("Quality", RcImageQuality, RcCmdSetImageQuality),
            "ImageAspect": ("Aspect", RcImageAspect, RcCmdSetImageAspect),
            "FileFormat": ("Format", RcFileFormat, RcCmdSetImageFormat),
            "DriveMode": ("Drive", RcDriveMode, RcCmdSetDriveMode),
            "Fnumber": ("Aperture", RcFStop, RcCmdSetFStop),
            "ShutterSpeed": ("Shutter", RcShutterSpeed, RcCmdSetShutterSpeed),
            "EV": ("EV", RcEvOffset, RcCmdSetExposureValueOffset),
            "ISOSetting": ("ISO", RcIso, RcCmdSetIso),
            "WB": ("WB", RcWhiteBalance, RcCmdSetWhiteBalanceMode),
            "ColorMode": ("Color", RcColorStyle, RcCmdSetColorStyle),
            "VideoFormat": ("Format", RcVideoFormat, RcCmdSetVideoFormat),
        }

        # Build every chip once; _relayout_settings() places the mode-relevant ones into the
        # grid (wrapping to ~2 rows) and hides the rest - so switching modes never leaves holes.
        for key in SHARED_SETTING_KEYS + PHOTO_SETTING_KEYS + VIDEO_SETTING_KEYS:
            label, enum_cls, wrapper_cls = setting_defs[key]
            self._setting_chips[key] = self._make_setting_chip(label, enum_cls, wrapper_cls, key)
        for cap, key in (("Audio", "VASwitch"), ("EIS", "VideoEis")):
            chip, val = self._make_readonly_chip(cap)
            self._setting_chips[key] = chip
            self._video_readonly[key] = val
        # Auto-restart toggle as a first-class strip chip (2026-07-19, iOS parity) - it used to
        # be discoverable only inside the Connection menu; now its state reads at a glance.
        self._setting_chips["_AutoRestart"] = self._make_autorestart_chip()

        self.settings_container = QWidget()
        self.settings_grid = QGridLayout(self.settings_container)
        self.settings_grid.setContentsMargins(theme.Space.XL, theme.Space.SM, theme.Space.XL, theme.Space.MD)
        self.settings_grid.setHorizontalSpacing(theme.Space.MD)
        self.settings_grid.setVerticalSpacing(theme.Space.SM)
        return self.settings_container

    def _relayout_settings(self):
        """Place the chips relevant to the current mode into the grid (shared + photo, or
        shared + video read-only), wrapping across SETTINGS_COLUMNS columns; hide the rest."""
        keys = SHARED_SETTING_KEYS + (
            PHOTO_SETTING_KEYS if self._mode == "photo"
            else VIDEO_SETTING_KEYS + VIDEO_READONLY_KEYS + ["_AutoRestart"]
        )
        # Hide + unparent everything first, then add-and-show the mode's chips. Order matters:
        # setVisible(True) must come AFTER addWidget reparents the chip, or Qt drops the visible
        # state during the reparent (bit the video read-only chips, which aren't in the grid on
        # the first photo-mode layout).
        for chip in self._setting_chips.values():
            self.settings_grid.removeWidget(chip)
            chip.setVisible(False)
        for i, key in enumerate(keys):
            chip = self._setting_chips[key]
            self.settings_grid.addWidget(chip, i // SETTINGS_COLUMNS, i % SETTINGS_COLUMNS)
            chip.setVisible(True)

    def _make_setting_chip(self, label, enum_cls, wrapper_cls, metadata_key) -> QWidget:
        chip = QWidget()
        v = QVBoxLayout(chip)
        v.setContentsMargins(0, 0, 0, 0)
        v.setSpacing(3)
        cap = QLabel(label)
        cap.setProperty("tier", "muted")
        combo = QComboBox()
        combo.addItems([_display_label(metadata_key, e.value) for e in enum_cls])
        combo.setMinimumWidth(96)
        # activated (not currentIndexChanged) fires only on real user interaction, so metadata
        # syncing via setCurrentIndex can never re-trigger a command.
        combo.activated.connect(
            lambda idx, ec=enum_cls, wc=wrapper_cls, mk=metadata_key: self._on_setting_changed(idx, ec, wc, mk)
        )
        v.addWidget(cap)
        v.addWidget(combo)
        self._setting_combos[metadata_key] = (combo, enum_cls)
        return chip

    def _make_readonly_chip(self, label):
        chip = QWidget()
        v = QVBoxLayout(chip)
        v.setContentsMargins(0, 0, 0, 0)
        v.setSpacing(3)
        cap = QLabel(label + " (read-only)")
        cap.setProperty("tier", "muted")
        val = QLabel("—")
        val.setProperty("tier", "secondary")
        v.addWidget(cap)
        v.addWidget(val)
        return chip, val

    def _make_autorestart_chip(self) -> QWidget:
        chip = QWidget()
        v = QVBoxLayout(chip)
        v.setContentsMargins(0, 0, 0, 0)
        v.setSpacing(3)
        cap = QLabel("Auto-restart")
        cap.setProperty("tier", "muted")
        self.auto_restart_chip_btn = QPushButton("Off")
        self.auto_restart_chip_btn.setCheckable(True)
        self._style_plain_toggle(self.auto_restart_chip_btn, False)
        self.auto_restart_chip_btn.toggled.connect(self._on_auto_restart_toggled)
        v.addWidget(cap)
        v.addWidget(self.auto_restart_chip_btn)
        return chip

    # ---- mode switch ----

    def _set_mode(self, mode: str):
        self._mode = mode
        self.photo_mode_btn.setChecked(mode == "photo")
        self.video_mode_btn.setChecked(mode == "video")
        self.shutter.set_mode(mode)
        self.live_view.set_crop_mode(mode)
        # Crop is a fact in video mode (2026-07-19): the overlay is permanently on there, so
        # the toggle locks - shown active but disabled. Photo mode restores the user's own
        # toggle state and re-enables it (when connected).
        if mode == "video":
            self.crop_btn.setEnabled(False)
            self._style_guide_btn(self.crop_btn, True)
        else:
            self.crop_btn.setEnabled(self._connected)
            self._style_guide_btn(self.crop_btn, self.crop_btn.isChecked())
        self._relayout_settings()

    # ---- settings sync (bug #10/#12 logic preserved verbatim) ----

    def _on_setting_changed(self, idx: int, enum_cls, wrapper_cls, metadata_key: str):
        if self.session is None or not self._connected:
            return
        values = list(enum_cls)
        if idx < 0 or idx >= len(values):
            return
        chosen = values[idx]
        cmd = wrapper_cls(chosen)
        self.session.request_command(cmd.to_json())

        # Suppress metadata sync for this field until the camera confirms the new value or a
        # timeout passes (bug #10/#12). NEVER_EXPIRE keys are trusted indefinitely because their
        # metadata never reflects the pending value.
        if metadata_key in NEVER_EXPIRE_METADATA_KEYS:
            deadline = float("inf")
            log("_on_setting_changed: %s -> requested %r, suppressing metadata sync indefinitely "
                "(this field's metadata doesn't reliably confirm changes - see bug #12)" % (
                    metadata_key, chosen.value))
        else:
            timeout = SETTING_CONFIRM_TIMEOUT.get(metadata_key, DEFAULT_SETTING_CONFIRM_TIMEOUT)
            deadline = time.time() + timeout
            log("_on_setting_changed: %s -> requested %r, suppressing metadata sync for %.1fs" % (
                metadata_key, chosen.value, timeout))
        self._pending_setting_values[metadata_key] = (chosen.value, deadline)

        # ImageAspect drives the photo crop overlay directly; update it optimistically since its
        # metadata may never confirm (bug #12).
        if metadata_key == "ImageAspect":
            self.live_view.set_image_aspect(chosen.value)

    def _on_live_metadata(self, data: dict):
        self.live_view.set_video_format(data.get("VideoFormat"))
        if "ImageAspect" not in self._pending_setting_values:
            self.live_view.set_image_aspect(data.get("ImageAspect"))

        for key, val_label in self._video_readonly.items():
            v = data.get(key)
            if v is not None:
                val_label.setText(str(v))

        now = time.time()
        for metadata_key, (combo, enum_cls) in self._setting_combos.items():
            value = data.get(metadata_key)
            if value is None:
                continue

            pending = self._pending_setting_values.get(metadata_key)
            if pending is not None:
                expected_value, deadline = pending
                allowed_timeout = SETTING_CONFIRM_TIMEOUT.get(metadata_key, DEFAULT_SETTING_CONFIRM_TIMEOUT)
                if value == expected_value:
                    log("_on_live_metadata: %s confirmed as %r" % (metadata_key, value))
                    del self._pending_setting_values[metadata_key]
                elif now < deadline:
                    continue
                else:
                    log("_on_live_metadata: %s NEVER confirmed %r - gave up after %.1fs, camera "
                        "reports %r instead (see bug #12 in ARCHITECTURE.md)" % (
                            metadata_key, expected_value, allowed_timeout, value))
                    del self._pending_setting_values[metadata_key]

            for i, e in enumerate(enum_cls):
                if e.value == value:
                    if combo.currentIndex() != i:
                        combo.setCurrentIndex(i)
                    break

    # ---- capture actions ----

    def _on_shutter(self):
        if self.session is None or not self._connected:
            return
        if self._mode == "photo":
            self.session.request_shoot_with_review()
        else:
            self.session.request_toggle_recording()

    def _on_shutter_long_press(self):
        """Escape hatch for a desynced camera (M1, 2026-07-12, ported from the iOS app: camera
        stuck recording while the UI believes it isn't) - force-sends VideoRecordingStop
        regardless of believed state. Video mode only, same as the iOS gesture."""
        if self.session is None or not self._connected or self._mode != "video":
            return
        self.session.request_force_stop_recording()

    def _trigger_autofocus(self):
        if self.session is not None and self._connected:
            self.session.request_command(RcCmdTriggerFocus(RcTriggerFocusMode.Auto).to_json())

    def _on_focus_requested(self, x: int, y: int):
        if self.session is not None and self._connected:
            cmd = RcCmdTriggerFocus(RcTriggerFocusMode.Manual, (x, y))
            self.session.request_command(cmd.to_json())
            self.status_chip.setText("Focus at (%d, %d)" % (x, y))

    def _on_photo_review_progress(self, bytes_read: int, total: int):
        self.live_view.show_download_progress(bytes_read, total)

    def _on_photo_review_ready(self, image: QImage):
        self.live_view.show_photo_review(image)

    def _on_photo_review_failed(self, reason: str):
        self.live_view.clear_review()
        self._set_status("Photo taken, review unavailable: %s" % reason)

    # ---- guide toggles ----

    def _on_crop_toggled(self, checked):
        self.live_view.show_crop = checked
        self._style_guide_btn(self.crop_btn, checked)
        self.live_view.update()

    def _on_thirds_toggled(self, checked):
        self.live_view.show_thirds = checked
        self._style_guide_btn(self.thirds_btn, checked)
        self.live_view.update()

    def _on_peaking_toggled(self, checked):
        self._style_plain_toggle(self.peaking_btn, checked)
        if not checked:
            self.live_view.set_peaking_overlay(None)

    def _on_rotate_clicked(self):
        rotation = self.live_view.cycle_view_rotation()
        self.rotate_btn.setText("Rotate %d°" % rotation)
        self._style_plain_toggle(self.rotate_btn, rotation != 0)

    #: Sobel gradient magnitude (|gx|+|gy| on a 0-255 grey frame) above which a pixel counts as
    #: "in focus" and gets painted. Tunable: lower = more of the frame lights up. ~150 lands
    #: close to what cv2.Canny(60, 180) used to mark, without the hysteresis pass.
    PEAKING_EDGE_THRESHOLD = 150

    def _compute_peaking(self, image: QImage) -> Optional[QImage]:
        """Focus peaking (2026-07-19, iOS parity; numpy-only since 2026-07-20 - see the import
        block for why cv2 had to go): Sobel edge magnitude of the live frame, painted amber on a
        transparent overlay. Pure-numpy slicing convolution on a ~640x480 frame is a few ms,
        cheap enough per delivered frame on the GUI thread (unlike iOS, where MainActor
        contention interacts with the stream's frame-dropping policy and forced it off-thread).
        A plain gradient threshold is also what most focus-peaking implementations use - it
        marks high local contrast, which is exactly "what's sharp"."""
        rgb = image.convertToFormat(QImage.Format.Format_RGB888)
        w, h = rgb.width(), rgb.height()
        if w < 3 or h < 3:
            return None
        buf = np.frombuffer(rgb.constBits(), np.uint8, count=rgb.sizeInBytes())
        arr = buf.reshape(h, rgb.bytesPerLine())[:, : w * 3].reshape(h, w, 3)
        # Rec. 601 luma, float32 so the gradient math doesn't wrap around uint8.
        g = (arr[:, :, 0] * 0.299 + arr[:, :, 1] * 0.587 + arr[:, :, 2] * 0.114).astype(np.float32)
        # 3x3 Sobel via slicing (no scipy): each term is the shifted neighbourhood.
        gx = ((g[:-2, 2:] + 2 * g[1:-1, 2:] + g[2:, 2:])
              - (g[:-2, :-2] + 2 * g[1:-1, :-2] + g[2:, :-2]))
        gy = ((g[2:, :-2] + 2 * g[2:, 1:-1] + g[2:, 2:])
              - (g[:-2, :-2] + 2 * g[:-2, 1:-1] + g[:-2, 2:]))
        magnitude = np.abs(gx) + np.abs(gy)  # L1 - as good as sqrt for a threshold, cheaper
        rgba = np.zeros((h, w, 4), np.uint8)
        # The Sobel result is (h-2, w-2) - it has no values for the 1px border, so inset it.
        rgba[1:-1, 1:-1][magnitude > self.PEAKING_EDGE_THRESHOLD] = (245, 166, 35, 230)  # ACCENT
        return QImage(rgba.data, w, h, w * 4, QImage.Format.Format_RGBA8888).copy()

    def _on_diagonals_toggled(self, checked):
        self.live_view.show_diagonals = checked
        self._style_guide_btn(self.diag_btn, checked)
        self.live_view.update()

    def _open_file_browser(self):
        if self.session is None:
            return
        dialog = FileBrowserDialog(self.session, self)
        dialog.exec()

    # ---- connection ----

    def _connect_ble(self):
        if self._connected:
            return
        self._set_status("Pairing - check the camera screen...")
        if not self.session.isRunning():
            self.session.start()
        self.session.request_connect()

    def _connect_direct(self):
        if self._connected:
            return
        self._set_status("Connecting (already on camera Wi-Fi)...")
        if not self.session.isRunning():
            self.session.start()
        self.session.request_connect_direct()

    def _disconnect(self):
        if self._connected:
            self._set_status("Disconnecting...")
            self.session.request_disconnect()

    def _set_restore_wifi_network(self):
        """M5, 2026-07-12: lets the user configure the manual fallback network for the
        Wi-Fi-restore-on-disconnect feature - only consulted when both auto-detects (in
        camera_session.py's _do_connect capture chain) come up empty. Persisted via QSettings so
        it survives across app launches; applied to the CURRENT session immediately (it's read
        again at the next `_do_connect` regardless, but this makes the change take effect without
        requiring a restart if the user reconnects within the same session)."""
        current = self._settings.value("restore_wifi_ssid", "", type=str)
        text, ok = QInputDialog.getText(
            self, "Restore Wi-Fi on disconnect",
            "Network name (SSID) to rejoin after disconnecting from the camera - only used if "
            "automatic detection fails. Leave blank to disable.",
            text=current,
        )
        if not ok:
            return
        ssid = text.strip()
        self._settings.setValue("restore_wifi_ssid", ssid)
        if self.session is not None:
            self.session.manual_restore_ssid = ssid or None

    def _on_auto_restart_toggled(self, checked: bool):
        """M6, 2026-07-12: near-continuous recording via app-side stop/start just under the
        camera's own recording-length limits - see camera_session.py's
        _maybe_auto_restart_recording/_perform_auto_restart. Single control since 2026-07-20:
        the settings-strip chip (the duplicate Connection-menu item was removed)."""
        if self.session is not None:
            self.session.auto_restart_recording = checked
        chip_btn = getattr(self, "auto_restart_chip_btn", None)
        if chip_btn is not None:
            chip_btn.setText("On" if checked else "Off")
            self._style_plain_toggle(chip_btn, checked)

    def _make_and_wire_session(self):
        self.session = CameraSession()
        self.session.manual_restore_ssid = self._settings.value("restore_wifi_ssid", "", type=str) or None
        # M6, 2026-07-12: carry the toggle's current state into a freshly (re)created session -
        # not persisted across launches, but should survive _reset_connection within one launch.
        # Guarded because the very first call (from __init__) runs before the settings strip has
        # created the chip.
        chip_btn = getattr(self, "auto_restart_chip_btn", None)
        self.session.auto_restart_recording = chip_btn.isChecked() if chip_btn else False
        self._all_sessions.append(self.session)
        self.session.paired.connect(self._on_paired)
        self.session.wifiSwitched.connect(self._on_wifi_switched)
        self.session.connected.connect(self._on_connected)
        self.session.frameReady.connect(self._on_frame)
        self.session.statusUpdated.connect(self._on_status)
        self.session.liveMetadataUpdated.connect(self._on_live_metadata)
        self.session.photoReviewProgress.connect(self._on_photo_review_progress)
        self.session.photoReviewReady.connect(self._on_photo_review_ready)
        self.session.photoReviewFailed.connect(self._on_photo_review_failed)
        self.session.recordingStateChanged.connect(self._on_recording_state)
        self.session.recordingClipNumberChanged.connect(self._on_recording_clip_number)
        self.session.errorOccurred.connect(self._on_error)
        self.session.disconnected.connect(self._on_disconnected)
        self.session.connectionLost.connect(self._on_connection_lost)

    def _reset_connection(self):
        """Abandon the current session thread (which may be stuck in a blocking BLE/HTTP call
        with no clean cancellation hook) and start clean. The old thread is not stopped/waited
        on - its signals are just disconnected so it can no longer affect the UI; it becomes a
        harmless orphan the OS cleans up on exit."""
        if self.session is not None:
            try:
                self.session.paired.disconnect(self._on_paired)
                self.session.wifiSwitched.disconnect(self._on_wifi_switched)
                self.session.connected.disconnect(self._on_connected)
                self.session.frameReady.disconnect(self._on_frame)
                self.session.statusUpdated.disconnect(self._on_status)
                self.session.liveMetadataUpdated.disconnect(self._on_live_metadata)
                self.session.photoReviewProgress.disconnect(self._on_photo_review_progress)
                self.session.photoReviewReady.disconnect(self._on_photo_review_ready)
                self.session.photoReviewFailed.disconnect(self._on_photo_review_failed)
                self.session.recordingStateChanged.disconnect(self._on_recording_state)
                self.session.recordingClipNumberChanged.disconnect(self._on_recording_clip_number)
                self.session.errorOccurred.disconnect(self._on_error)
                self.session.disconnected.disconnect(self._on_disconnected)
                self.session.connectionLost.disconnect(self._on_connection_lost)
            except Exception:
                pass

        self._make_and_wire_session()
        self._connected = False
        self._set_controls_enabled(False)
        self.live_view.set_image(None)
        self.live_view.set_recording(False)
        self.live_view.clear_review()
        self.shutter.set_recording(False)
        self._set_status("Connection reset. Ready to connect again.")
        self._refresh_connection_ui()

    # ---- session signal handlers (GUI thread) ----

    def _on_paired(self, ssid, password):
        self._set_status("Paired. Switching Wi-Fi to %s..." % ssid)

    def _on_wifi_switched(self):
        self._set_status("Wi-Fi switched. Starting remote control...")

    def _on_connected(self):
        self._connected = True
        self._set_controls_enabled(True)
        self._set_status("Connected")
        self._refresh_connection_ui()

    def _on_frame(self, image: QImage):
        self.live_view.set_image(image)
        if _PEAKING_AVAILABLE and self.peaking_btn.isChecked() and self._connected:
            self.live_view.set_peaking_overlay(self._compute_peaking(image))

    def _on_status(self, data: dict):
        battery = data.get("batteryLevel", "?")
        shots = data.get("SurplusPhotoCnts", "?")
        self._set_status("Connected", battery=battery, shots=shots)

    def _on_recording_state(self, is_recording: bool):
        self.live_view.set_recording(is_recording)
        self.shutter.set_recording(is_recording)
        if not is_recording:
            self.live_view.set_recording_clip_number(1)  # reset for the next recording session

    def _on_recording_clip_number(self, clip_number: int):
        """M6, 2026-07-12: > 1 once auto-restart has kicked in at least once for the current
        recording - shown in the live view's recording note (LiveViewWidget)."""
        self.live_view.set_recording_clip_number(clip_number)

    def _on_error(self, message: str):
        self._set_status("Error: %s" % message)
        if not self._connected:
            self._refresh_connection_ui()

    def _on_disconnected(self):
        self._connected = False
        self._set_controls_enabled(False)
        self.live_view.set_image(None)
        self.live_view.set_recording(False)
        self.live_view.clear_review()
        self.shutter.set_recording(False)
        self._set_status("Disconnected")
        self._refresh_connection_ui()

    def _on_connection_lost(self, reason: str):
        """The camera vanished on its own (powered off, out of Wi-Fi range) - M2, 2026-07-12,
        ported from the iOS app's camera-vanished detection. Deliberately a single combined
        handler rather than reusing `_on_error` + `_on_disconnected` back-to-back: those two
        firing in emission order would let `_on_disconnected`'s generic "Disconnected" status
        clobber the specific reason `_on_error` had just set."""
        self._connected = False
        self._set_controls_enabled(False)
        self.live_view.set_image(None)
        self.live_view.set_recording(False)
        self.live_view.clear_review()
        self.shutter.set_recording(False)
        self._set_status("Error: %s" % reason)
        self._refresh_connection_ui()

    # ---- shared UI state ----

    def _set_controls_enabled(self, on: bool):
        self.photo_mode_btn.setEnabled(on)
        self.video_mode_btn.setEnabled(on)
        self.shutter.setEnabled(on)
        self.crop_btn.setEnabled(on and self._mode == "photo")  # locked in video mode (2026-07-19)
        self.thirds_btn.setEnabled(on)
        self.diag_btn.setEnabled(on)
        self.peaking_btn.setEnabled(on and _PEAKING_AVAILABLE)
        self.files_btn.setEnabled(on)
        self.settings_container.setEnabled(on)
        if not on:
            self.live_view.set_peaking_overlay(None)

    def _refresh_connection_ui(self):
        """Enable exactly the connection menu actions that make sense for the current state."""
        self.act_connect.setEnabled(not self._connected)
        self.act_connect_direct.setEnabled(not self._connected)
        self.act_disconnect.setEnabled(self._connected)

    def _set_status(self, text, battery=None, shots=None):
        dot = theme.Color.OK if self._connected else theme.Color.TEXT_3
        parts = ['<span style="color:%s">&#9679;</span> %s' % (dot, text)]
        if battery is not None:
            parts.append("%s%%" % battery)
        if shots is not None:
            parts.append("%s shots" % shots)
        self.status_chip.setText("&nbsp;&middot;&nbsp;".join(parts))

    def closeEvent(self, event):
        # Ask every session (incl. orphans from _reset_connection) to stop, then a short grace
        # period. A thread stuck in a blocking bleak/asyncio call won't react to "quit" until it
        # hits its own timeout (up to 90s); we deliberately don't block app quit that long.
        for session in self._all_sessions:
            if session.isRunning():
                session.stop()
        for session in self._all_sessions:
            if session.isRunning():
                session.wait(1500)
        event.accept()
