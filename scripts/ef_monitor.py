#!/usr/bin/env python3
"""Démon de surveillance EcoFlow (River 3 Plus) en Bluetooth local.

Boucle : scan BLE → connexion → écriture périodique de state.json (lu par le
plugin SwiftBar) → actions par paliers selon le niveau de batterie :
  < notify %    : notification macOS
  < lowpower %  : mode économie d'énergie (sudo pmset, via sudoers dédié)
  < shutdown %  : extinction propre (opt-in, config actions.shutdown)
  > restore %   : retour au mode normal (hystérésis)

Conçu pour tourner en LaunchAgent (KeepAlive) ; journalise sur stderr.
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
import eflib  # noqa: E402

log = logging.getLogger("ef-monitor")

SCAN_TIMEOUT = 30       # durée max d'un cycle de scan avant état "searching"
CONNECT_TIMEOUT = 30
RESCAN_DELAY = 10       # pause entre deux cycles de scan infructueux


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
}

_language = {"value": "en"}


def refresh_language(config: dict) -> None:
    """Langue des notifications : réglage app, sinon celle du système."""
    setting = config.get("language") or "auto"
    if setting in ("fr", "en"):
        _language["value"] = setting
        return
    # Même source que l'app : la première langue d'interface du système
    result = subprocess.run(
        ["defaults", "read", "-g", "AppleLanguages"], capture_output=True, text=True
    )
    match = re.search(r'"([A-Za-z-]+)"', result.stdout)
    first = (match.group(1) if match else "en").lower()
    _language["value"] = "fr" if first.startswith("fr") else "en"


def T(key: str, **kwargs) -> str:
    table = NOTIF_STRINGS.get(_language["value"], NOTIF_STRINGS["en"])
    return table[key].format(**kwargs)


def notify(title: str, message: str, sound: bool = False) -> None:
    script = f'display notification "{message}" with title "{title}"'
    if sound:
        script += ' sound name "Submarine"'
    subprocess.run(["osascript", "-e", script], check=False, capture_output=True)


def sudo_run(*args: str) -> bool:
    """Exécute une commande via sudo -n (exige une entrée sudoers dédiée)."""
    result = subprocess.run(["sudo", "-n", *args], capture_output=True, text=True)
    if result.returncode != 0:
        log.warning("sudo %s a échoué : %s", " ".join(args), result.stderr.strip())
    return result.returncode == 0


class TierActions:
    """Machine à états des paliers, avec hystérésis."""

    def __init__(self, config: dict):
        self.config = config
        self.lowpower_on = None      # None = état inconnu au démarrage
        self.notified_low = False
        self.sudo_warned = False
        self.shutdown_deadline = None

    def evaluate(self, state: dict) -> None:
        # Les paliers raisonnent sur le % effectif (fenêtre utilisable) :
        # avec une limite de décharge à 10 %, un niveau brut de 15 % est critique
        level = state.get("battery_level_effective")
        if level is None:
            level = state.get("battery_level")
        if level is None:
            return

        # Interrupteur général (case "Actions automatiques" du menu)
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

        # En charge ou au repos : le cycle de décharge est terminé, tout réarmer
        if not discharging:
            self.shutdown_deadline = None
            self.notified_low = False
            if self.lowpower_on:
                self._set_lowpower(False)
            return

        # Option "mode éco dès le passage sur batterie" : sans attendre le seuil
        eco_on_battery = (
            actions["lowpower"] and actions.get("lowpower_on_battery") and relevant
        )
        if eco_on_battery and self.lowpower_on is not True:
            self._set_lowpower(True)

        # Hystérésis du mode éco : ne le couper qu'une fois remonté à restore %
        # (sauf si l'option "dès la batterie" le maintient volontairement)
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
            log.warning("Niveau critique (%.0f%%) : extinction dans %d s", level, grace)
            notify(T("critical_title"), T("critical_body", level=level, grace=grace), sound=True)
        elif now >= self.shutdown_deadline:
            log.warning("Extinction propre du Mac (niveau %.0f%%)", level)
            # Pseudo-hibernation : snapshot de session puis extinction aimable
            subprocess.run(
                ["/bin/bash", str(PROJECT_ROOT / "scripts" / "ef_hibernate.sh")],
                check=False,
                capture_output=True,
                timeout=120,
            )
            # Filet de sécurité si une app bloque la fermeture aimable
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
    # Pourcentage effectif : niveau rapporté à la fenêtre utilisable
    # définie par les limites de décharge (min) et de charge (max)
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

    # Autonomie effective : le BMS estime le temps jusqu'à 0 %, mais la sortie
    # coupe à la limite de décharge — on rapporte son estimation à la portion
    # réellement utilisable (conserve son taux de décharge, pertes incluses)
    remaining = get("remaining_time_discharging")
    remaining_effective = remaining
    if remaining and level and limit_min:
        if level > limit_min:
            remaining_effective = round(remaining * (level - limit_min) / level)
        else:
            remaining_effective = 0

    plugged = bool(get("plugged_in_ac")) or (get("ac_input_power") or 0) > 3
    # Le capteur BMS (pow_get_bms) ne remonte pas toujours : repli sur le
    # bilan global entrées/sorties pour classer le mode.
    # "plugged" = secteur en passthrough : la batterie ne se décharge pas.
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
    """Un cycle de scan ; retourne le Device eflib ou None."""
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
    await scanner.start()
    try:
        await asyncio.wait_for(done.wait(), timeout=SCAN_TIMEOUT)
    except TimeoutError:
        pass
    finally:
        await scanner.stop()
    return result.get("device")


class ModeWatcher:
    """Notifie les bascules secteur/charge ↔ batterie (événement UPS)."""

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
    """Alerte température des cellules (hors plage de sécurité)."""

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
    """Puissance interne CPU+GPU+ANE (W) via powermetrics (sudoers requis)."""
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
    """Échantillonne niveau de batterie et consommations (1/min, 24 h)."""

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
                "powermetrics indisponible (sudoers non configuré ?) : "
                "pas de mesure CPU interne"
            )
        self.samples.append(
            {
                "ts": round(now),
                "level": state["battery_level"],
                "in_w": state.get("input_power") or 0,
                "out_w": state.get("output_power") or 0,
                # Conso du Mac = sortie AC, seulement quand il y est branché
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
    """Exécute une commande one-shot déposée par l'app (command.json)."""
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
            log.info("Commande : sortie AC → %s", "on" if value else "off")
            await device.enable_ac_ports(value)
        else:
            log.warning("Commande inconnue : %r", action)
    except Exception as exc:
        log.error("Commande %s échouée : %s", action, exc)


