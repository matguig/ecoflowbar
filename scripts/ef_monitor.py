#!/usr/bin/env python3
"""EcoFlow monitoring daemon (River 3 Plus) over local Bluetooth.

Loop: BLE scan -> connect -> periodically write state.json (read by the
SwiftBar plugin) -> tiered actions based on the battery level:
  < notify %    : macOS notification
  < lowpower %  : low power mode (sudo pmset, via a dedicated sudoers entry)
  < shutdown %  : clean shutdown (opt-in, config actions.shutdown)
  > restore %   : back to normal mode (hysteresis)

Designed to run as a LaunchAgent (KeepAlive); logs to stderr.
"""

import asyncio
import logging
import os
import re
import subprocess
import sys
import threading
import time

import json

from common import (
    COMMAND_PATH,
    CONFIG_PATH,
    PROJECT_ROOT,
    HISTORY_PATH,
    LOG_PATH,
    STATE_PATH,
    load_config,
    write_history,
    write_state,
)

from bleak import BleakScanner  # noqa: E402
from bleak.exc import BleakError  # noqa: E402
import eflib  # noqa: E402

log = logging.getLogger("ef-monitor")

SCAN_TIMEOUT = 30       # max duration of a scan cycle before "searching" state
CONNECT_TIMEOUT = 30
RESCAN_DELAY = 10       # pause between two unsuccessful scan cycles


