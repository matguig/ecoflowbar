#!/usr/bin/env python3
# <bitbar.title>EcoFlow Battery</bitbar.title>
# <bitbar.desc>Niveau et autonomie de la batterie EcoFlow (via démon BLE local)</bitbar.desc>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
"""Plugin SwiftBar : affiche l'état EcoFlow écrit par ef_monitor.py."""

import json
import time
from pathlib import Path

APP_DIR = Path.home() / "Library" / "Application Support" / "ecoflow-monitor"
STATE = APP_DIR / "state.json"
CONFIG = APP_DIR / "config.json"
LOG = Path.home() / "Library" / "Logs" / "ecoflow-monitor.log"
STALE_SECONDS = 60

# Le plugin est un lien symbolique depuis ~/.swiftbar vers le projet
PROJECT = Path(__file__).resolve().parent.parent
PYTHON = PROJECT / ".venv" / "bin" / "python"
CONFIG_SCRIPT = PROJECT / "scripts" / "ef_config.py"

CONFIG_DEFAULTS = {
    "thresholds": {"notify": 20, "lowpower": 10, "shutdown": 5, "restore": 15},
    "actions_enabled": True,
    "actions": {"notify": True, "lowpower": True, "shutdown": False},
    "require_mac_on_ecoflow": True,
}

THRESHOLD_PRESETS = {
    "notify": ("Notification batterie faible", [15, 20, 25, 30]),
    "lowpower": ("Mode économie d'énergie", [5, 10, 15]),
    "shutdown": ("Extinction propre", [3, 5, 8]),
    "restore": ("Retour au mode normal", [13, 15, 20, 25]),
}

TOGGLES = [
    ("actions.notify", "Notifications"),
    ("actions.lowpower", "Mode éco automatique"),
    ("actions.shutdown", "Extinction automatique"),
    ("require_mac_on_ecoflow", "Agir seulement si le Mac est sur l'EcoFlow"),
]


def load_settings():
    merged = json.loads(json.dumps(CONFIG_DEFAULTS))
    try:
        raw = json.loads(CONFIG.read_text())
    except (OSError, json.JSONDecodeError):
        return merged
    for key, value in raw.items():
        if isinstance(value, dict) and isinstance(merged.get(key), dict):
            merged[key].update(value)
        else:
            merged[key] = value
    return merged


def config_action(label, depth, checked, *args):
    parts = [f"{'-' * depth} {label} | shell={PYTHON} param1={CONFIG_SCRIPT}"]
    parts += [f"param{i}={arg}" for i, arg in enumerate(args, start=2)]
    parts.append("terminal=false refresh=true")
    if checked:
        parts.append("checked=true")
    return " ".join(parts)


def settings_lines(lines):
    settings = load_settings()
    lines.append("Réglages")
    lines.append(
        config_action("Actions automatiques sur le Mac", 2,
                      bool(settings.get("actions_enabled", True)),
                      "toggle", "actions_enabled")
    )
    lines.append("-- ---")
    for key, (label, presets) in THRESHOLD_PRESETS.items():
        current = settings["thresholds"].get(key)
        lines.append(f"-- {label} : {current} %")
        values = sorted(set(presets) | ({current} if isinstance(current, int) else set()))
        for value in values:
            lines.append(
                config_action(f"{value} %", 4, value == current,
                              "set", f"thresholds.{key}", str(value))
            )
    lines.append("-- ---")
    for dotted, label in TOGGLES:
        node = settings
        *parents, leaf = dotted.split(".")
        for part in parents:
            node = node.get(part, {})
        lines.append(config_action(label, 2, bool(node.get(leaf)), "toggle", dotted))


def fmt_minutes(minutes):
    if not minutes or minutes <= 0:
        return None
    return f"{int(minutes) // 60}:{int(minutes) % 60:02d}"


def fmt_watts(value):
    return f"{value:.0f} W" if isinstance(value, (int, float)) else "—"


def menu_footer(lines):
    lines.append("---")
    settings_lines(lines)
    lines.append("---")
    lines.append(f"Ouvrir le journal du démon | shell=/usr/bin/open param1={LOG}")
    lines.append("Rafraîchir | refresh=true")


def main():
    lines = []

    try:
        state = json.loads(STATE.read_text())
    except (OSError, json.JSONDecodeError):
        print("⚡︎ ∅ | color=gray")
        print("---")
        print("Démon EcoFlow non configuré ou jamais lancé")
        print("Voir le README du projet portable-mac-mini")
        return

    age = time.time() - state.get("ts", 0)
    status = state.get("status")

    if age > STALE_SECONDS:
        print("⚡︎ ⚠︎ | color=orange")
        lines.append(f"Démon injoignable (dernier état il y a {age / 60:.0f} min)")
        menu_footer(lines)
        print("\n".join(["---"] + lines))
        return

    if status in ("searching", "offline", "unconfigured"):
        label = {
            "searching": "recherche Bluetooth…",
            "offline": "EcoFlow hors de portée ou éteinte",
            "unconfigured": "non configuré : lancer ef_login.py",
        }[status]
        print("⚡︎ – | color=gray")
        lines.append(f"EcoFlow : {label}")
        menu_footer(lines)
        print("\n".join(["---"] + lines))
        return

    level = state.get("battery_level") or 0
    mode = state.get("power_mode")
    on_ecoflow = state.get("mac_on_ecoflow")

    color = ""
    if mode == "discharging":
        if level <= 10:
            color = " | color=red"
        elif level <= 20:
            color = " | color=orange"

    if mode == "charging":
        title = f"⚡︎ {level:.0f}%"
    elif mode == "discharging":
        remaining = fmt_minutes(state.get("remaining_time_discharging"))
        title = f"🔋 {level:.0f}%" + (f" {remaining}" if remaining else "")
    else:  # idle : sur secteur ou aucune charge
        title = f"🔌 {level:.0f}%"

    print(title + color)
    print("---")

    lines.append(f"{state.get('device', 'EcoFlow')} — {level:.0f} %")
    if mode == "discharging":
        remaining = fmt_minutes(state.get("remaining_time_discharging"))
        if remaining:
            lines.append(f"Autonomie restante : {remaining.replace(':', ' h ')}")
    elif mode == "charging":
        remaining = fmt_minutes(state.get("remaining_time_charging"))
        if remaining:
            lines.append(f"Charge complète dans : {remaining.replace(':', ' h ')}")

    lines.append(
        f"Mac sur EcoFlow : {'oui' if on_ecoflow else 'non'}"
        + (f" ({fmt_watts(state.get('ac_output_power'))})" if on_ecoflow else "")
    )
    lines.append("---")
    lines.append(f"Entrée : {fmt_watts(state.get('input_power'))}")
    lines.append(f"Sortie AC : {fmt_watts(state.get('ac_output_power'))}")
    lines.append(f"Sortie USB-C : {fmt_watts(state.get('usbc_output_power'))}")
    temp = state.get("cell_temperature")
    if isinstance(temp, (int, float)):
        lines.append(f"Température cellules : {temp:.0f} °C")
    lines.append(f"Mis à jour il y a {age:.0f} s | color=gray")
    menu_footer(lines)
    print("\n".join(lines))


if __name__ == "__main__":
    main()
