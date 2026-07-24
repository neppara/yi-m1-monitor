#!/usr/bin/env python3
"""
Снятие состояния камеры «до / после» для проверки сервисных режимов `.SDK`.

Как это работает и почему безопасно
-----------------------------------
В прошивке найдены 10 имён файлов-триггеров сервисных режимов. Механизм: камера при
старте ищет файл с таким именем в корне SD-карты и, найдя, включает режим.

**Мы ничего не записываем В КАМЕРУ.** Файл кладётся на карту, камера его только читает.
Откат — удалить файл. Этот скрипт вообще не пишет на карту: он только СНИМАЕТ состояние,
а файл ты создаёшь сам (командой, которую скрипт напечатает).

Порядок работы
--------------
    # 1) базовый снимок, без всяких файлов на карте
    ./venv/bin/python3 probe_service_mode.py --label baseline

    # 2) кладёшь файл на карту, ВЫКЛЮЧАЕШЬ и ВКЛЮЧАЕШЬ камеру, потом:
    ./venv/bin/python3 probe_service_mode.py --label nosleep

Второй прогон сам сравнит себя с базовым и покажет, что изменилось.

Что снимается
-------------
* все поля метаданных live view (их 26 у обычной камеры — новые сразу видно);
* полный ответ GetCameraStatus;
* ПОЛНЫЙ список файлов на карте — если режим создаст лог, он появится в диффе;
* время до засыпания камеры (для проверки NOSLEEP), если запросить --sleep-test.

ВАЖНО ПРО РИСК
--------------
Скрипт не решает за тебя, какой режим включать. Часть имён (`AUDIOADJ`, `IMAGER`,
`NODIST`, `NONAIL`) содержит признаки калибровки, а в камере есть области заводской
калибровки `.camadj`/`.camdef`, которые нечем восстановить. Пока агент не подтвердит,
что режим ничего не записывает, — не трогай его.
"""

import json
import os
import subprocess
import sys
import time
from datetime import datetime

from urllib3 import PoolManager

from probe_connect import connect_to_camera, restore_wifi

CAMERA = "192.168.0.10"
UDP_PORT = 54321

# Имена триггеров из прошивки (0x53117f..0x5311eb). Порядок — как в таблице 0xc09b4b24.
SDK_FILES = [
    ("NOSLEEP.SDK",  "не засыпать",                    "похоже на безопасный"),
    ("SLEEP1.SDK",   "режим сна (агрессивный?)",       "похоже на безопасный"),
    ("IMAGER.SDK",   "сенсор",                         "ОСТОРОЖНО — может калибровать"),
    ("BATLIFE.SDK",  "батарея",                        "похоже на безопасный"),
    ("NONAIL.SDK",   "миниатюры (nail = thumbnail?)",  "ОСТОРОЖНО"),
    ("NODIST.SDK",   "коррекция дисторсии",            "ОСТОРОЖНО"),
    ("AUDIOADJ.SDK", "подстройка аудио (ADJ!)",        "ОПАСНО — ADJ = adjustment"),
    ("WIFIDUMP.SDK", "диагностика Wi-Fi",              "похоже на безопасный"),
    ("SHORTPIC.SDK", "укороченные лимиты фото",        "похоже на безопасный"),
    ("SHORTMOV.SDK", "укороченные лимиты видео",       "похоже на безопасный"),
]

RESULTS_ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                            "fable research", "wifi-experiment-results")

label = "run"
for i, a in enumerate(sys.argv):
    if a == "--label" and i + 1 < len(sys.argv):
        label = sys.argv[i + 1]
SLEEP_TEST = "--sleep-test" in sys.argv

OUT_DIR = os.path.join(RESULTS_ROOT, "run_%s_service_%s"
                       % (datetime.now().strftime("%Y%m%d_%H%M%S"), label))
os.makedirs(OUT_DIR, exist_ok=True)
LOG = os.path.join(OUT_DIR, "log.txt")
_lines = []


def log(msg=""):
    print(msg, flush=True)
    _lines.append(str(msg))
    with open(LOG, "w", encoding="utf-8") as fh:
        fh.write("\n".join(_lines) + "\n")


http = PoolManager()


def send(cmd, timeout=8.0):
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


# ---------------------------------------------------------------- сбор состояния
import re
import socket
import threading

_meta = {}
_udp_on = True


