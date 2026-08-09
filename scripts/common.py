"""Chemins et configuration partagés entre les scripts ecoflow-monitor."""

import json
import os
import sys
import tempfile
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT_ROOT / "vendor"))

APP_DIR = Path.home() / "Library" / "Application Support" / "ecoflow-monitor"
CONFIG_PATH = APP_DIR / "config.json"
STATE_PATH = APP_DIR / "state.json"
HISTORY_PATH = APP_DIR / "history.json"
# Commandes one-shot déposées par l'app (ex: couper la sortie AC)
COMMAND_PATH = APP_DIR / "command.json"
LOG_PATH = Path.home() / "Library" / "Logs" / "ecoflow-monitor.log"

DEFAULT_CONFIG = {
    # Langue des notifications et de l'app : "auto" (système), "fr" ou "en"
    "language": "auto",
    # Rempli par ef_login.py / ef_scan.py
    "user_id": None,
    "device_sn": None,
    "device_name": None,
    # Seuils en % de batterie EcoFlow
    "thresholds": {
        "notify": 20,      # notification "batterie faible"
        "lowpower": 10,    # activation du mode économie d'énergie macOS
        "shutdown": 5,     # extinction propre du Mac
        "restore": 15,     # ré-activation du mode normal (hystérésis)
    },
    # Interrupteur général : à false, aucune action n'est effectuée sur le Mac
    # (l'affichage dans la barre de menus continue de fonctionner)
    "actions_enabled": True,
    "actions": {
        "notify": True,
        "lowpower": True,
        # Mode éco dès le passage sur batterie (sans attendre le seuil)
        "lowpower_on_battery": False,
        # Opt-in volontaire : passer à true une fois le montage validé
        "shutdown": False,
    },
    # Limites écrites dans la batterie ; None = ne pas piloter.
    # max 80-85 % au quotidien prolonge la durée de vie des cellules ;
    # min > 0 garde une réserve (UPS, santé des cellules).
    "charge_limit_max": None,
    "charge_limit_min": None,
    # En-dessous de ce débit AC (W), on considère que le Mac n'est pas branché
    # sur l'EcoFlow (marge : un M4 au repos tire ~8-15 W vus de l'onduleur)
    "mac_watts_min": 5,
    # Les actions lowpower/shutdown ne se déclenchent que si le Mac est
    # détecté comme branché sur l'EcoFlow
    "require_mac_on_ecoflow": True,
    # Délai (s) entre l'alerte d'extinction et le shutdown effectif
    "shutdown_grace_seconds": 60,
    # Période (s) d'écriture de state.json quand connecté
    "poll_seconds": 3,
}


def _merge(defaults: dict, overrides: dict) -> dict:
    out = dict(defaults)
    for key, value in overrides.items():
        if isinstance(value, dict) and isinstance(out.get(key), dict):
            out[key] = _merge(out[key], value)
        else:
            out[key] = value
    return out


def load_config() -> dict:
    if CONFIG_PATH.exists():
        return _merge(DEFAULT_CONFIG, json.loads(CONFIG_PATH.read_text()))
    return dict(DEFAULT_CONFIG)


def save_config(config: dict) -> None:
    APP_DIR.mkdir(parents=True, exist_ok=True)
    _atomic_write(CONFIG_PATH, json.dumps(config, indent=2, ensure_ascii=False))


def write_state(state: dict) -> None:
    APP_DIR.mkdir(parents=True, exist_ok=True)
    _atomic_write(STATE_PATH, json.dumps(state, indent=2, ensure_ascii=False))


def write_history(samples: list) -> None:
    APP_DIR.mkdir(parents=True, exist_ok=True)
    _atomic_write(HISTORY_PATH, json.dumps(samples))


def _atomic_write(path: Path, content: str) -> None:
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(content)
        os.replace(tmp, path)
    except BaseException:
        os.unlink(tmp)
        raise