NOTIF_STRINGS = {
    "en": {
        "low_title": "Low EcoFlow battery",
        "low_body": "{level:.0f}% remaining{extra}",
        "autonomy_extra": " — {remaining} left",
        "eco_title": "EcoFlow",
        "eco_on": "Low power mode enabled",
        "eco_off": "Back to normal mode",
        "sudo_title": "EcoFlow — action unavailable",
        "sudo_body": "sudoers not configured: see README (config/sudoers-ecoflow)",
        "critical_title": "EcoFlow critical — shutdown imminent",
        "critical_body": "{level:.0f}%: the Mac will shut down cleanly in {grace}s "
                         "(plug in the EcoFlow to cancel)",
        "to_battery_title": "Switched to battery",
        "to_battery_body": "The EcoFlow now powers the Mac{extra}",
        "to_mains_title": "Back on AC power",
        "to_mains_body": "The EcoFlow is powered again",
        "temp_high_title": "EcoFlow — high temperature",
        "temp_high_body": "Cells at {temp:.0f} °C",
        "temp_cold_title": "EcoFlow — charging in the cold",
        "temp_cold_body": "Cells at {temp:.0f} °C: charging below 0 °C damages the battery",
    },
    "es": {
        "low_title": "Batería EcoFlow baja",
        "low_body": "{level:.0f}% restante{extra}",
        "autonomy_extra": " — quedan {remaining}",
        "eco_title": "EcoFlow",
        "eco_on": "Modo de ahorro activado",
        "eco_off": "Vuelta al modo normal",
        "sudo_title": "EcoFlow — acción no disponible",
        "sudo_body": "sudoers sin configurar: ver README (config/sudoers-ecoflow)",
        "critical_title": "EcoFlow crítica — apagado inminente",
        "critical_body": "{level:.0f}%: el Mac se apagará limpiamente en {grace}s "
                         "(enchufa la EcoFlow para cancelar)",
        "to_battery_title": "Cambiado a batería",
        "to_battery_body": "La EcoFlow ahora alimenta el Mac{extra}",
        "to_mains_title": "De vuelta a la red",
        "to_mains_body": "La EcoFlow vuelve a estar alimentada",
        "temp_high_title": "EcoFlow — temperatura alta",
        "temp_high_body": "Celdas a {temp:.0f} °C",
        "temp_cold_title": "EcoFlow — carga en frío",
        "temp_cold_body": "Celdas a {temp:.0f} °C: cargar bajo 0 °C daña la batería",
    },
    "fr": {
        "low_title": "Batterie EcoFlow faible",
        "low_body": "{level:.0f} % restants{extra}",
        "autonomy_extra": " — autonomie {remaining}",
        "eco_title": "EcoFlow",
        "eco_on": "Mode économie d'énergie activé",
        "eco_off": "Retour au mode normal",
        "sudo_title": "EcoFlow — action impossible",
        "sudo_body": "sudoers non configuré : voir README (config/sudoers-ecoflow)",
        "critical_title": "EcoFlow critique — extinction imminente",
        "critical_body": "{level:.0f} % : le Mac s'éteindra proprement dans {grace} s "
                         "(branchez l'EcoFlow pour annuler)",
        "to_battery_title": "Passage sur batterie",
        "to_battery_body": "L'EcoFlow alimente le Mac{extra}",
        "to_mains_title": "Retour secteur",
        "to_mains_body": "L'EcoFlow est de nouveau alimentée",
        "temp_high_title": "EcoFlow — température élevée",
        "temp_high_body": "Cellules à {temp:.0f} °C",
        "temp_cold_title": "EcoFlow — charge à froid",
        "temp_cold_body": "Cellules à {temp:.0f} °C : la charge sous 0 °C abîme la batterie",
    },
    "de": {
        "low_title": "EcoFlow-Akku fast leer",
        "low_body": "{level:.0f} % verbleibend{extra}",
        "autonomy_extra": " — noch {remaining}",
        "eco_title": "EcoFlow",
        "eco_on": "Stromsparmodus aktiviert",
        "eco_off": "Zurück im Normalmodus",
        "sudo_title": "EcoFlow — Aktion nicht möglich",
        "sudo_body": "sudoers nicht konfiguriert: siehe README (config/sudoers-ecoflow)",
        "critical_title": "EcoFlow kritisch — Herunterfahren steht bevor",
        "critical_body": "{level:.0f} %: der Mac fährt in {grace} s sauber herunter "
                         "(EcoFlow anschließen zum Abbrechen)",
        "to_battery_title": "Auf Akku gewechselt",
        "to_battery_body": "Die EcoFlow versorgt jetzt den Mac{extra}",
        "to_mains_title": "Wieder am Netz",
        "to_mains_body": "Die EcoFlow wird wieder versorgt",
        "temp_high_title": "EcoFlow — hohe Temperatur",
        "temp_high_body": "Zellen bei {temp:.0f} °C",
        "temp_cold_title": "EcoFlow — Laden bei Kälte",
        "temp_cold_body": "Zellen bei {temp:.0f} °C: Laden unter 0 °C schädigt den Akku",
    },
    "ja": {
        "low_title": "EcoFlowバッテリー残量低下",
        "low_body": "残り{level:.0f}%{extra}",
        "autonomy_extra" : " — あと{remaining}",
        "eco_title": "EcoFlow",
        "eco_on": "低電力モードを有効化",
        "eco_off": "通常モードに復帰",
        "sudo_title": "EcoFlow — 操作不可",
        "sudo_body": "sudoers未設定：README参照（config/sudoers-ecoflow）",
        "critical_title": "EcoFlow残量危機 — まもなくシステム終了",
        "critical_body": "{level:.0f}%：{grace}秒後にMacを正常終了します"
                         "（EcoFlowを電源に接続するとキャンセル）",
        "to_battery_title": "バッテリー駆動に切替",
        "to_battery_body": "EcoFlowがMacに給電中{extra}",
        "to_mains_title": "電源復帰",
        "to_mains_body": "EcoFlowへの給電が再開されました",
        "temp_high_title": "EcoFlow — 高温",
        "temp_high_body": "セル温度{temp:.0f}°C",
        "temp_cold_title": "EcoFlow — 低温充電",
        "temp_cold_body": "セル温度{temp:.0f}°C：0°C未満での充電は電池を傷めます",
    },
    "zh": {
        "low_title": "EcoFlow电池电量低",
        "low_body": "剩余{level:.0f}%{extra}",
        "autonomy_extra": " — 还可用{remaining}",
        "eco_title": "EcoFlow",
        "eco_on": "已启用节能模式",
        "eco_off": "已恢复正常模式",
        "sudo_title": "EcoFlow — 操作不可用",
        "sudo_body": "未配置sudoers：参见README（config/sudoers-ecoflow）",
        "critical_title": "EcoFlow电量危急 — 即将关机",
        "critical_body": "{level:.0f}%：Mac将在{grace}秒后正常关机"
                         "（接通EcoFlow电源可取消）",
        "to_battery_title": "已切换到电池供电",
        "to_battery_body": "EcoFlow正在为Mac供电{extra}",
        "to_mains_title": "市电已恢复",
        "to_mains_body": "EcoFlow已恢复供电",
        "temp_high_title": "EcoFlow — 温度过高",
        "temp_high_body": "电芯温度{temp:.0f}°C",
        "temp_cold_title": "EcoFlow — 低温充电",
        "temp_cold_body": "电芯温度{temp:.0f}°C：0°C以下充电会损伤电池",
    },
}

