# PyInstaller spec for "YI M1 Monitor.app" (2026-07-20).
#
# WHY PyInstaller (not the earlier hand-rolled venv-copy bundle): that bundle exec'd the
# Command-Line-Tools python framework, so the running process was attributed to Apple's
# Python.app - which has no Bluetooth usage string, so CoreBluetooth returned "BLE is not
# authorized" with no prompt, AND the menu bar said "Python". PyInstaller embeds its own python
# and makes THIS bundle the responsible process, so macOS reads our Info.plist (below) and
# actually prompts for Bluetooth / Local Network, and the app is branded correctly.
#
# Build:  ./venv/bin/python3 -m PyInstaller --noconfirm --distpath ~/Applications YiM1Monitor.spec
import os

REPO = os.path.abspath(os.getcwd())
APP_DIR = os.path.join(REPO, "app")

a = Analysis(
    [os.path.join("app", "main.py")],
    pathex=[REPO, APP_DIR],
    binaries=[],
    datas=[],
    # main.py's sys.path.insert lets it find these at runtime, but PyInstaller's static analysis
    # needs them named explicitly (they're imported as top-level packages, not app.*).
    hiddenimports=[
        "theme", "icons", "main_window", "camera_session",
        "prot_ble", "prot_ble.ble_keyhack",
        "prot_http", "prot_http.command_http", "prot_http.const_wifi",
        "prot_http.const_http_enum_extra", "prot_http.const_http_cmd_rc_params",
        "numpy",
    ],
    hookspath=[],
    runtime_hooks=[],
    # cv2 is deliberately EXCLUDED (2026-07-20): it can't be imported from a frozen app
    # ("recursion is detected during loading of cv2 binary extensions") and the only thing the
    # app used it for - focus-peaking edge detection - is now a numpy Sobel. Keeping it out
    # also drops ~100MB from the bundle. The research/probe scripts still use cv2 from the venv.
    excludes=["tkinter", "PyInstaller", "cv2"],
    noarchive=False,
)
pyz = PYZ(a.pure)

exe = EXE(
    pyz, a.scripts, [],
    exclude_binaries=True,
    name="YI M1 Monitor",
    console=False,          # windowed GUI app
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
    icon=os.path.join("macos_app_template", "AppIcon.icns"),
)
coll = COLLECT(
    exe, a.binaries, a.datas,
    name="YI M1 Monitor",
)
app = BUNDLE(
    coll,
    name="YI M1 Monitor.app",
    icon=os.path.join("macos_app_template", "AppIcon.icns"),
    bundle_identifier="com.yim1monitor.mac",
    info_plist={
        "CFBundleName": "YI M1 Monitor",
        "CFBundleDisplayName": "YI M1 Monitor",
        "CFBundleShortVersionString": "1.0",
        "CFBundleVersion": "1.0",
        "LSMinimumSystemVersion": "12.0",
        "NSHighResolutionCapable": True,
        "NSBluetoothAlwaysUsageDescription":
            "YI M1 Monitor uses Bluetooth to pair with your camera and read its Wi-Fi credentials.",
        "NSLocalNetworkUsageDescription":
            "YI M1 Monitor connects to your camera over its own Wi-Fi network to show live view and send camera commands.",
        "NSLocationUsageDescription":
            "Location access lets macOS report the current Wi-Fi network name, so the app can restore your previous network after disconnecting from the camera.",
    },
)
