#!/usr/bin/env python3
"""Bluetooth scan for EcoFlow devices within range.

Lists the detected EcoFlow devices and saves to the configuration the serial
number of the one to monitor (automatic if there is only one).

Usage:  .venv/bin/python scripts/ef_scan.py [scan_duration_seconds]
"""

import asyncio
import sys

from common import load_config, save_config

from bleak import BleakScanner  # noqa: E402
import eflib  # noqa: E402


async def main() -> int:
    duration = float(sys.argv[1]) if len(sys.argv) > 1 else 15.0
    print(f"Bluetooth scan for {duration:.0f} s…")

    found: dict[str, dict] = {}

    def callback(ble_dev, adv_data):
        sn = eflib.sn_from_advertisement(adv_data)
        if sn is None:
            return
        sn = sn.decode("ASCII", errors="replace")
        device = eflib.NewDevice(ble_dev, adv_data)
        if device is None:
            return
        found[sn] = {
            "sn": sn,
            "name": device.device,
            "address": ble_dev.address,
            "rssi": adv_data.rssi,
            "supported": not eflib.is_unsupported(device),
        }

    scanner = BleakScanner(detection_callback=callback)
    await scanner.start()
    await asyncio.sleep(duration)
    await scanner.stop()

    if not found:
        print("No EcoFlow device detected.", file=sys.stderr)
        print("Check that the battery is powered on, within range, and that the", file=sys.stderr)
        print("Mac's Bluetooth is on (macOS permission granted).", file=sys.stderr)
        return 1

    print(f"\n{len(found)} EcoFlow device(s) detected:")
    for info in found.values():
        flag = "" if info["supported"] else "  [UNSUPPORTED]"
        print(f"  - {info['name']}  SN={info['sn']}  RSSI={info['rssi']} dBm{flag}")

    supported = [i for i in found.values() if i["supported"]]
    if len(supported) == 1:
        target = supported[0]
    else:
        sn_input = input("\nSerial number to monitor: ").strip()
        matches = [i for i in supported if i["sn"] == sn_input]
        if not matches:
            print("Unknown SN.", file=sys.stderr)
            return 1
        target = matches[0]

    config = load_config()
    config["device_sn"] = target["sn"]
    config["device_name"] = target["name"]
    save_config(config)
    print(f"\nOK — {target['name']} (SN {target['sn']}) saved as the device to monitor.")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