_language = {"value": "en"}


def refresh_language(config: dict) -> None:
    """Notification language: the app setting, otherwise the system one."""
    setting = config.get("language") or "auto"
    if setting in ("fr", "en"):
        _language["value"] = setting
        return
    # Same source as the app: the system's first interface language
    result = subprocess.run(
        ["defaults", "read", "-g", "AppleLanguages"], capture_output=True, text=True
    )
    codes = [c.lower() for c in re.findall(r'"([A-Za-z-]+)"', result.stdout)]
    supported_prefixes = ("en", "fr", "de", "es", "ja", "zh")
    first = next(
        (c for c in codes if any(c.startswith(p) for p in supported_prefixes)), "en"
    )
    supported = ("en", "fr", "de", "es", "ja", "zh")
    _language["value"] = next(
        (lang for lang in supported if first.startswith(lang)), "en"
    )


def T(key: str, **kwargs) -> str:
    table = NOTIF_STRINGS.get(_language["value"], NOTIF_STRINGS["en"])
    return table[key].format(**kwargs)


def notify(title: str, message: str, sound: bool = False) -> None:
    script = f'display notification "{message}" with title "{title}"'
    if sound:
        script += ' sound name "Submarine"'
    subprocess.run(["osascript", "-e", script], check=False, capture_output=True)


def sudo_run(*args: str) -> bool:
    """Run a command via sudo -n (requires a dedicated sudoers entry)."""
    result = subprocess.run(["sudo", "-n", *args], capture_output=True, text=True)
    if result.returncode != 0:
        log.warning("sudo %s failed: %s", " ".join(args), result.stderr.strip())
    return result.returncode == 0


