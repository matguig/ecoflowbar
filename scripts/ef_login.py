#!/usr/bin/env python3
"""Récupération de l'identifiant utilisateur EcoFlow (étape unique, en ligne).

Le protocole BLE V2 d'EcoFlow exige l'ID du compte auquel l'appareil est lié.
Ce script vous demande vos identifiants EcoFlow, les envoie UNIQUEMENT aux
serveurs EcoFlow (même appel que l'app officielle), et ne conserve localement
que l'ID utilisateur retourné. Le mot de passe n'est jamais écrit sur disque.

Usage :  .venv/bin/python scripts/ef_login.py
"""

import asyncio
import getpass
import sys

from common import load_config, save_config

import aiohttp  # noqa: E402
from eflib.login import EcoFlowLogin, Region  # noqa: E402


async def main() -> int:
    print("— Connexion au compte EcoFlow (une seule fois, nécessite Internet) —")
    identifier = input("Email du compte EcoFlow : ").strip()
    password = getpass.getpass("Mot de passe (non affiché, non conservé) : ")
    region = input("Région [auto] (auto/api/api-e/api-a/api-j/api-r/api-cn) : ").strip() or "auto"

    async with aiohttp.ClientSession() as session:
        result = await EcoFlowLogin(session).login(identifier, password, region)

    if result.error or not result.user_id:
        print(f"Échec : {result.error}", file=sys.stderr)
        return 1

    config = load_config()
    config["user_id"] = result.user_id
    save_config(config)
    print(f"OK — user_id {result.user_id} enregistré dans la configuration.")
    print("Étape suivante : scripts/ef_scan.py (batterie allumée, à portée Bluetooth).")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