def udp_listener():
    """Пересборка кадров по индексам пакетов (портировано из app/camera_session.py).
    Метаданные лежат в первых 2048 байтах СОБРАННОГО кадра, а не в отдельных датаграммах."""
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
                if len(data) <= 2048:
                    continue
                for k, v in re.findall(rb'"([A-Za-z0-9_]+)"\s*:\s*"([^"]*)"', data[:2048]):
                    _meta[k.decode()] = v.decode("ascii", "replace")
    except Exception as exc:
        log("  (UDP-слушатель не поднялся: %r)" % (exc,))


def file_list():
    """ВАЖНО: параметры называются range_start/range_end (строками), НЕ id_start/id_end."""
    status, body = send({"command": "GetFileList", "range_start": "0",
                         "range_end": "9999", "filetype": "all"})
    if not is_ok(status, body):
        return []
    try:
        data = json.loads(body).get("data", [])
    except Exception:
        return []
    return [e for e in data if isinstance(e, dict)] if isinstance(data, list) else []


def snapshot():
    log("Жду поток live view...")
    deadline = time.time() + 12
    while time.time() < deadline and len(_meta) < 5:
        time.sleep(0.5)

    status, body = send({"command": "GetCameraStatus"})
    try:
        cam = json.loads(body).get("data", {})
    except Exception:
        cam = {}

    files = file_list()
    snap = {
        "label": label,
        "time": datetime.now().isoformat(timespec="seconds"),
        "metadata": dict(_meta),
        "camera_status": cam,
        "files": sorted(str(e.get("path", "")) for e in files),
    }
    with open(os.path.join(OUT_DIR, "snapshot.json"), "w", encoding="utf-8") as fh:
        json.dump(snap, fh, indent=2, ensure_ascii=False, sort_keys=True)
    return snap


def show(snap):
    log("")
    log("=" * 72)
    log("СНИМОК СОСТОЯНИЯ  (метка: %s)" % label)
    log("=" * 72)
    log("Поля метаданных (%d):" % len(snap["metadata"]))
    for k in sorted(snap["metadata"]):
        log("    %-22s = %r" % (k, snap["metadata"][k]))
    log("")
    log("GetCameraStatus:")
    for k in sorted(snap["camera_status"]):
        log("    %-22s = %r" % (k, snap["camera_status"][k]))
    log("")
    log("Файлов на карте: %d" % len(snap["files"]))


def compare(snap):
    """Сравниваем с прогоном, у которого ДРУГАЯ метка — иначе сравнение бессмысленно.

    (В прошлой версии этой логики бралcя просто последний по времени каталог, из-за
    чего прогон сравнивался сам с собой. Здесь метка проверяется явно.)
    """
    import glob
    others = []
    for path in sorted(glob.glob(os.path.join(RESULTS_ROOT, "run_*_service_*", "snapshot.json"))):
        if os.path.dirname(path) == OUT_DIR:
            continue
        try:
            with open(path, encoding="utf-8") as fh:
                prev = json.load(fh)
        except Exception:
            continue
        if prev.get("label") != snap["label"]:
            others.append((path, prev))
    if not others:
        log("")
        log("Сравнивать не с чем — это первый прогон с такой меткой.")
        log("Сделай базовый прогон (--label baseline) без файлов на карте, если ещё не делал.")
        return
    path, prev = others[-1]
    log("")
    log("=" * 72)
    log("ОТЛИЧИЯ от прогона %r (%s)" % (prev.get("label"), os.path.basename(os.path.dirname(path))))
    log("=" * 72)

    changed = False
    for k in sorted(set(prev["metadata"]) | set(snap["metadata"])):
        a, b = prev["metadata"].get(k), snap["metadata"].get(k)
        if a != b:
            changed = True
            log("  метаданные %-20s  %r -> %r" % (k, a, b))
    for k in sorted(set(prev["camera_status"]) | set(snap["camera_status"])):
        a, b = prev["camera_status"].get(k), snap["camera_status"].get(k)
        if a != b:
            changed = True
            log("  статус     %-20s  %r -> %r" % (k, a, b))

    new = [f for f in snap["files"] if f not in prev["files"]]
    gone = [f for f in prev["files"] if f not in snap["files"]]
    if new:
        changed = True
        log("")
        log("  НОВЫЕ ФАЙЛЫ НА КАРТЕ (%d) — вот здесь и ищи лог режима:" % len(new))
        for f in new:
            log("      + %s" % f)
    if gone:
        changed = True
        for f in gone:
            log("      - %s" % f)

    if not changed:
        log("  Ничего не изменилось.")
        log("")
        log("  Учти: часть эффектов по HTTP не видна в принципе — например, надписи")
        log("  на экране камеры или пункты сервисного меню. Отсутствие отличий здесь")
        log("  НЕ значит, что режим не включился.")


