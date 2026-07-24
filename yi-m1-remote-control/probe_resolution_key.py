#!/usr/bin/env python3
"""
Проверка гипотезы: ключ параметра команды RCVideoFormatSet — "Resolution".

Найдено статическим анализом прошивки (agent-tasks/AGENT_RESULT_02, перепроверено
вручную): строка "Resolution" лежит по адресу 0x6b8416, длина 10, и именно её
ищет обработчик 0x0015641c. Раньше перебирали VideoFormat/Value/Mode — все 404.

Значения видеоформатов, найденные в прошивке:
    4K_30, 4K_24, 2K_30, FHD_60, FHD_30, FHD_24, 4K_30_LOW

БЕЗОПАСНОСТЬ: скрипт шлёт только HTTP-команды. Ничего не прошивает, во флеш не
пишет, файлы на карте не удаляет. Худший случай — камера запутается в состоянии;
лечится выключением/включением камеры.

Запуск:
    python3 probe_resolution_key.py            # с BLE-пейрингом
    python3 probe_resolution_key.py --direct   # уже на Wi-Fi камеры

Лог пишется в fable research/wifi-experiment-results/run_<дата>_resolution_key/log.txt
"""

import json
import os
import re
import socket
import sys
import threading
import time
from datetime import datetime

from urllib3 import PoolManager

INET_ADDRESS_CAMERA = "192.168.0.10"
UDP_PORT_LIVEVIEW = 54321
RECORD_SECONDS = 5.0
RECORD_COOLDOWN = 2.0          # прошивке нужно время дописать файл

OUTPUT_ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                           "fable research", "wifi-experiment-results")
OUTPUT_DIR = os.path.join(OUTPUT_ROOT,
                          "run_%s_resolution_key" % datetime.now().strftime("%Y%m%d_%H%M%S"))
os.makedirs(OUTPUT_DIR, exist_ok=True)
LOG_PATH = os.path.join(OUTPUT_DIR, "log.txt")

_log_lines = []


def log(msg=""):
    print(msg, flush=True)
    _log_lines.append(str(msg))
    # пишем на каждый шаг: если скрипт упадёт или его прервут, лог уцелеет
    with open(LOG_PATH, "w", encoding="utf-8") as fh:
        fh.write("\n".join(_log_lines) + "\n")


http = PoolManager()


def send(command_dict, timeout=5.0):
    """Одна команда. Камера обслуживает ОДИН запрос за раз — только последовательно."""
    json_str = json.dumps(command_dict, separators=(",", ":"))
    url = "http://%s/?data=%s" % (INET_ADDRESS_CAMERA, json_str)
    try:
        response = http.request("GET", url, timeout=timeout)
        return response.status, response.data.decode("utf-8", errors="replace")
    except Exception as exc:
        return None, repr(exc)


def is_ok(status, body):
    """ВАЖНО: камера рапортует ошибку как HTTP 200 + {"code":<err>} в теле, где
    УСПЕХ обозначается code == 200 (а не 0!). Ошибки — 1515 "rc only one",
    1502 "get filelist err" и т.п. Логика скопирована один-в-один из рабочего
    app/camera_session.py::is_camera_success — не менять по памяти."""
    if status != 200:
        return False
    try:
        obj = json.loads(body)
    except Exception:
        return True          # не-JSON тело (например, сырые байты файла) = успех
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
    return True              # объект без поля "code" = успех


def step(label, command_dict, timeout=5.0):
    status, body = send(command_dict, timeout=timeout)
    verdict = "OK " if is_ok(status, body) else "FAIL"
    log("  [%s] %-52s -> HTTP %s | %s" % (verdict, label, status, body.strip()[:160]))
    return status, body


# --------------------------------------------------------------------------
# Фоновое чтение VideoFormat из UDP-метаданных live view (best effort)
# --------------------------------------------------------------------------
_seen_video_format = {"value": None}
_udp_running = True


