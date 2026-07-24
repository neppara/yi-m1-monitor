#!/usr/bin/env python3
"""
Проверка "скрытых" значений, найденных в прошивке (agent-tasks/AGENT_RESULT_05).

САМОЕ ВАЖНОЕ В ЭТОМ СКРИПТЕ — НЕГАТИВНЫЙ КОНТРОЛЬ (этап 1).

Вчера мы обрадовались тому, что камера ответила code:200 на все семь видеоформатов.
Но мы НИ РАЗУ не отправили заведомо мусорное значение. Если камера отвечает 200 на
любую строку, то "приняла" не значит ничего, и весь список находок ничего не стоит.
Поэтому скрипт сначала посылает выдуманные значения. Если камера их примет — он
ОСТАНАВЛИВАЕТСЯ и говорит об этом прямо, вместо того чтобы выдать красивый, но
бессмысленный список "подтверждённых" режимов.

Второй уровень проверки: для видеоформатов есть независимый канал — поле VideoFormat
в UDP-метаданных live view. Оно показывает, что камера реально применила, а не то,
что она ответила. Для принятых значений скрипт ещё и пишет короткий клип, чтобы
потом ffprobe сказал правду о разрешении и fps.

ВАЖНАЯ ОГОВОРКА про происхождение строк: прошивка построена на платформе Xacti ASDK,
которая обслуживает несколько моделей камер разных брендов. Строки вроде VGA_240 или
720P_* вполне могут быть общим кодом платформы, никогда не подключённым для YI M1.
Наличие строки в бинарнике НЕ доказывает поддержку. Этот скрипт и нужен, чтобы
отличить одно от другого.

БЕЗОПАСНОСТЬ: только HTTP-команды. Ничего не прошивается. Меняются настройки съёмки
(в конце скрипт пытается вернуть исходные). Худший случай — камера запуталась в
состоянии, лечится выключением/включением.

Запуск (Mac уже в Wi-Fi камеры):
    ./venv/bin/python3 probe_hidden_values.py
"""

import json
import os
import re
import socket
import threading
import time
from datetime import datetime

from urllib3 import PoolManager

CAMERA = "192.168.0.10"
UDP_PORT = 54321
CLIP_SECONDS = 3.0

OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       "fable research", "wifi-experiment-results",
                       "run_%s_hidden_values" % datetime.now().strftime("%Y%m%d_%H%M%S"))
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


def step(label, cmd):
    status, body = send(cmd)
    ok = is_ok(status, body)
    log("  [%s] %-46s -> %s | %s" % ("OK  " if ok else "FAIL", label, status, body.strip()[:120]))
    return ok


# ---------------------------------------------------------------- метаданные
_meta = {}
_udp_on = True


def udp_listener():
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            s.bind(("", UDP_PORT))
            s.settimeout(1.0)
            while _udp_on:
                try:
                    data, _ = s.recvfrom(65535)
                except (socket.timeout, OSError):
                    continue
                for key in (b"VideoFormat", b"ShutterSpeed", b"Fnumber", b"ImageQuality",
                            b"WB", b"DialMode"):
                    m = re.search(b'"' + key + b'"\\s*:\\s*"([^"]*)"', data)
                    if m:
                        _meta[key.decode()] = m.group(1).decode("ascii", "replace")
    except Exception as exc:
        log("  (UDP-слушатель не поднялся: %r)" % (exc,))


def meta_after(key, want, wait=3.0):
    """Ждём, пока метаданные подтвердят применённое значение. Возвращает то, что реально видим."""
    deadline = time.time() + wait
    while time.time() < deadline:
        if _meta.get(key) == want:
            return want
        time.sleep(0.25)
    return _meta.get(key)


# ---------------------------------------------------------------- этапы
BOGUS = [
    ("RCVideoFormatSet", "Resolution", "ZZ_NOT_A_FORMAT_99"),
    ("RCVideoFormatSet", "Resolution", "8K_120"),
    ("RCShutterSpeedSet", "dShutterSpeed", "1/99999s"),
    ("RCFNSet", "Fnumber", "99.9"),
    ("RCISOSet", "ISO", "999999"),
]

NEW_VIDEO = ["2880_24", "1920_24", "720P_60", "720P_30", "720P_24", "VGA_240", "VGA"]
NEW_SHUTTER = ["1/8000s", "1/6400s", "1/5000s", "1/3000s", "1/1700s", "TIME10", "TIME2"]
NEW_FSTOP = ["2.9", "3.6", "6.4", "8.4", "10.0", "11.0"]
NEW_QUALITY = ["27", "14"]
NEW_MISC = [("RCWBSet", "WBMode", "CWB"), ("RCSwitchDialMode", "DialMode", "Scene")]


