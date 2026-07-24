#!/usr/bin/env python3
"""
Три независимых вопроса за один заход:

  1) ChangeCurrentFrame - команда, которую не отправлял НИКТО. В таблице прошивки её
     имя не заканчивается нулём (после него стоит 0xff), поэтому все инструменты,
     включая нашего агента, читали эту запись как "пустая/нечитаемая". Настоящее имя
     прочитано побайтово: "ChangeCurrentFrame", 18 символов, обработчик 0x00156180.

  2) Семейство ML (GetMLFileList / UploadML / DeleteMLFile) - что это за сущность?
     Здесь вызывается ТОЛЬКО читающая GetMLFileList. UploadML сознательно НЕ трогаем:
     это единственная команда во всём протоколе, которая пишет файл В камеру, и вслепую
     её дёргать нельзя.

  3) Пикинг самой камеры. Пользователь подтвердил: камера умеет подсвечивать края
     КРАСНЫМ. Вся обработка кадра идёт на камере, значит подсветка, скорее всего, уже
     ВШИТА в JPEG живого вида - и тогда её можно использовать вместо нашего Sobel.
     Строка "MF-PEAK" в прошивке ни на что не ссылается как параметр, зато рядом лежит
     отладочная "PEAK MPOS :%04d" - похоже, это ЗНАЧЕНИЕ, которое камера сообщает сама.

     Экран камеры блокируется во время Wi-Fi-сессии, поэтому переключать пикинг надо
     ДО запуска. Отсюда схема: два прогона с разными метками, потом сравниваем.

БЕЗОПАСНОСТЬ: только чтение и безобидные команды. Ничего не прошивается, файлы не
удаляются, UploadML не вызывается.

Запуск - ДВА раза, с разными метками:
    # 1) выключи пикинг на камере, подключись, потом:
    ./venv/bin/python3 probe_unknown_commands.py --label peaking-off

    # 2) отключись, включи пикинг на камере, подключись снова, потом:
    ./venv/bin/python3 probe_unknown_commands.py --label peaking-on

Скрипт сам сравнит второй прогон с первым, если найдёт его.
"""

import glob
import json
import os
import re
import socket
import sys
import threading
import time
from datetime import datetime

from urllib3 import PoolManager

from probe_connect import connect_to_camera, restore_wifi

CAMERA = "192.168.0.10"
UDP_PORT = 54321
FRAMES_TO_SAVE = 6

RESULTS_ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                            "fable research", "wifi-experiment-results")

label = "run"
for i, arg in enumerate(sys.argv):
    if arg == "--label" and i + 1 < len(sys.argv):
        label = sys.argv[i + 1]