class ChargeLimitEnforcer:
    """Applique les limites de charge/décharge (config) à la batterie."""

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
                log.info("%s : %s%% → %s%%", config_key, current, target)
                await getattr(device, setter)(float(target))
            except Exception as exc:
                log.error("Réglage %s échoué : %s", config_key, exc)


def make_config_reloader(config: dict):
    """Recharge config.json à chaud quand son mtime change (menu Réglages)."""
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
                log.info("Configuration rechargée")
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

    while True:
        refresh_config()
        write_state({"ts": time.time(), "status": "searching"})
        device = await find_device(config)
        if device is None:
            write_state({"ts": time.time(), "status": "offline"})
            await asyncio.sleep(RESCAN_DELAY)
            continue

        log.info("Trouvé %s (SN %s), connexion…", device.device, device.serial_number)
        try:
            await device.connect(user_id=config["user_id"])
            await device.wait_connected(timeout=CONNECT_TIMEOUT)
        except Exception as exc:
            log.error("Connexion échouée : %s", exc)
            try:
                await device.disconnect()
            except Exception:
                pass
            await asyncio.sleep(RESCAN_DELAY)
            continue

        log.info("Connecté à %s", device.device)
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
            log.error("Erreur pendant la surveillance : %s", exc)
        finally:
            try:
                await device.disconnect()
            except Exception:
                pass

        log.info("Déconnecté, nouveau scan dans %d s", RESCAN_DELAY)
        await asyncio.sleep(RESCAN_DELAY)


def watch_supervisor() -> None:
    """Mode supervisé (lancé par EcoFlowBar) : l'app tient notre stdin ouvert.
    EOF = l'app est morte (quit ou crash) → on s'arrête immédiatement."""
    if os.environ.get("EF_SUPERVISED") != "1":
        return

    def run() -> None:
        try:
            while sys.stdin.buffer.read(4096):
                pass
        except Exception:
            pass
        log.info("Superviseur disparu (EOF stdin) : arrêt du démon")
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
        log.error("user_id absent : lancez d'abord scripts/ef_login.py")
        # LaunchAgent KeepAlive : on attend au lieu de boucler en crash-loop,
        # en gardant state.json frais pour que le plugin affiche le bon statut
        for _ in range(10):
            write_state({"ts": time.time(), "status": "unconfigured"})
            time.sleep(30)
        return 1

    log.info("Démarrage — état: %s, log: %s", STATE_PATH, LOG_PATH)
    try:
        asyncio.run(monitor_loop(config))
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
