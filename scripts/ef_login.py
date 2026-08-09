#!/usr/bin/env python3
"""Fetch the EcoFlow user ID (one-time, online step).

EcoFlow's BLE V2 protocol requires the ID of the account the device is linked
to. This script asks for your EcoFlow credentials, sends them ONLY to the
EcoFlow servers (the same call the official app makes), and keeps locally only
the returned user ID. The password is never written to disk.

Usage:  .venv/bin/python scripts/ef_login.py
"""

import asyncio
import getpass
import sys

from common import load_config, save_config

import aiohttp  # noqa: E402
from eflib.login import EcoFlowLogin, Region  # noqa: E402


async def main() -> int:
    print("— Sign in to the EcoFlow account (one time only, requires Internet) —")
    identifier = input("EcoFlow account email: ").strip()
    password = getpass.getpass("Password (not shown, not stored): ")
    region = input("Region [auto] (auto/api/api-e/api-a/api-j/api-r/api-cn): ").strip() or "auto"

    async with aiohttp.ClientSession() as session:
        result = await EcoFlowLogin(session).login(identifier, password, region)

    if result.error or not result.user_id:
        print(f"Failed: {result.error}", file=sys.stderr)
        return 1

    config = load_config()
    config["user_id"] = result.user_id
    save_config(config)
    print(f"OK — user_id {result.user_id} saved to the configuration.")
    print("Next step: scripts/ef_scan.py (battery powered on, within Bluetooth range).")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