OUT_DIR = os.path.join(RESULTS_ROOT, "run_%s_unknown_%s"
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


def step(label_text, cmd, quiet_body=False):
    status, body = send(cmd)
    ok = is_ok(status, body)
    shown = body.strip()[:150] if not quiet_body else "(тело в отдельном файле)"
    log("  [%s] %-44s -> %s | %s" % ("OK  " if ok else "FAIL", label_text, status, shown))
    return ok, body


# ------------------------------------------------------------------ live view
_meta_full = {}
_frames = []
_udp_on = True


def udp_listener():
    """Собираем ВСЕ поля метаданных + корректно пересобранные кадры.

    ФОРМАТ (портировано из app/camera_session.py - НЕ упрощать):
    каждая датаграмма = 12-байтовый заголовок + payload, всё big-endian:
        [0:4]  индекс кадра
        [4:8]  сколько всего пакетов в этом кадре
        [8:12] индекс этого пакета внутри кадра
    Пакеты приходят НЕ ПО ПОРЯДКУ - Wi-Fi спокойно переставляет их местами, поэтому
    собирать надо по индексам в массив, а не склеивать подряд. Первая версия этого
    скрипта именно склеивала подряд и выдавала битые JPEG, из-за чего проверка
    пикинга дала бессмысленный результат.

    В собранном кадре первые 2048 байт - текстовый заголовок с метаданными, дальше JPEG.
    """
    pending = []          # список кадров в сборке; храним максимум 3
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

                frame_idx = int.from_bytes(pack[:4], "big")
                total = int.from_bytes(pack[4:8], "big")
                pkt_idx = int.from_bytes(pack[8:12], "big")
                payload = pack[12:]
                if total <= 0 or total > 4096:
                    continue

                frame = next((f for f in pending if f["idx"] == frame_idx), None)
                if frame is None:
                    frame = {"idx": frame_idx, "total": total,
                             "pieces": [None] * total, "got": 0}
                    pending.append(frame)
                    if len(pending) > 3:
                        pending.pop(0)          # старый кадр не дособрался - выбрасываем
                if 0 <= pkt_idx < frame["total"] and frame["pieces"][pkt_idx] is None:
                    frame["pieces"][pkt_idx] = payload
                    frame["got"] += 1

                done = next((f for f in pending if f["got"] == f["total"]), None)
                if done is None:
                    continue
                pending.remove(done)

                data = b"".join(done["pieces"])
                if len(data) <= 2048:
                    continue
                header, jpeg = data[:2048], data[2048:]
                for k, v in re.findall(rb'"([A-Za-z0-9_]+)"\s*:\s*"([^"]*)"', header):
                    _meta_full[k.decode()] = v.decode("ascii", "replace")
                if len(_frames) < FRAMES_TO_SAVE and jpeg[:3] == b'\xff\xd8\xff':
                    _frames.append(jpeg)
    except Exception as exc:
        log("  (UDP-слушатель не поднялся: %r)" % (exc,))


def dump_metadata_and_frames():
    log("")
    log("=" * 72)
    log("ЭТАП 1. ПОЛНЫЙ СНИМОК МЕТАДАННЫХ И КАДРОВ  (метка: %s)" % label)
    log("=" * 72)
    log("Ждём поток live view...")
    deadline = time.time() + 12
    while time.time() < deadline and (len(_meta_full) < 5 or len(_frames) < 2):
        time.sleep(0.5)

    log("")
    log("ВСЕ поля метаданных, которые прислала камера (%d штук):" % len(_meta_full))
    for k in sorted(_meta_full):
        log("    %-22s = %r" % (k, _meta_full[k]))

    with open(os.path.join(OUT_DIR, "metadata.json"), "w", encoding="utf-8") as fh:
        json.dump(_meta_full, fh, indent=2, ensure_ascii=False, sort_keys=True)

    for i, frame in enumerate(_frames):
        with open(os.path.join(OUT_DIR, "frame_%d.jpg" % i), "wb") as fh:
            fh.write(frame)
    log("")
    log("  сохранено кадров: %d (frame_0.jpg ...) - по ним увидим красную подсветку" % len(_frames))

    # сравнение с предыдущим прогоном
    previous = sorted(glob.glob(os.path.join(RESULTS_ROOT, "run_*_unknown_*", "metadata.json")))
    previous = [p for p in previous if os.path.dirname(p) != OUT_DIR]
    if previous:
        prev_path = previous[-1]
        try:
            with open(prev_path, encoding="utf-8") as fh:
                prev = json.load(fh)
        except Exception:
            prev = {}
        log("")
        log("  --- отличия от предыдущего прогона (%s) ---" % os.path.basename(os.path.dirname(prev_path)))
        changed = False
        for k in sorted(set(prev) | set(_meta_full)):
            a, b = prev.get(k), _meta_full.get(k)
            if a != b:
                changed = True
                log("      %-22s  %r  ->  %r" % (k, a, b))
        if not changed:
            log("      (ни одно поле не изменилось)")
        log("")
        log("  Если пикинг переключался между прогонами, изменившееся поле - он и есть.")


def probe_change_current_frame():
    log("")
    log("=" * 72)
    log("ЭТАП 2. ChangeCurrentFrame - команда, которую не отправлял никто")
    log("=" * 72)
    log("Имя прочитано побайтово (в таблице оно не заканчивается нулём, дальше 0xff).")
    log("Параметр неизвестен, поэтому пробуем правдоподобные ключи из общего пула.")
    log("")
    step("голая, без параметра", {"command": "ChangeCurrentFrame"})
    for key in ("Frame", "FFrame", "Cnt", "Operation", "Operate", "Resolution", "path"):
        for val in ("1", "0"):
            step("%s=%s" % (key, val), {"command": "ChangeCurrentFrame", key: val})
            time.sleep(0.2)
        if key in ("Operation", "Operate"):
            for val in ("NearS", "ON"):
                step("%s=%s" % (key, val), {"command": "ChangeCurrentFrame", key: val})
                time.sleep(0.2)
    log("")
    log("  Напоминание: 404 на голую команду НЕ значит 'не существует' - точно так же")
    log("  отвечает команда без обязательного параметра. Именно это годами прятало")
    log("  ключ Resolution.")


def probe_ml_family():
    log("")
    log("=" * 72)
    log("ЭТАП 3. Что такое 'ML'? (только чтение)")
    log("=" * 72)
    log("UploadML НЕ вызывается - это единственная команда, которая пишет файл в камеру.")
    log("Сначала выясняем, что за сущность, потом решаем.")
    log("")
    ok, body = step("GetMLFileList (голая)", {"command": "GetMLFileList"})
    if not ok:
        for extra in ({"range_start": "0", "range_end": "9999", "filetype": "all"},
                      {"range_start": "0", "range_end": "9999"},
                      {"filetype": "all"}):
            ok, body = step("GetMLFileList %s" % list(extra), dict({"command": "GetMLFileList"}, **extra))
            if ok:
                break
    if ok:
        with open(os.path.join(OUT_DIR, "ml_filelist.json"), "w", encoding="utf-8") as fh:
            fh.write(body)
        log("")
        log("  ОТВЕТ (первые 600 символов):")
        log("  " + body.strip()[:600])
        log("")
        log("  полный ответ сохранён в ml_filelist.json")


def probe_misc():
    log("")
    log("=" * 72)
    log("ЭТАП 4. Мелочи, оставшиеся с прошлого раза")
    log("=" * 72)
    log("")
    log("  --- Scene: что это за режим? Смотрим, изменится ли DialMode ---")
    before = _meta_full.get("DialMode")
    step("RCSwitchDialMode DialMode=Scene", {"command": "RCSwitchDialMode", "DialMode": "Scene"})
    time.sleep(2.5)
    log("      DialMode: %r -> %r" % (before, _meta_full.get("DialMode")))
    if before is not None:
        step("возврат DialMode=%s" % before, {"command": "RCSwitchDialMode", "DialMode": before})

    log("")
    log("  --- MF-PEAK как значение: пробуем туда, где оно правдоподобно ---")
    for cmd, key in (("RCMFAdjust", "Operation"), ("RCSwitchDialMode", "DialMode"),
                     ("RCFocusModeSet", "FocusMode")):
        step("%s %s=MF-PEAK" % (cmd, key), {"command": cmd, key: "MF-PEAK"})
        time.sleep(0.3)


def control_focus_mode():
    """РЕШАЮЩИЙ КОНТРОЛЬ для MF-PEAK.

    В прошлый раз RCFocusModeSet с MF-PEAK ответил не 404, а {"code":1000,"data":"set
    focus failed"} - то есть значение прошло дальше разбора и упало уже на применении.
    Соблазнительно заключить, что MF-PEAK - настоящий режим фокуса. НО этот вывод
    держится только если команда ОТВЕРГАЕТ мусор. Если она отвечает "set focus failed"
    вообще на всё, наблюдение пустое.

    Поэтому: сначала заведомая чушь, потом известные хорошие значения, потом MF-PEAK.
    Сравнение трёх ответов и даёт ответ.
    """
    log("")
    log("=" * 72)
    log("ЭТАП 5. КОНТРОЛЬ: валидирует ли RCFocusModeSet значения вообще?")
    log("=" * 72)
    log("Читать так:")
    log("  мусор -> 404, MF-PEAK -> 'set focus failed'  =  MF-PEAK НАСТОЯЩИЙ режим")
    log("  мусор -> 'set focus failed' (как и MF-PEAK)   =  команда жрёт что угодно,")
    log("                                                   зацепка пустая")
    log("")
    results = {}
    for tag, val in (("мусор", "ZZ_NOT_A_MODE_99"), ("мусор-2", "QQQQ"),
                     ("известное MF", "MF"), ("известное S-AF", "S-AF"),
                     ("MF-PEAK", "MF-PEAK")):
        _, body = step("%-16s FocusMode=%s" % (tag, val),
                       {"command": "RCFocusModeSet", "FocusMode": val})
        results[tag] = body.strip()[:80]
        time.sleep(0.4)

    log("")
    garbage_404 = "404" in results.get("мусор", "") or "Not Found" in results.get("мусор", "")
    peak_reached = "set focus failed" in results.get("MF-PEAK", "")
    log("  ВЫВОД:")
    if garbage_404 and peak_reached:
        log("    Мусор отвергается, а MF-PEAK доходит до применения.")
        log("    >>> MF-PEAK - НАСТОЯЩЕЕ значение FocusMode. Пикинг, вероятно,")
        log("    >>> включается через RCFocusModeSet, а падает из-за мёртвого объектива.")
    elif not garbage_404:
        log("    Мусор тоже принят -> команда не валидирует значения.")
        log("    >>> Наблюдение про MF-PEAK НИЧЕГО не доказывает. Зацепка закрыта.")
    else:
        log("    Картина не укладывается ни в один из двух сценариев - смотри ответы выше.")

    # восстановим исходный режим фокуса
    original = _meta_full.get("FocusMode")
    if original:
        step("возврат FocusMode=%s" % original,
             {"command": "RCFocusModeSet", "FocusMode": original})


def main():
    global _udp_on
    log("время: %s   метка: %s" % (datetime.now().isoformat(timespec="seconds"), label))
    log("")

    # Автоподключение: BLE-пейринг + присоединение к Wi-Fi камеры без ручных шагов.
    if not connect_to_camera(log):
        return

    threading.Thread(target=udp_listener, daemon=True).start()

    if not step("RCStartRemoteCtl", {"command": "RCStartRemoteCtl"})[0]:
        log("Сессия не открылась - камера занята другим клиентом?")
        return

    try:
        dump_metadata_and_frames()
        probe_change_current_frame()
        probe_ml_family()
        probe_misc()
        control_focus_mode()
    finally:
        log("")
        step("RCStopRemoteCtl", {"command": "RCStopRemoteCtl"})
        _udp_on = False
        time.sleep(0.3)
        log("")
        restore_wifi(log)
        log("")
        log("Результаты: %s" % OUT_DIR)
        log("")
        log("ДАЛЬШЕ: покажи лог. Если это был прогон 'peaking-on' - я сравню кадры")
        log("и метаданные с прогоном 'peaking-off' и скажу, отдаёт ли камера подсветку")
        log("прямо в live view.")


if __name__ == "__main__":
    main()