class TierActions:
    """Tier state machine, with hysteresis."""

    def __init__(self, config: dict):
        self.config = config
        self.lowpower_on = None      # None = state unknown at startup
        self.notified_low = False
        self.sudo_warned = False
        self.shutdown_deadline = None

    def evaluate(self, state: dict) -> None:
        # Tiers reason on the effective % (usable window):
        # with a discharge limit at 10 %, a raw level of 15 % is critical
        level = state.get("battery_level_effective")
        if level is None:
            level = state.get("battery_level")
        if level is None:
            return

        # Master switch ("Automatic actions" checkbox in the menu)
        if not self.config.get("actions_enabled", True):
            self.shutdown_deadline = None
            self.notified_low = False
            if self.lowpower_on:
                self._set_lowpower(False)
            return

        thresholds = self.config["thresholds"]
        actions = self.config["actions"]
        discharging = state["power_mode"] == "discharging"
        relevant = discharging and (
            state.get("mac_on_ecoflow") or not self.config["require_mac_on_ecoflow"]
        )

        # Charging or idle: the discharge cycle is over, re-arm everything
        if not discharging:
            self.shutdown_deadline = None
            self.notified_low = False
            if self.lowpower_on:
                self._set_lowpower(False)
            return

        # "Eco mode as soon as on battery" option: without waiting for the threshold
        eco_on_battery = (
            actions["lowpower"] and actions.get("lowpower_on_battery") and relevant
        )
        if eco_on_battery and self.lowpower_on is not True:
            self._set_lowpower(True)

        # Eco mode hysteresis: only turn it off once back up to restore %
        # (unless the "on battery" option deliberately keeps it on)
        if level >= thresholds["restore"] and self.lowpower_on and not eco_on_battery:
            self._set_lowpower(False)

        if level > thresholds["notify"]:
            self.notified_low = False
            self.shutdown_deadline = None
            return

        if not relevant:
            self.shutdown_deadline = None
            return

        if actions["notify"] and level <= thresholds["notify"] and not self.notified_low:
            self.notified_low = True
            remaining = format_minutes(state.get("remaining_time_discharging_effective") or state.get("remaining_time_discharging"))
            extra = T("autonomy_extra", remaining=remaining) if remaining else ""
            notify(T("low_title"), T("low_body", level=level, extra=extra), sound=True)

        if actions["lowpower"] and level <= thresholds["lowpower"] and self.lowpower_on is not True:
            self._set_lowpower(True)

        if actions["shutdown"] and level <= thresholds["shutdown"]:
            self._handle_shutdown(level)
        else:
            self.shutdown_deadline = None

    def _set_lowpower(self, on: bool) -> None:
        if sudo_run("pmset", "-a", "lowpowermode", "1" if on else "0"):
            self.lowpower_on = on
            notify(T("eco_title"), T("eco_on") if on else T("eco_off"))
        elif not self.sudo_warned:
            self.sudo_warned = True
            notify(T("sudo_title"), T("sudo_body"))

    def _handle_shutdown(self, level: float) -> None:
        grace = self.config["shutdown_grace_seconds"]
        now = time.monotonic()
        if self.shutdown_deadline is None:
            self.shutdown_deadline = now + grace
            log.warning("Critical level (%.0f%%): shutting down in %d s", level, grace)
            notify(T("critical_title"), T("critical_body", level=level, grace=grace), sound=True)
        elif now >= self.shutdown_deadline:
            log.warning("Clean Mac shutdown (level %.0f%%)", level)
            # Pseudo-hibernation: snapshot the session then a graceful shutdown
            subprocess.run(
                ["/bin/bash", str(PROJECT_ROOT / "scripts" / "ef_hibernate.sh")],
                check=False,
                capture_output=True,
                timeout=120,
            )
            # Safety net if an app blocks the graceful shutdown
            time.sleep(60)
            sudo_run("shutdown", "-h", "now")


def format_minutes(minutes) -> str | None:
    if not minutes or minutes <= 0:
        return None
    return f"{int(minutes) // 60} h {int(minutes) % 60:02d}"


def read_device_state(device, config: dict) -> dict:
    def get(prop):
        return getattr(device, prop, None)

    battery_in = get("battery_input_power") or 0
    battery_out = get("battery_output_power") or 0
    in_sum = get("input_power") or 0
    out_sum = get("output_power") or 0
    # Effective percentage: level relative to the usable window
    # defined by the discharge (min) and charge (max) limits
    level = get("battery_level")
    limit_min = get("battery_charge_limit_min")
    limit_max = get("battery_charge_limit_max")
    effective = None
    if level is not None:
        low = limit_min or 0
        high = limit_max or 100
        span = high - low
        if span >= 5:
            effective = round(max(0.0, min(100.0, (level - low) / span * 100)), 1)
        else:
            effective = level

    # Effective runtime: the BMS estimates the time until 0 %, but the output
    # cuts off at the discharge limit — we scale its estimate to the actually
    # usable portion (keeps its discharge rate, losses included)
    remaining = get("remaining_time_discharging")
    remaining_effective = remaining
    if remaining and level and limit_min:
        if level > limit_min:
            remaining_effective = round(remaining * (level - limit_min) / level)
        else:
            remaining_effective = 0

    plugged = bool(get("plugged_in_ac")) or (get("ac_input_power") or 0) > 3
    # The BMS sensor (pow_get_bms) does not always report: fall back to the
    # overall input/output balance to classify the mode.
    # "plugged" = AC in passthrough: the battery is not discharging.
    if battery_in > 3:
        power_mode = "charging"
    elif battery_out > 3:
        power_mode = "discharging"
    elif in_sum - out_sum > 3:
        power_mode = "charging"
    elif out_sum - in_sum > 3:
        power_mode = "discharging"
    elif plugged:
        power_mode = "plugged"
    else:
        power_mode = "idle"

    ac_out = get("ac_output_power") or 0
    mac_on_ecoflow = bool(get("ac_ports")) and ac_out >= config["mac_watts_min"]

    return {
        "ts": time.time(),
        "status": "connected",
        "device": device.device,
        "sn": device.serial_number,
        "battery_level": level,
        "battery_level_effective": effective,
        "power_mode": power_mode,
        "mac_on_ecoflow": mac_on_ecoflow,
        "remaining_time_discharging": remaining,
        "remaining_time_discharging_effective": remaining_effective,
        "remaining_time_charging": get("remaining_time_charging"),
        "ac_input_power": get("ac_input_power"),
        "ac_output_power": ac_out,
        "input_power": in_sum,
        "output_power": out_sum,
        "usbc_output_power": get("usbc_output_power"),
        "dc_input_power": get("dc_input_power"),
        "cell_temperature": get("cell_temperature"),
        "plugged_in_ac": get("plugged_in_ac"),
        "ac_ports": get("ac_ports"),
        "battery_charge_limit_max": limit_max,
        "battery_charge_limit_min": limit_min,
    }


