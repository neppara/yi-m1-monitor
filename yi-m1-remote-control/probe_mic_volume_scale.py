#!/usr/bin/env python3
"""
Определяет РЕАЛЬНУЮ шкалу громкости микрофона (RCVAVolSet / метаданное VAVol).

Зачем: в приложениях сейчас стоят значения 0/25/50/75/100 — они ВЫДУМАНЫ. Подтверждено
живьём было только "50" (камера отразила VAVol=50), а собственные значения камеры,
которые мы наблюдали в метаданных, — это 2 и 4. То есть шкала, похоже, уровневая
(0..6? 0..10?), а не процентная. Обработчик RCVAVolSet (0x00156588) диапазон не
проверяет — принимает любое число, поэтому "приняла" ничего не доказывает.

Метод: отправляем значение и смотрим, что камера ВЕРНЁТ в поле VAVol метаданных.
Если камера нормализует/обрежет значение — это и есть настоящая граница.

БЕЗОПАСНОСТЬ: меняется только громкость микрофона. В конце восстанавливается исходное
значение. Ничего не прошивается, файлы не трогаются.

Запуск:
    ./venv/bin/python3 probe_mic_volume_scale.py
"""

import json
import os
import re
import socket
import threading
import time
from datetime import datetime

from urllib3 import PoolManager

from probe_connect import connect_to_camera, restore_wifi

CAMERA = "192.168.0.10"
UDP_PORT = 54321

OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       "fable research", "wifi-experiment-results",
                       "run_%s_mic_volume" % datetime.now().strftime("%Y%m%d_%H%M%S"))
os.makedirs(OUT_DIR, exist_ok=True)
LOG = os.path.join(OUT_DIR, "log.txt")
_lines = []


def log(msg=""):
    print(msg, flush=True)
    _lines.append(str(msg))
    with open(LOG, "w", encoding="utf-8") as fh:
        fh.write("\n".join(_lines) + "\n")


http = PoolManager()


def send(cmd, timeout=6.0):
    url = "http://%s/?data=%s" % (CAMERA, json.dumps(cmd, separators=(",", ":")))
    try:
        r = http.request("GET", url, timeout=timeout)
        return r.status, r.data.decode("utf-8", errors="replace")
    except Exception as exc:
        return None, repr(exc)


def is_ok(status, body):
    """Успех = HTTP 200 И code == 200 (НЕ 0). Логика из app/camera_session.py."""
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


_meta = {}
_udp_on = True


def udp_listener():
    """Пересборка кадров по индексам пакетов (как в app/camera_session.py)."""
    pending = []
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sk:
            sk.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            sk.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1024 * 1024)
            sk.bind(("", UDP_PORT))
            sk.settimeout(1.0)
            while _udp_on:
                try:
                    pack, _ = sk.recvfrom(1024000)
                except (socket.timeout, OSError):
                    continue
                if len(pack) < 12:
                    continue
                fi = int.from_bytes(pack[:4], "big")
                total = int.from_bytes(pack[4:8], "big")
                pi = int.from_bytes(pack[8:12], "big")
                if total <= 0 or total > 4096:
                    continue
                fr = next((f for f in pending if f["idx"] == fi), None)
                if fr is None:
                    fr = {"idx": fi, "total": total, "pieces": [None] * total, "got": 0}
                    pending.append(fr)
                    if len(pending) > 3:
                        pending.pop(0)
                if 0 <= pi < fr["total"] and fr["pieces"][pi] is None:
                    fr["pieces"][pi] = pack[12:]
                    fr["got"] += 1
                done = next((f for f in pending if f["got"] == f["total"]), None)
                if done is None:
                    continue
                pending.remove(done)
                data = b"".join(done["pieces"])
                if len(data) > 2048:
                    for k, v in re.findall(rb'"([A-Za-z0-9_]+)"\s*:\s*"([^"]*)"', data[:2048]):
                        _meta[k.decode()] = v.decode("ascii", "replace")
    except Exception as exc:
        log("  (UDP-слушатель не поднялся: %r)" % (exc,))


def read_vol(wait=3.0):
    """Ждём, пока метаданные обновятся, и возвращаем то, что камера реально показывает."""
    deadline = time.time() + wait
    seen = _meta.get("VAVol")
    while time.time() < deadline:
        time.sleep(0.3)
        cur = _meta.get("VAVol")
        if cur != seen:
            return cur
    return _meta.get("VAVol")


def main():
    global _udp_on
    log("время: %s" % datetime.now().isoformat(timespec="seconds"))
    log("")
    if not connect_to_camera(log):
        return

    threading.Thread(target=udp_listener, daemon=True).start()
    try:
        if not is_ok(*send({"command": "RCStartRemoteCtl"})):
            log("Сессия не открылась — камера занята другим клиентом?")
            return

        log("Жду метаданные...")
        deadline = time.time() + 12
        while time.time() < deadline and "VAVol" not in _meta:
            time.sleep(0.4)
        original = _meta.get("VAVol")
        log("ИСХОДНОЕ значение VAVol: %r" % original)
        log("")
        log("=" * 66)
        log("ПЕРЕБОР: что камера РЕАЛЬНО показывает после каждого значения")
        log("=" * 66)
        log("Смотри колонку 'камера показывает' — если она перестаёт расти,")
        log("значит найден потолок шкалы.")
        log("")
        log("  %-10s %-8s %s" % ("отправлено", "ответ", "камера показывает"))

        results = {}
        # мелкий шаг в начале (гипотеза: шкала уровней), потом крупные значения-зонды
        probe = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "10",
                 "11", "15", "20", "25", "50", "75", "100"]
        for val in probe:
            ok = is_ok(*send({"command": "RCVAVolSet", "Vol": val}))
            shown = read_vol()
            results[val] = shown
            mark = "" if shown == val else "   <-- НЕ совпало с отправленным"
            log("  %-10s %-8s %s%s" % (val, "OK" if ok else "FAIL", shown, mark))
            time.sleep(0.4)

        log("")
        log("=" * 66)
        log("ВЫВОД")
        log("=" * 66)
        echoed = [v for v, shown in results.items() if shown == v]
        if echoed:
            nums = [int(v) for v in echoed]
            log("  Камера подтвердила значения: %s" % ", ".join(echoed))
            log("  Диапазон: %d .. %d" % (min(nums), max(nums)))
        else:
            log("  Камера не подтвердила НИ ОДНО значение - шкала работает иначе,")
            log("  либо метаданные не отражают эту настройку сразу.")
        rejected = [v for v, shown in results.items() if shown != v]
        if rejected:
            log("  Не подтверждены: %s" % ", ".join(rejected))
        log("")
        log("  Это и есть реальная шкала. Значения 0/25/50/75/100 в приложениях")
        log("  были ПРЕДПОЛОЖЕНИЕМ - заменим на то, что показал этот прогон.")

    finally:
        if 'original' in dir() and original:
            log("")
            log("Возвращаю исходную громкость %r..." % original)
            send({"command": "RCVAVolSet", "Vol": original})
        send({"command": "RCStopRemoteCtl"})
        _udp_on = False
        time.sleep(0.3)
        restore_wifi(log)
        log("")
        log("Лог: %s" % LOG)


if __name__ == "__main__":
    main()
