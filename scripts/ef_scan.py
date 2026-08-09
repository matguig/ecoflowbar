#!/usr/bin/env python3
"""Scan Bluetooth des appareils EcoFlow à portée.

Liste les appareils EcoFlow détectés et enregistre dans la configuration le
numéro de série de celui à surveiller (automatique s'il n'y en a qu'un).

Usage :  .venv/bin/python scripts/ef_scan.py [durée_scan_secondes]
"""

import asyncio
import sys

from common import load_config, save_config

from bleak import BleakScanner  # noqa: E402
import eflib  # noqa: E402


async def main() -> int:
    duration = float(sys.argv[1]) if len(sys.argv) > 1 else 15.0
    print(f"Scan Bluetooth pendant {duration:.0f} s…")

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
        print("Aucun appareil EcoFlow détecté.", file=sys.stderr)
        print("Vérifiez que la batterie est allumée, à portée, et que le", file=sys.stderr)
        print("Bluetooth du Mac est actif (autorisation macOS accordée).", file=sys.stderr)
        return 1

    print(f"\n{len(found)} appareil(s) EcoFlow détecté(s) :")
    for info in found.values():
        flag = "" if info["supported"] else "  [NON SUPPORTÉ]"
        print(f"  - {info['name']}  SN={info['sn']}  RSSI={info['rssi']} dBm{flag}")

    supported = [i for i in found.values() if i["supported"]]
    if len(supported) == 1:
        target = supported[0]
    else:
        sn_input = input("\nNuméro de série à surveiller : ").strip()
        matches = [i for i in supported if i["sn"] == sn_input]
        if not matches:
            print("SN inconnu.", file=sys.stderr)
            return 1
        target = matches[0]

    config = load_config()
    config["device_sn"] = target["sn"]
    config["device_name"] = target["name"]
    save_config(config)
    print(f"\nOK — {target['name']} (SN {target['sn']}) enregistré comme appareil à surveiller.")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
