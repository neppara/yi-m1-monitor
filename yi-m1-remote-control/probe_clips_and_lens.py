#!/usr/bin/env python3
"""
Две задачи:
  1) Скачать два последних видеоклипа (FHD_24 / FHD_30) — чтобы ffprobe сказал
     ПРАВДУ о реальном fps, а не то, что нам ответила камера.
  2) Собрать всё, что камера знает об объективе, по HTTP.

БЕЗОПАСНОСТЬ: только чтение. Ничего не пишется в камеру, ничего не удаляется,
никакие прошивки НЕ запускаются. Команда UpdateLenFW здесь СОЗНАТЕЛЬНО не
вызывается — она пишет прошивку в объектив, это отдельное решение человека.

Запуск (Mac уже в Wi-Fi камеры):
    ./venv/bin/python3 probe_clips_and_lens.py            # клипы + объектив
    ./venv/bin/python3 probe_clips_and_lens.py --lens     # только объектив (быстро)
"""

import json
import os
import sys
import time
from datetime import datetime

from urllib3 import PoolManager

INET_ADDRESS_CAMERA = "192.168.0.10"

OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       "fable research", "wifi-experiment-results",
                       "run_%s_clips_lens" % datetime.now().strftime("%Y%m%d_%H%M%S"))
os.makedirs(OUT_DIR, exist_ok=True)
LOG_PATH = os.path.join(OUT_DIR, "log.txt")

_lines = []


def log(msg=""):
    print(msg, flush=True)
    _lines.append(str(msg))
    with open(LOG_PATH, "w", encoding="utf-8") as fh:
        fh.write("\n".join(_lines) + "\n")


http = PoolManager()


def send(cmd, timeout=10.0):
    url = "http://%s/?data=%s" % (INET_ADDRESS_CAMERA,
                                  json.dumps(cmd, separators=(",", ":")))
    try:
        r = http.request("GET", url, timeout=timeout)
        return r.status, r.data.decode("utf-8", errors="replace")
    except Exception as exc:
        return None, repr(exc)


def is_ok(status, body):
    """Успех = HTTP 200 И code == 200 (не 0!). Логика из app/camera_session.py."""
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


def lens_and_camera_info():
    log("=" * 68)
    log("ИНФОРМАЦИЯ ОБ ОБЪЕКТИВЕ И КАМЕРЕ")
    log("=" * 68)

    status, body = send({"command": "GetCameraStatus"})
    log("GetCameraStatus -> HTTP %s" % status)
    log("  сырой ответ: %s" % body.strip())
    try:
        data = json.loads(body).get("data", {})
    except Exception:
        data = {}

    if data:
        log("")
        log("  разобрано по полям:")
        for key in sorted(data):
            log("    %-22s = %r" % (key, data[key]))
        log("")
        lens_ver = data.get("lenVer")
        lens_type = data.get("lenType")
        log("  --- ОБЪЕКТИВ ---")
        log("    версия прошивки : %r" % lens_ver)
        log("    тип/модель      : %r" % lens_type)
        if lens_type in ("", None):
            log("    >>> Камера НЕ сообщает модель объектива (пустая строка).")
            log("        Для мануального стекла без электроники это ожидаемо.")
            log("        Если сейчас стоит КИТОВЫЙ 12-40 и поле всё равно пустое —")
            log("        значит тело не опознаёт объектив, и это уже само по себе")
            log("        объясняет, почему обновление прошивки объектива не идёт.")
        else:
            log("    >>> Камера опознаёт объектив как: %r" % lens_type)

    # CheckPreUpdate — по имени это ПРОВЕРКА готовности к обновлению, не само
    # обновление. Вызываем только её; UpdateLenFW сознательно не трогаем.
    log("")
    log("  --- проверка готовности к обновлению (только запрос, без прошивки) ---")
    status, body = send({"command": "CheckPreUpdate"})
    log("    CheckPreUpdate -> HTTP %s | %s" % (status, body.strip()[:200]))


def file_list():
    """ВАЖНО: параметры называются range_start/range_end (строками), НЕ id_start/id_end.
    Нулевая ширина диапазона даёт {"code":1502} (баг #11)."""
    status, body = send({"command": "GetFileList",
                         "range_start": "0", "range_end": "9999",
                         "filetype": "all"})
    if not is_ok(status, body):
        log("GetFileList не удался -> HTTP %s | %s" % (status, body.strip()[:200]))
        return []
    try:
        data = json.loads(body).get("data", [])
    except Exception as exc:
        log("Не разобрал ответ GetFileList: %r" % exc)
        log("  сырой ответ (первые 400): %s" % body[:400])
        return []
    if not isinstance(data, list):
        log("Неожиданная форма ответа: %s" % body[:400])
        return []
    return [e for e in data if isinstance(e, dict)]


def download(path_on_camera, dest_path):
    url = "http://%s/?data=%s" % (
        INET_ADDRESS_CAMERA,
        json.dumps({"command": "GetFile", "path": path_on_camera,
                    "resulotion": "Original"}, separators=(",", ":")))
    try:
        resp = http.request("GET", url, preload_content=False, timeout=120.0)
        total = 0
        with open(dest_path, "wb") as fh:
            while True:
                chunk = resp.read(65536)
                if not chunk:
                    break
                fh.write(chunk)
                total += len(chunk)
        resp.release_conn()
        return total
    except Exception as exc:
        log("    ошибка скачивания: %r" % exc)
        return 0


def clips():
    log("")
    log("=" * 68)
    log("СКАЧИВАНИЕ ПОСЛЕДНИХ ВИДЕОКЛИПОВ")
    log("=" * 68)

    entries = file_list()
    if not entries:
        log("Список файлов пуст или не получен.")
        return

    log("Всего записей: %d" % len(entries))
    log("")
    log("Ключи первой записи (чтобы знать структуру): %s"
        % sorted(entries[0].keys()))
    log("")

    entries.sort(key=lambda e: str(e.get("date", "")), reverse=True)
    log("Последние 8 файлов:")
    for e in entries[:8]:
        log("  %s  %s  %s" % (str(e.get("date", "?")),
                              str(e.get("filetype", "?")).ljust(6),
                              e.get("path", "?")))

    videos = [e for e in entries
              if str(e.get("path", "")).upper().endswith((".MP4", ".MOV", ".AVI"))]
    if not videos:
        log("")
        log("Видеофайлов в списке не нашлось — проверь расширения выше.")
        return

    log("")
    log("Качаю два последних видео:")
    for entry in videos[:2]:
        remote = entry.get("path")
        local = os.path.join(OUT_DIR, os.path.basename(remote))
        log("  <- %s" % remote)
        size = download(remote, local)
        log("     сохранено: %s (%s байт)" % (local, size))


def main():
    lens_only = "--lens" in sys.argv

    log("время: %s" % datetime.now().isoformat(timespec="seconds"))
    log("")

    status, _ = send({"command": "GetCameraStatus"}, timeout=5.0)
    if status is None:
        log("НЕТ СВЯЗИ С КАМЕРОЙ (192.168.0.10). Проверь Wi-Fi.")
        return

    lens_and_camera_info()

    if not lens_only:
        clips()

    log("")
    log("Готово. Лог и файлы: %s" % OUT_DIR)


if __name__ == "__main__":
    main()