def print_howto():
    log("")
    log("=" * 72)
    log("КАК ПРОВЕРИТЬ РЕЖИМ")
    log("=" * 72)
    log("Файл кладётся на КАРТУ, в камеру ничего не пишется. Откат — удалить файл.")
    log("")
    log("  1. Вставь карту в Mac")
    log("  2. Создай пустой файл-триггер в корне карты, например:")
    log("       touch /Volumes/<КАРТА>/NOSLEEP.SDK")
    log("  3. Вставь карту в камеру, ВЫКЛЮЧИ и ВКЛЮЧИ её (проверка идёт при старте)")
    log("  4. Запусти:  ./venv/bin/python3 probe_service_mode.py --label nosleep")
    log("")
    log("Список триггеров из прошивки:")
    for name, what, risk in SDK_FILES:
        log("  %-14s %-32s %s" % (name, what, risk))
    log("")
    log("НЕ ТРОГАЙ помеченные ОСТОРОЖНО/ОПАСНО, пока не разобран их код:")
    log("в камере есть области заводской калибровки (.camadj/.camdef), и если режим")
    log("их перезапишет, восстановить будет нечем.")


def main():
    global _udp_on
    log("время: %s   метка: %s" % (datetime.now().isoformat(timespec="seconds"), label))

    if not connect_to_camera(log):
        print_howto()
        return

    threading.Thread(target=udp_listener, daemon=True).start()
    try:
        if not is_ok(*send({"command": "RCStartRemoteCtl"})):
            log("Сессия не открылась — камера занята другим клиентом?")
            return
        snap = snapshot()
        show(snap)
        compare(snap)

        if SLEEP_TEST:
            # ВАЖНО: сессию удалённого управления ЗАКРЫВАЕМ перед тестом.
            # Активная RC-сессия почти наверняка сама удерживает камеру от засыпания -
            # с ней тест показал бы "не спит" и с файлом, и без него, то есть был бы
            # бессмысленным. Опрашиваем редко (30 с) и максимально лёгкой командой.
            send({"command": "RCStopRemoteCtl"})
            log("")
            log("=" * 72)
            log("ТЕСТ ЗАСЫПАНИЯ (метка: %s)" % label)
            log("=" * 72)
            log("RC-сессия закрыта, чтобы не удерживать камеру искусственно.")
            log("Опрос раз в 30 секунд, до 20 минут. НЕ ТРОГАЙ камеру руками.")
            log("")
            start = time.time()
            slept_at = None
            while time.time() - start < 1200:
                time.sleep(30)
                elapsed = time.time() - start
                alive = is_ok(*send({"command": "GetCameraStatus"}, timeout=5.0))
                log("  %4.0f сек (%.1f мин): %s" % (elapsed, elapsed / 60.0,
                                                    "отвечает" if alive else "НЕ ОТВЕЧАЕТ"))
                if not alive:
                    # одна ложная неудача бывает от помех - подтверждаем вторым запросом
                    time.sleep(5)
                    if not is_ok(*send({"command": "GetCameraStatus"}, timeout=5.0)):
                        slept_at = elapsed
                        break
                    log("       (первый запрос не прошёл, второй прошёл - помеха, продолжаю)")
            log("")
            if slept_at is None:
                log("  РЕЗУЛЬТАТ: 20 минут, камера НЕ уснула.")
            else:
                log("  РЕЗУЛЬТАТ: камера перестала отвечать через %.0f сек (%.1f мин)."
                    % (slept_at, slept_at / 60.0))
            log("")
            log("  Это число и нужно сравнивать между прогонами. Одиночный замер")
            log("  ничего не значит - нужен и базовый, БЕЗ файла на карте.")
    finally:
        send({"command": "RCStopRemoteCtl"})
        _udp_on = False
        time.sleep(0.3)
        restore_wifi(log)
        print_howto()
        log("")
        log("Снимок: %s" % OUT_DIR)


if __name__ == "__main__":
    main()
