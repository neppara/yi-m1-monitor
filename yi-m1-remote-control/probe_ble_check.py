#!/usr/bin/env python3
"""Быстрая диагностика BLE: видно ли камеру вообще.

Ничего не подключает и не меняет — только смотрит эфир. Нужен, когда основной
скрипт говорит "камера не найдена", и надо понять, в камере дело или в Mac.

    ./venv/bin/python3 probe_ble_check.py
"""
import asyncio
import subprocess

YI_SERVICE = "41106dd9-25ad-477b-a884-5038b6de4649"


def bluetooth_state():
    try:
        out = subprocess.check_output(["system_profiler", "SPBluetoothDataType"],
                                      text=True, timeout=20)
        for line in out.splitlines():
            if "State:" in line:
                return line.strip()
    except Exception as exc:
        return "не смог прочитать: %r" % (exc,)
    return "неизвестно"


async def scan(seconds, attempt, total):
    from bleak import BleakScanner
    print("--- скан %d из %d, %d секунд ---" % (attempt, total, seconds), flush=True)
    try:
        devices = await BleakScanner.discover(timeout=float(seconds), return_adv=True)
    except Exception as exc:
        print("  ОШИБКА сканера: %r" % (exc,), flush=True)
        return False
    camera = None
    named = 0
    for dev, adv in devices.values():
        uuids = [u.lower() for u in (adv.service_uuids or [])]
        if YI_SERVICE in uuids or (dev.name or "").startswith("YI_M1"):
            camera = (dev, adv)
        if dev.name:
            named += 1
    print("  устройств видно: %d (из них с именем: %d)" % (len(devices), named), flush=True)
    if camera:
        dev, adv = camera
        print("  >>> КАМЕРА НАЙДЕНА: %s  rssi=%s" % (dev.name, adv.rssi), flush=True)
        if adv.rssi < -75:
            print("      сигнал слабый — поднеси камеру ближе к Mac", flush=True)
        return True
    print("  камеры нет в эфире", flush=True)
    return False


async def main():
    print("Bluetooth: %s" % bluetooth_state())
    print()
    for i in range(1, 4):
        if await scan(10, i, 3):
            print()
            print("Камера доступна — можно запускать основной скрипт.")
            return
        print()
        if i < 3:
            print("Потрогай камеру (кнопка/колесо), чтобы она не спала. Повторяю...")
            print()
            await asyncio.sleep(3)
    print("За 3 попытки камера не появилась. По убыванию вероятности:")
    print("  1. ВЫКЛЮЧИ И ВКЛЮЧИ КАМЕРУ — после Wi-Fi-сессии она часто перестаёт")
    print("     рекламироваться по BLE, пока не перезагрузится.")
    print("  2. К камере уже подключён другой BLE-клиент (телефон, официальное")
    print("     приложение, наш iOS-монитор) — камера принимает только одного.")
    print("  3. Камера ушла в сон.")


asyncio.run(main())
