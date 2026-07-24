#!/usr/bin/env python3
"""Общее автоподключение к камере для всех probe-скриптов.

Раньше каждый скрипт требовал ручной возни: запусти probe_resolution_key.py ради
BLE-пейринга, руками переключи Wi-Fi, нажми Enter. Здесь то же самое делается само -
логика взята из рабочего app/camera_session.py, а не написана заново.

Использование:

    from probe_connect import connect_to_camera, restore_wifi

    if not connect_to_camera(log):
        return
    try:
        ...твои команды...
    finally:
        restore_wifi(log)

ЧТО ВАЖНО ЗНАТЬ ПРО ЭТОТ КОД (грабли, на которых уже стояли):

* Пароль камеры МЕНЯЕТСЯ на каждый пейринг, SSID при этом один и тот же. Если у macOS
  сохранён старый пароль для этого SSID, она будет молча долбиться им вместо нового.
  Поэтому перед подключением сеть надо «забыть».

* `networksetup -setairportnetwork` возвращает 0, даже когда подключение ещё не
  состоялось: код возврата означает лишь «запрос принят».

* Спрашивать у системы «на той ли мы сети?» БЕСПОЛЕЗНО. Живое тестирование показало:
  `networksetup -getairportnetwork` 35+ секунд подряд отвечал «You are not associated
  with an AirPort network», пока меню Wi-Fi ясно показывало подключение к камере. Это
  известная особенность macOS - запрос текущего SSID может требовать Location Services,
  и без него инструменты врут, а не сообщают об ошибке.

  Поэтому проверяем не SSID, а РЕАЛЬНУЮ достижимость камеры: опрашиваем GetCameraStatus.
  Это ровно то, что нам нужно на самом деле, и не требует никаких разрешений.

* BLE и Wi-Fi делят одну антенну 2.4 ГГц. Выключить Bluetooth программно на macOS
  нельзя, поэтому скрипт лишь напоминает об этом.
"""

import json
import subprocess
import time

from urllib3 import PoolManager

CAMERA_IP = "192.168.0.10"
_http = PoolManager()

_state = {"device": None, "previous_ssid": None}


# --------------------------------------------------------------------------- Wi-Fi
def _wifi_device():
    """Имя сетевого устройства Wi-Fi (en0/en1) - на разных Mac отличается."""
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


def _current_ssid():
    """Текущая сеть - через system_profiler: он, в отличие от networksetup, не требует
    Location Services (проверено живьём на этом Mac)."""
    try:
        out = subprocess.check_output(
            ["system_profiler", "SPAirPortDataType", "-json"], text=True, timeout=15)
        data = json.loads(out)
    except Exception:
        return None

    def walk(node):
        if isinstance(node, dict):
            for k, v in node.items():
                if k == "spairport_current_network_information" and isinstance(v, dict):
                    name = v.get("_name")
                    if name:
                        return name
                got = walk(v)
                if got:
                    return got
        elif isinstance(node, list):
            for item in node:
                got = walk(item)
                if got:
                    return got
        return None

    return walk(data)


def camera_reachable(timeout=3.0):
    try:
        url = "http://%s/?data=%s" % (
            CAMERA_IP, json.dumps({"command": "GetCameraStatus"}, separators=(",", ":")))
        r = _http.request("GET", url, timeout=timeout)
        return r.status == 200
    except Exception:
        return False


