"""Paths and configuration shared across the ecoflow-monitor scripts."""

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
# One-shot commands dropped by the app (e.g. cut off the AC output)
COMMAND_PATH = APP_DIR / "command.json"
LOG_PATH = Path.home() / "Library" / "Logs" / "ecoflow-monitor.log"

DEFAULT_CONFIG = {
    # Language of the notifications and the app: "auto" (system), "fr" or "en"
    "language": "auto",
    # Filled in by ef_login.py / ef_scan.py
    "user_id": None,
    "device_sn": None,
    "device_name": None,
    # Thresholds in % of EcoFlow battery
    "thresholds": {
        "notify": 20,      # "low battery" notification
        "lowpower": 10,    # enable macOS low power mode
        "shutdown": 5,     # clean Mac shutdown
        "restore": 15,     # re-enable normal mode (hysteresis)
    },
    # Master switch: when false, no action is taken on the Mac
    # (the menu-bar display keeps working)
    "actions_enabled": True,
    "actions": {
        "notify": True,
        "lowpower": True,
        # Eco mode as soon as we switch to battery (without waiting for the threshold)
        "lowpower_on_battery": False,
        # Deliberate opt-in: set to true once the setup is validated
        "shutdown": False,
    },
    # Limits written to the battery; None = do not control.
    # max 80-85 % day to day extends the cell lifespan;
    # min > 0 keeps a reserve (UPS, cell health).
    "charge_limit_max": None,
    "charge_limit_min": None,
    # Below this AC draw (W), we consider the Mac not to be plugged
    # into the EcoFlow (margin: an idle M4 draws ~8-15 W as seen by the inverter)
    "mac_watts_min": 5,
    # The lowpower/shutdown actions only trigger if the Mac is
    # detected as plugged into the EcoFlow
    "require_mac_on_ecoflow": True,
    # Delay (s) between the shutdown warning and the actual shutdown
    "shutdown_grace_seconds": 60,
    # Interval (s) for writing state.json while connected
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