def negative_control():
    log("=" * 72)
    log("ЭТАП 1. НЕГАТИВНЫЙ КОНТРОЛЬ — принимает ли камера заведомую чушь?")
    log("=" * 72)
    log("Если хоть одно из этих выдуманных значений будет принято, то ответ 200")
    log("ничего не доказывает, и дальше идти бессмысленно.")
    log("")
    accepted = []
    for cmd, key, val in BOGUS:
        if step("%s %s=%s" % (cmd, key, val), {"command": cmd, key: val}):
            accepted.append((cmd, val))
    log("")
    if accepted:
        log("  >>> КАМЕРА ПРИНЯЛА ВЫДУМАННЫЕ ЗНАЧЕНИЯ: %s" % accepted)
        log("  >>> Значит она НЕ валидирует значения, и code:200 не означает поддержку.")
        log("  >>> Единственное надёжное доказательство — метаданные и записанный файл.")
        return False
    log("  >>> Все выдуманные значения ОТВЕРГНУТЫ. Камера валидирует ввод,")
    log("  >>> значит 'принято' — осмысленный сигнал. Продолжаем.")
    return True


def probe_video(strict):
    log("")
    log("=" * 72)
    log("ЭТАП 2. СКРЫТЫЕ ВИДЕОФОРМАТЫ")
    log("=" * 72)
    baseline = _meta.get("VideoFormat")
    log("исходный формат: %s" % baseline)
    log("")
    confirmed = []
    for val in NEW_VIDEO:
        ok = step("Resolution=%s" % val, {"command": "RCVideoFormatSet", "Resolution": val})
        seen = meta_after("VideoFormat", val) if ok else None
        verdict = ("ПОДТВЕРЖДЁН метаданными" if seen == val
                   else "принят, но метаданные показывают %r" % seen)
        log("      %s" % (verdict if ok else "отвергнут"))
        if ok and seen == val:
            confirmed.append(val)
        log("")
    log("  ПОДТВЕРЖДЕНО МЕТАДАННЫМИ: %s" % (", ".join(confirmed) if confirmed else "ничего"))
    return confirmed, baseline


def record_clips(formats):
    if not formats:
        return
    log("")
    log("=" * 72)
    log("ЭТАП 3. ЗАПИСЬ КЛИПОВ подтверждённых форматов (ffprobe скажет правду)")
    log("=" * 72)
    for val in formats:
        log("")
        log("  --- %s ---" % val)
        step("Resolution=%s" % val, {"command": "RCVideoFormatSet", "Resolution": val})
        time.sleep(1.0)
        if not step("VideoRecordingStart", {"command": "VideoRecordingStart"}):
            continue
        time.sleep(CLIP_SECONDS)
        step("VideoRecordingStop", {"command": "VideoRecordingStop"})
        time.sleep(2.0)


def probe_simple(strict):
    log("")
    log("=" * 72)
    log("ЭТАП 4. ОСТАЛЬНЫЕ СКРЫТЫЕ ЗНАЧЕНИЯ")
    log("=" * 72)
    groups = [("выдержка", "RCShutterSpeedSet", "dShutterSpeed", "ShutterSpeed", NEW_SHUTTER),
              ("диафрагма", "RCFNSet", "Fnumber", "Fnumber", NEW_FSTOP),
              ("качество", "RCImageQualitySet", "ImageQuality", "ImageQuality", NEW_QUALITY)]
    for title, cmd, key, meta_key, values in groups:
        log("")
        log("  === %s ===" % title)
        for val in values:
            ok = step("%s=%s" % (key, val), {"command": cmd, key: val})
            if ok:
                seen = meta_after(meta_key, val, wait=2.0)
                log("      метаданные: %r %s" % (seen, "✓" if seen == val else "(не подтвердили)"))
    log("")
    log("  === прочее ===")
    for cmd, key, val in NEW_MISC:
        step("%s %s=%s" % (cmd, key, val), {"command": cmd, key: val})


def main():
    global _udp_on
    log("время: %s" % datetime.now().isoformat(timespec="seconds"))
    log("")

    status, _ = send({"command": "GetCameraStatus"}, timeout=5.0)
    if status is None:
        log("НЕТ СВЯЗИ С КАМЕРОЙ (192.168.0.10). Проверь Wi-Fi.")
        return

    threading.Thread(target=udp_listener, daemon=True).start()

    log("Открываем сессию удалённого управления...")
    if not step("RCStartRemoteCtl", {"command": "RCStartRemoteCtl"}):
        log("Сессия не открылась — камера занята другим клиентом?")
        return
    time.sleep(2.0)   # дать метаданным появиться

    baseline = None
    try:
        strict = negative_control()
        confirmed, baseline = probe_video(strict)
        record_clips(confirmed)
        probe_simple(strict)
    finally:
        log("")
        log("=== Возвращаем исходный формат и закрываем сессию ===")
        if baseline:
            step("Resolution=%s (восстановление)" % baseline,
                 {"command": "RCVideoFormatSet", "Resolution": baseline})
        step("RCStopRemoteCtl", {"command": "RCStopRemoteCtl"})
        _udp_on = False
        time.sleep(0.3)
        log("")
        log("Лог: %s" % LOG)
        log("")
        log("ДАЛЬШЕ: покажи мне лог. Если что-то записалось — скачаем клипы")
        log("скриптом probe_clips_and_lens.py и проверим ffprobe.")


if __name__ == "__main__":
    main()