def udp_metadata_listener():
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            sock.bind(("", UDP_PORT_LIVEVIEW))
            sock.settimeout(1.0)
            while _udp_running:
                try:
                    data, _ = sock.recvfrom(65535)
                except socket.timeout:
                    continue
                except Exception:
                    continue
                match = re.search(rb'"VideoFormat"\s*:\s*"([^"]*)"', data)
                if match:
                    _seen_video_format["value"] = match.group(1).decode("ascii", "replace")
    except Exception as exc:
        log("  (UDP-слушатель не запустился: %r — не критично)" % (exc,))


def current_format(wait_seconds=6.0):
    """Ждём, пока в метаданных появится VideoFormat."""
    deadline = time.time() + wait_seconds
    while time.time() < deadline:
        if _seen_video_format["value"]:
            return _seen_video_format["value"]
        time.sleep(0.3)
    return None


# --------------------------------------------------------------------------
def pair_via_ble():
    from prot_ble import trigger_remote_control_closest
    log("=== BLE-пейринг ===")
    result = trigger_remote_control_closest()
    if result is None:
        log("Пейринг не удался. Разбуди камеру и повтори.")
        raise SystemExit(1)
    ssid, password = result
    log("SSID: %s" % ssid)
    log("Пароль: %s" % password)
    log("")
    print("=" * 66)
    print("Переключи Wi-Fi этого Mac на сеть камеры (интернет пропадёт — это норма).")
    print("Затем ВЫКЛЮЧИ Bluetooth — он мешает Wi-Fi (общая антенна 2.4 ГГц).")
    print("=" * 66)
    input("Нажми Enter, когда подключишься... ")


def get_newest_files(limit=4):
    """Последние файлы на карте — чтобы понять, какие клипы мы только что записали."""
    status, body = send({"command": "GetFileList", "filetype": "all",
                         "id_start": 0, "id_end": 9999})
    if status != 200:
        return []
    try:
        entries = json.loads(body).get("data", [])
    except Exception:
        return []
    if not isinstance(entries, list):
        return []
    entries = [e for e in entries if isinstance(e, dict)]
    entries.sort(key=lambda e: str(e.get("date", "")), reverse=True)
    return entries[:limit]


def record_clip(tag):
    log("  -- запись клипа (%s), %.0f сек --" % (tag, RECORD_SECONDS))
    status, body = step("VideoRecordingStart", {"command": "VideoRecordingStart"})
    if not is_ok(status, body):
        log("  !! запись не стартовала, клип пропущен")
        return False
    time.sleep(RECORD_SECONDS)
    step("VideoRecordingStop", {"command": "VideoRecordingStop"})
    time.sleep(RECORD_COOLDOWN)
    return True