async def find_device(config: dict):
    """One scan cycle; returns the eflib Device or None."""
    target_sn = config.get("device_sn")
    result = {}
    done = asyncio.Event()

    def callback(ble_dev, adv_data):
        sn = eflib.sn_from_advertisement(adv_data)
        if sn is None or result:
            return
        sn = sn.decode("ASCII", errors="replace")
        if target_sn and sn != target_sn:
            return
        device = eflib.NewDevice(ble_dev, adv_data)
        if device is None or eflib.is_unsupported(device):
            return
        result["device"] = device
        done.set()

    scanner = BleakScanner(detection_callback=callback)
    await scanner.start()  # may raise BleakError (e.g. Bluetooth off/denied)
    try:
        await asyncio.wait_for(done.wait(), timeout=SCAN_TIMEOUT)
    except TimeoutError:
        pass
    finally:
        try:
            await scanner.stop()
        except Exception:
            pass
    return result.get("device")


class ModeWatcher:
    """Notifies AC/charge <-> battery switches (UPS event)."""

    def __init__(self, config: dict):
        self.config = config
        self.prev = None

    def evaluate(self, state: dict) -> None:
        mode = state["power_mode"]
        prev, self.prev = self.prev, mode
        if prev is None or prev == mode:
            return
        if not (self.config.get("actions_enabled", True) and self.config["actions"]["notify"]):
            return
        if mode == "discharging" and prev in ("plugged", "charging", "idle"):
            remaining = format_minutes(state.get("remaining_time_discharging_effective") or state.get("remaining_time_discharging"))
            extra = T("autonomy_extra", remaining=remaining) if remaining else ""
            notify(T("to_battery_title"), T("to_battery_body", extra=extra), sound=True)
        elif prev == "discharging" and mode in ("plugged", "charging"):
            notify(T("to_mains_title"), T("to_mains_body"))


class TempWatcher:
    """Cell temperature alert (outside the safe range)."""

    HIGH, HIGH_CLEAR = 45, 40
    LOW, LOW_CLEAR = 0, 2

    def __init__(self, config: dict):
        self.config = config
        self.warned_high = False
        self.warned_low = False

    def evaluate(self, state: dict) -> None:
        temp = state.get("cell_temperature")
        if temp is None:
            return
        if not (self.config.get("actions_enabled", True) and self.config["actions"]["notify"]):
            return
        if temp >= self.HIGH and not self.warned_high:
            self.warned_high = True
            notify(T("temp_high_title"), T("temp_high_body", temp=temp), sound=True)
        elif temp < self.HIGH_CLEAR:
            self.warned_high = False
        if temp <= self.LOW and state["power_mode"] == "charging" and not self.warned_low:
            self.warned_low = True
            notify(T("temp_cold_title"), T("temp_cold_body", temp=temp), sound=True)
        elif temp > self.LOW_CLEAR:
            self.warned_low = False