# --------------------------------------------------------------------------- главное
def connect_to_camera(log, skip_if_reachable=True, join_timeout=45.0, ble_attempts=5):
    """Полный цикл: проверка → BLE-пейринг → присоединение к Wi-Fi → ожидание камеры.

    Возвращает True, если камера отвечает.
    """
    if skip_if_reachable and camera_reachable():
        log("Камера уже доступна — подключение не требуется.")
        return True

    _state["device"] = _wifi_device()
    if not _state["device"]:
        log("Не удалось определить Wi-Fi-устройство этого Mac.")
        return False
    log("Wi-Fi устройство: %s" % _state["device"])

    _state["previous_ssid"] = _current_ssid()
    log("Текущая сеть (для восстановления в конце): %r" % _state["previous_ssid"])

    log("")
    log("=== BLE-пейринг ===")
    log("*** СЕЙЧАС МОЖЕТ ПОЯВИТЬСЯ ЗАПРОС НА ЭКРАНЕ КАМЕРЫ — НАЖМИ ACCEPT ***")

    # Камера рекламируется по BLE С ПЕРЕБОЯМИ - это наблюдалось многократно: из трёх
    # подряд сканов два не видят её вовсе ("No device advertised the YI M1 service UUID"),
    # третий находит. Раньше это лечилось тем, что человек вручную перезапускал скрипт,
    # пока не повезёт. Теперь повторяем сами.
    result = None
    for attempt in range(1, ble_attempts + 1):
        if attempt > 1:
            log("")
            log("--- попытка %d из %d ---" % (attempt, ble_attempts))
            log("Пока идёт скан: потрогай камеру (нажми кнопку, крутани колесо),")
            log("чтобы она не ушла в сон и продолжала рекламироваться.")
        try:
            from prot_ble import trigger_remote_control_closest
            result = trigger_remote_control_closest()
        except Exception as exc:
            log("BLE-пейринг упал с исключением: %r" % (exc,))
            result = None
        if result is not None:
            break
        if attempt < ble_attempts:
            time.sleep(3.0)

    if result is None:
        log("")
        log("Камера так и не найдена по BLE за %d попыток. Что проверить:" % ble_attempts)
        log("  1. Камера включена и НЕ спит (экран активен).")
        log("  2. Камера принимает ОДНОГО BLE-клиента — закрой официальное приложение")
        log("     на телефоне и наш iOS-монитор, если он подключён.")
        log("  3. Если недавно была Wi-Fi-сессия, камера могла не свернуть точку доступа:")
        log("     ВЫКЛЮЧИ И ВКЛЮЧИ КАМЕРУ — это лечит чаще всего.")
        log("  4. Bluetooth на Mac включён (проверь в меню).")
        return False

    ssid, password = result
    log("SSID: %s" % ssid)

    # Пароль каждый раз новый, а SSID тот же — сохранённый старый пароль всё сломает.
    subprocess.run(["networksetup", "-removepreferredwirelessnetwork",
                    _state["device"], ssid], capture_output=True, text=True)
    time.sleep(0.5)

    log("Подключаюсь к сети камеры (интернет пропадёт — это нормально)...")
    subprocess.run(["networksetup", "-setairportnetwork",
                    _state["device"], ssid, password], capture_output=True, text=True)

    # Код возврата ничего не значит — ждём РЕАЛЬНОГО ответа камеры.
    deadline = time.time() + join_timeout
    while time.time() < deadline:
        if camera_reachable():
            log("Камера отвечает. Подключение установлено.")
            log("(Bluetooth лучше выключить вручную — общая антенна 2.4 ГГц мешает Wi-Fi.)")
            return True
        time.sleep(1.5)

    log("Камера не ответила за %.0f секунд." % join_timeout)
    log("Проверь вручную, подключился ли Mac к сети %s." % ssid)
    return False


def restore_wifi(log):
    """Вернуть прежнюю сеть, чтобы не остаться без интернета."""
    prev = _state.get("previous_ssid")
    dev = _state.get("device")
    if not prev or not dev:
        log("Прежняя сеть неизвестна — переключи Wi-Fi обратно вручную.")
        return
    log("Возвращаю сеть %r..." % prev)
    subprocess.run(["networksetup", "-setairportnetwork", dev, prev],
                   capture_output=True, text=True)
    for _ in range(10):
        time.sleep(1.5)
        if _current_ssid() == prev:
            log("Интернет восстановлен (%s)." % prev)
            return
    log("Автовозврат не подтвердился — проверь Wi-Fi вручную.")
