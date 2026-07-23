#!/usr/bin/env python3
"""
YI M1 Monitor - a small desktop app for remote-monitoring and controlling the
YI M1 camera over BLE + Wi-Fi.

Run from Terminal.app (not through an automation sandbox) so macOS can grant
Bluetooth permission to the process:

    cd yi-m1-remote-control
    source venv/bin/activate
    python3 app/main.py
"""
import os
import sys

# When launched from Finder / a PyInstaller .app there is no terminal, so all the
# [session]/[BLE]/[liveview] diagnostics would vanish. Tee stdout+stderr to a log file in that
# case (detected via "stdout is not a tty") so field debugging still works; a Terminal run keeps
# its live console. Path: ~/Library/Logs/YiM1Monitor.log.
if not sys.stdout or not sys.stdout.isatty():
    try:
        _log_dir = os.path.expanduser("~/Library/Logs")
        os.makedirs(_log_dir, exist_ok=True)
        _log = open(os.path.join(_log_dir, "YiM1Monitor.log"), "a", buffering=1)
        _log.write("\n===== YI M1 Monitor launched (pid %d) =====\n" % os.getpid())
        sys.stdout = _log
        sys.stderr = _log
    except Exception:
        pass

# Force line-buffered stdout/stderr. print() only auto-line-buffers when stdout is a real
# tty in *some* launch conditions; under others (observed: no output at all appeared in
# Terminal.app while the app was stuck on BLE) it silently block-buffers, so log lines only
# show up on flush/exit instead of in real time. All the BLE/session log helpers also pass
# flush=True per-call as a second layer of defense, but this covers anything that doesn't.
try:
    sys.stdout.reconfigure(line_buffering=True)
    sys.stderr.reconfigure(line_buffering=True)
except Exception:
    pass

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from PySide6.QtWidgets import QApplication

import theme
from main_window import MainWindow


def main():
    print("[main] YI M1 Monitor starting. If you see this line but nothing else after "
          "clicking Connect, logging itself is working fine and the problem is elsewhere.",
          flush=True)
    # Name the app so the macOS menu bar / window titles read "YI M1 Monitor" instead of
    # "Python" (2026-07-20: the .app bundle execs the CLT-framework python, so AppKit would
    # otherwise attribute the process to Python.app). Set BEFORE the QApplication so Qt picks
    # it up for the macOS application menu.
    QApplication.setApplicationName("YI M1 Monitor")
    QApplication.setApplicationDisplayName("YI M1 Monitor")
    QApplication.setOrganizationName("YiM1Monitor")
    app = QApplication(sys.argv)
    app.setStyleSheet(theme.app_stylesheet())
    window = MainWindow()
    window.show()
    sys.exit(app.exec())


if __name__ == "__main__":
    main()