def read_cpu_power() -> float | None:
    """Internal CPU+GPU+ANE power (W) via powermetrics (sudoers required)."""
    try:
        result = subprocess.run(
            ["sudo", "-n", "/usr/bin/powermetrics",
             "-i", "500", "-n", "1", "--samplers", "cpu_power"],
            capture_output=True,
            text=True,
            timeout=15,
        )
    except subprocess.TimeoutExpired:
        return None
    if result.returncode != 0:
        return None
    for line in result.stdout.splitlines():
        if "Combined Power" in line:
            try:
                return float(line.split(":")[1].strip().split()[0]) / 1000.0
            except (IndexError, ValueError):
                return None
    return None


class HistoryRecorder:
    """Samples battery level and power draws (1/min, 24 h)."""

    INTERVAL = 60
    RETENTION = 24 * 3600

    def __init__(self):
        try:
            self.samples = json.loads(HISTORY_PATH.read_text())
        except (OSError, json.JSONDecodeError):
            self.samples = []
        self.last_ts = self.samples[-1]["ts"] if self.samples else 0
        self.last_cpu_w = None
        self.cpu_warned = False

    def maybe_record(self, state: dict) -> None:
        now = state["ts"]
        if state.get("battery_level") is None or now - self.last_ts < self.INTERVAL:
            return
        self.last_ts = now
        self.last_cpu_w = read_cpu_power()
        if self.last_cpu_w is None and not self.cpu_warned:
            self.cpu_warned = True
            log.info(
                "powermetrics unavailable (sudoers not configured?): "
                "no internal CPU measurement"
            )
        self.samples.append(
            {
                "ts": round(now),
                "level": state["battery_level"],
                "in_w": state.get("input_power") or 0,
                "out_w": state.get("output_power") or 0,
                # Mac power draw = AC output, only when it is plugged in
                "mac_w": state.get("ac_output_power")
                if state.get("mac_on_ecoflow")
                else None,
                "cpu_w": self.last_cpu_w,
                "mode": state["power_mode"],
            }
        )
        cutoff = now - self.RETENTION
        self.samples = [s for s in self.samples if s["ts"] >= cutoff]
        write_history(self.samples)


async def process_command(device) -> None:
    """Runs a one-shot command dropped by the app (command.json)."""
    if not COMMAND_PATH.exists():
        return
    try:
        command = json.loads(COMMAND_PATH.read_text())
    except (OSError, json.JSONDecodeError):
        command = None
    COMMAND_PATH.unlink(missing_ok=True)
    if not command:
        return
    action = command.get("action")
    try:
        if action == "set_ac":
            value = bool(command.get("value"))
            log.info("Command: AC output -> %s", "on" if value else "off")
            await device.enable_ac_ports(value)
        else:
            log.warning("Unknown command: %r", action)
    except Exception as exc:
        log.error("Command %s failed: %s", action, exc)


class ChargeLimitEnforcer:
    """Applies the charge/discharge limits (config) to the battery."""

    RETRY_SECONDS = 60
    LIMITS = (
        ("charge_limit_max", "battery_charge_limit_max", "set_battery_charge_limit_max"),
        ("charge_limit_min", "battery_charge_limit_min", "set_battery_charge_limit_min"),
    )

    def __init__(self, config: dict):
        self.config = config
        self.last_sent = {}

    async def evaluate(self, device, state: dict) -> None:
        for config_key, state_key, setter in self.LIMITS:
            target = self.config.get(config_key)
            current = state.get(state_key)
            if target is None or current is None:
                continue
            if abs(float(current) - float(target)) < 0.5:
                continue
            now = time.monotonic()
            if now - self.last_sent.get(config_key, 0.0) < self.RETRY_SECONDS:
                continue
            self.last_sent[config_key] = now
            try:
                log.info("%s: %s%% -> %s%%", config_key, current, target)
                await getattr(device, setter)(float(target))
            except Exception as exc:
                log.error("Setting %s failed: %s", config_key, exc)


def make_config_reloader(config: dict):
    """Hot-reloads config.json when its mtime changes (Settings menu)."""
    last_mtime = [None]

    def refresh() -> None:
        try:
            mtime = CONFIG_PATH.stat().st_mtime
        except OSError:
            return
        if mtime != last_mtime[0]:
            if last_mtime[0] is not None:
                config.clear()
                config.update(load_config())
                refresh_language(config)
                log.info("Configuration reloaded")
            last_mtime[0] = mtime

    return refresh