def main():
    global _udp_running

    direct = "--direct" in sys.argv

    log("=" * 66)
    log("ПРОВЕРКА КЛЮЧА 'Resolution' для RCVideoFormatSet")
    log("время: %s" % datetime.now().isoformat(timespec="seconds"))
    log("=" * 66)
    log("")

    if not direct:
        pair_via_ble()
    else:
        log("Режим --direct: считаем, что Mac уже в Wi-Fi камеры.")
        log("")

    threading.Thread(target=udp_metadata_listener, daemon=True).start()

    log("=== 0. Проверка связи ===")
    status, body = step("GetCameraStatus", {"command": "GetCameraStatus"})
    if status is None:
        log("")
        log("НЕТ СВЯЗИ С КАМЕРОЙ (192.168.0.10).")
        log("Проверь, что Mac подключён именно к Wi-Fi камеры.")
        return

    log("")
    log("=== 1. Открываем сессию удалённого управления ===")
    status, body = step("RCStartRemoteCtl", {"command": "RCStartRemoteCtl"})
    if not is_ok(status, body):
        log("")
        log("Сессия не открылась. Обычная причина — камера уже занята другим")
        log("клиентом (телефон/приложение). Отключи их и повтори.")
        return

    try:
        log("")
        log("=== 2. Текущий формат из метаданных live view ===")
        baseline = current_format()
        log("  VideoFormat сейчас: %s" % (baseline or "не удалось прочитать"))

        log("")
        log("=== 3. ГЛАВНЫЙ ТЕСТ: ключ 'Resolution' ===")
        log("    Сначала ставим ТО ЖЕ значение, что уже стоит — самый безопасный тест.")
        log("    Если вернётся успех, ключ угадан верно.")
        safe_value = baseline if baseline else "FHD_30"
        status, body = step("Resolution = %s (текущее)" % safe_value,
                            {"command": "RCVideoFormatSet", "Resolution": safe_value})
        resolution_works = is_ok(status, body)

        log("")
        if resolution_works:
            log("  >>> КЛЮЧ 'Resolution' ПРИНЯТ. Гипотеза подтверждена. <<<")
        else:
            log("  >>> 'Resolution' не принят. Пробуем остальные варианты ключа. <<<")
            for key in ("VideoFormat", "Value", "Mode", "resolution", "Res"):
                step("%s = %s" % (key, safe_value),
                     {"command": "RCVideoFormatSet", key: safe_value})

        log("")
        log("=== 4. Контроль: заведомо рабочая команда в этой же сессии ===")
        log("    Если она даст успех, а RCVideoFormatSet — нет, значит дело не в сессии.")
        step("RCISOSet ISO=200", {"command": "RCISOSet", "ISO": "200"})

        if not resolution_works:
            log("")
            log("Ключ не подтвердился — запись двух фрагментов пропускаем.")
            return

        log("")
        log("=== 5. Перебор всех значений из прошивки ===")
        accepted = []
        for value in ("FHD_24", "FHD_30", "FHD_60", "2K_30", "4K_24", "4K_30", "4K_30_LOW"):
            status, body = step("Resolution = %s" % value,
                                {"command": "RCVideoFormatSet", "Resolution": value})
            if is_ok(status, body):
                accepted.append(value)
            time.sleep(0.4)
        log("")
        log("  ПРИНЯТЫЕ значения: %s" % (", ".join(accepted) if accepted else "нет"))

        log("")
        log("=== 6. Два фрагмента для сравнения ===")
        files_before = {f.get("name") for f in get_newest_files(10)}

        clip_specs = []
        if "FHD_24" in accepted:
            clip_specs.append("FHD_24")
        if "FHD_30" in accepted:
            clip_specs.append("FHD_30")
        if len(clip_specs) < 2:
            clip_specs = accepted[:2]

        if len(clip_specs) < 2:
            log("  Недостаточно принятых значений для двух разных фрагментов.")
        else:
            for value in clip_specs:
                log("")
                log("  --- фрагмент в режиме %s ---" % value)
                step("Resolution = %s" % value,
                     {"command": "RCVideoFormatSet", "Resolution": value})
                time.sleep(1.0)
                log("    метаданные сообщают: %s" % (_seen_video_format["value"] or "?"))
                record_clip(value)

        log("")
        log("=== 7. Новые файлы на карте ===")
        for entry in get_newest_files(6):
            marker = "  <-- НОВЫЙ" if entry.get("name") not in files_before else ""
            log("  %s  %s  %s%s" % (entry.get("date", "?"),
                                    str(entry.get("size", "?")).rjust(10),
                                    entry.get("name", "?"), marker))

    finally:
        log("")
        log("=== Закрываем сессию ===")
        step("RCStopRemoteCtl", {"command": "RCStopRemoteCtl"})
        _udp_running = False
        time.sleep(0.3)
        log("")
        log("Лог сохранён: %s" % LOG_PATH)
        log("")
        log("ДАЛЬШЕ: верни Wi-Fi обратно, скачай два новых клипа с карты и покажи мне")
        log("лог — я сверю их реальные параметры (ffprobe) с тем, что мы запрашивали.")


if __name__ == "__main__":
    main()
