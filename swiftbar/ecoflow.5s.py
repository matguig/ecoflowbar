#!/usr/bin/env python3
# <bitbar.title>EcoFlow Battery</bitbar.title>
# <bitbar.desc>EcoFlow battery level and runtime (via local BLE daemon)</bitbar.desc>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
"""SwiftBar plugin: displays the EcoFlow state written by ef_monitor.py."""

import json
import time
from pathlib import Path

APP_DIR = Path.home() / "Library" / "Application Support" / "ecoflow-monitor"
STATE = APP_DIR / "state.json"
CONFIG = APP_DIR / "config.json"
LOG = Path.home() / "Library" / "Logs" / "ecoflow-monitor.log"
STALE_SECONDS = 60

# The plugin is a symlink from ~/.swiftbar into the project
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
    "notify": ("Low battery notification", [15, 20, 25, 30]),
    "lowpower": ("Low power mode", [5, 10, 15]),
    "shutdown": ("Clean shutdown", [3, 5, 8]),
    "restore": ("Back to normal mode", [13, 15, 20, 25]),
}

TOGGLES = [
    ("actions.notify", "Notifications"),
    ("actions.lowpower", "Automatic eco mode"),
    ("actions.shutdown", "Automatic shutdown"),
    ("require_mac_on_ecoflow", "Act only if the Mac is on the EcoFlow"),
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
    lines.append("Settings")
    lines.append(
        config_action("Automatic actions on the Mac", 2,
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
    lines.append(f"Open the daemon log | shell=/usr/bin/open param1={LOG}")
    lines.append("Refresh | refresh=true")


def main():
    lines = []

    try:
        state = json.loads(STATE.read_text())
    except (OSError, json.JSONDecodeError):
        print("⚡︎ ∅ | color=gray")
        print("---")
        print("EcoFlow daemon not configured or never started")
        print("See the portable-mac-mini project README")
        return

    age = time.time() - state.get("ts", 0)
    status = state.get("status")

    if age > STALE_SECONDS:
        print("⚡︎ ⚠︎ | color=orange")
        lines.append(f"Daemon unreachable (last state {age / 60:.0f} min ago)")
        menu_footer(lines)
        print("\n".join(["---"] + lines))
        return

    if status in ("searching", "offline", "unconfigured"):
        label = {
            "searching": "Bluetooth search…",
            "offline": "EcoFlow out of range or powered off",
            "unconfigured": "not configured: run ef_login.py",
        }[status]
        print("⚡︎ – | color=gray")
        lines.append(f"EcoFlow: {label}")
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
    else:  # idle: on AC power or no load
        title = f"🔌 {level:.0f}%"

    print(title + color)
    print("---")

    lines.append(f"{state.get('device', 'EcoFlow')} — {level:.0f} %")
    if mode == "discharging":
        remaining = fmt_minutes(state.get("remaining_time_discharging"))
        if remaining:
            lines.append(f"Remaining runtime: {remaining.replace(':', ' h ')}")
    elif mode == "charging":
        remaining = fmt_minutes(state.get("remaining_time_charging"))
        if remaining:
            lines.append(f"Fully charged in: {remaining.replace(':', ' h ')}")

    lines.append(
        f"Mac on EcoFlow: {'yes' if on_ecoflow else 'no'}"
        + (f" ({fmt_watts(state.get('ac_output_power'))})" if on_ecoflow else "")
    )
    lines.append("---")
    lines.append(f"Input: {fmt_watts(state.get('input_power'))}")
    lines.append(f"AC output: {fmt_watts(state.get('ac_output_power'))}")
    lines.append(f"USB-C output: {fmt_watts(state.get('usbc_output_power'))}")
    temp = state.get("cell_temperature")
    if isinstance(temp, (int, float)):
        lines.append(f"Cell temperature: {temp:.0f} °C")
    lines.append(f"Updated {age:.0f} s ago | color=gray")
    menu_footer(lines)
    print("\n".join(lines))


if __name__ == "__main__":
    main()
