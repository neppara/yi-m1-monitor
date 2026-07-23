# macOS app bundle ("YI M1 Monitor.app")

A double-clickable macOS app so the Mac monitor no longer needs Terminal
(`source venv/bin/activate; python3 app/main.py`).

## Where it is

`~/Applications/YI M1 Monitor.app` — double-click to launch. Logs (the `[session]`/`[BLE]`/
`[liveview]` output that used to go to the terminal) are written to
`~/Library/Logs/YiM1Monitor.log` — `tail -f` it when debugging.

## Rebuild after changing any Python source

The bundle is a **snapshot** — editing the repo does NOT change the installed app. Rebuild from
the repo root (~20 s, ~220 MB output):

```
./venv/bin/python3 -m PyInstaller --noconfirm --distpath ~/Applications YiM1Monitor.spec
```

Everything (Info.plist keys, icon, hidden imports) is declared in `YiM1Monitor.spec`.

## Why PyInstaller (a thin wrapper does NOT work)

Two earlier attempts failed, both for the same underlying reason — **the app must be the
process macOS attributes permissions to**:

1. A shell-script wrapper running the in-repo venv: Finder-launched apps get no `~/Documents`
   access (TCC), so it died with `PermissionError` on `venv/pyvenv.cfg`, and no prompt ever
   appeared.
2. A self-contained bundle that copied the venv inside but still `exec`'d the Command-Line-Tools
   python: the running process was Apple's `Python.app`, which has no Bluetooth usage string —
   so CoreBluetooth returned **"BLE is not authorized"** with no prompt, and the menu bar read
   "Python".

PyInstaller embeds its own interpreter, so **this** bundle is the responsible process: macOS
reads our `Info.plist`, grants Bluetooth/Local Network to `com.yim1monitor.mac`, and the app is
branded correctly everywhere (verified: BLE now scans, finds `YI_M1_*`, and reaches the camera's
Accept prompt).

## CoreBluetooth warm-up retry (why the first connect used to fail)

`bleak` waits only **1 second** for CoreBluetooth to report its state, then raises
`"Bluetooth device is turned off"` — even when the adapter is on. On the first connect after a
cold app launch the stack isn't warm yet, so this fired every time and Bluetooth appeared dead.
`prot_ble/ble_keyhack.py` now retries scanner creation up to 5 times, 1 s apart (a real
`"not authorized"` error is re-raised immediately, since retrying can't help there). In
practice attempt 3 succeeds. Do not remove this retry.