async def monitor_loop(config: dict) -> None:
    actions = TierActions(config)
    history = HistoryRecorder()
    mode_watcher = ModeWatcher(config)
    temp_watcher = TempWatcher(config)
    charge_limit = ChargeLimitEnforcer(config)
    refresh_config = make_config_reloader(config)
    refresh_config()
    bt_warned = False

    while True:
        refresh_config()
        write_state({"ts": time.time(), "status": "searching"})
        try:
            device = await find_device(config)
        except BleakError as exc:
            # Bluetooth off, or authorization revoked (common after an
            # ad-hoc dev rebuild changes the app's code signature). Don't
            # crash: surface a clear state and keep retrying.
            message = str(exc).lower()
            denied = any(
                word in message
                for word in ("authoriz", "not available", "denied", "unavailable")
            )
            if denied:
                if not bt_warned:
                    bt_warned = True
                    log.error("Bluetooth unavailable/denied: %s", exc)
                    log.error(
                        "Grant Bluetooth access in System Settings > Privacy & "
                        "Security > Bluetooth (enable EcoFlowBar), then it recovers "
                        "on its own."
                    )
                write_state({"ts": time.time(), "status": "bluetooth_denied"})
            else:
                log.error("Scan error: %s", exc)
                write_state({"ts": time.time(), "status": "offline"})
            await asyncio.sleep(RESCAN_DELAY)
            continue
        bt_warned = False
        if device is None:
            write_state({"ts": time.time(), "status": "offline"})
            await asyncio.sleep(RESCAN_DELAY)
            continue

        log.info("Found %s (SN %s), connecting…", device.device, device.serial_number)
        try:
            await device.connect(user_id=config["user_id"])
            await device.wait_connected(timeout=CONNECT_TIMEOUT)
        except Exception as exc:
            log.error("Connection failed: %s", exc)
            try:
                await device.disconnect()
            except Exception:
                pass
            await asyncio.sleep(RESCAN_DELAY)
            continue

        log.info("Connected to %s", device.device)
        try:
            while device.is_connected:
                refresh_config()
                state = read_device_state(device, config)
                history.maybe_record(state)
                state["mac_cpu_w"] = history.last_cpu_w
                write_state(state)
                actions.evaluate(state)
                mode_watcher.evaluate(state)
                temp_watcher.evaluate(state)
                await charge_limit.evaluate(device, state)
                await process_command(device)
                await asyncio.sleep(config["poll_seconds"])
        except Exception as exc:
            log.error("Error during monitoring: %s", exc)
        finally:
            try:
                await device.disconnect()
            except Exception:
                pass

        log.info("Disconnected, rescanning in %d s", RESCAN_DELAY)
        await asyncio.sleep(RESCAN_DELAY)


def watch_supervisor() -> None:
    """Supervised mode (launched by EcoFlowBar): the app holds our stdin open.
    EOF = the app has died (quit or crash) -> we stop immediately."""
    if os.environ.get("EF_SUPERVISED") != "1":
        return

    def run() -> None:
        # Read the raw fd (os.read), NOT sys.stdin.buffer: a buffered reader
        # would hold an _io lock and, if the main thread crashes, trigger a
        # fatal "_enter_buffered_busy" error at interpreter shutdown.
        try:
            while os.read(0, 4096):
                pass
        except OSError:
            pass
        log.info("Supervisor gone (stdin EOF): stopping the daemon")
        os._exit(0)

    threading.Thread(target=run, daemon=True).start()


def main() -> int:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
        stream=sys.stderr,
    )
    watch_supervisor()
    config = load_config()
    refresh_language(config)
    if not config.get("user_id"):
        log.error("user_id missing: run scripts/ef_login.py first")
        # LaunchAgent KeepAlive: we wait instead of spinning in a crash loop,
        # keeping state.json fresh so the plugin shows the right status
        for _ in range(10):
            write_state({"ts": time.time(), "status": "unconfigured"})
            time.sleep(30)
        return 1

    log.info("Starting — state: %s, log: %s", STATE_PATH, LOG_PATH)
    try:
        asyncio.run(monitor_loop(config))
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
