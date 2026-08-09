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
import subprocess
import sys
import time

import json

from common import (
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

        # Hystérésis du mode éco : ne le couper qu'une fois remonté à restore %
        if level >= thresholds["restore"] and self.lowpower_on:
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
            remaining = format_minutes(state.get("remaining_time_discharging"))
            extra = f" — autonomie {remaining}" if remaining else ""
            notify("Batterie EcoFlow faible", f"{level:.0f} % restants{extra}", sound=True)

        if actions["lowpower"] and level <= thresholds["lowpower"] and self.lowpower_on is not True:
            self._set_lowpower(True)

        if actions["shutdown"] and level <= thresholds["shutdown"]:
            self._handle_shutdown(level)
        else:
            self.shutdown_deadline = None

    def _set_lowpower(self, on: bool) -> None:
        if sudo_run("pmset", "-a", "lowpowermode", "1" if on else "0"):
            self.lowpower_on = on
            notify(
                "EcoFlow",
                "Mode économie d'énergie activé" if on else "Retour au mode normal",
            )
        elif not self.sudo_warned:
            self.sudo_warned = True
            notify(
                "EcoFlow — action impossible",
                "sudoers non configuré : voir README (config/sudoers-ecoflow)",
            )

    def _handle_shutdown(self, level: float) -> None:
        grace = self.config["shutdown_grace_seconds"]
        now = time.monotonic()
        if self.shutdown_deadline is None:
            self.shutdown_deadline = now + grace
            log.warning("Niveau critique (%.0f%%) : extinction dans %d s", level, grace)
            notify(
                "EcoFlow critique — extinction imminente",
                f"{level:.0f} % : le Mac s'éteindra proprement dans {grace} s "
                "(branchez l'EcoFlow pour annuler)",
                sound=True,
            )
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
        "battery_level": get("battery_level"),
        "power_mode": power_mode,
        "mac_on_ecoflow": mac_on_ecoflow,
        "remaining_time_discharging": get("remaining_time_discharging"),
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


class HistoryRecorder:
    """Échantillonne le niveau de batterie (1/min, 24 h glissantes)."""

    INTERVAL = 60
    RETENTION = 24 * 3600

    def __init__(self):
        try:
            self.samples = json.loads(HISTORY_PATH.read_text())
        except (OSError, json.JSONDecodeError):
            self.samples = []
        self.last_ts = self.samples[-1]["ts"] if self.samples else 0

    def maybe_record(self, state: dict) -> None:
        now = state["ts"]
        if state.get("battery_level") is None or now - self.last_ts < self.INTERVAL:
            return
        self.last_ts = now
        self.samples.append(
            {
                "ts": round(now),
                "level": state["battery_level"],
                "in_w": state.get("input_power") or 0,
                "out_w": state.get("output_power") or 0,
                "mode": state["power_mode"],
            }
        )
        cutoff = now - self.RETENTION
        self.samples = [s for s in self.samples if s["ts"] >= cutoff]
        write_history(self.samples)


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
                log.info("Configuration rechargée")
            last_mtime[0] = mtime

    return refresh


async def monitor_loop(config: dict) -> None:
    actions = TierActions(config)
    history = HistoryRecorder()
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
                write_state(state)
                history.maybe_record(state)
                actions.evaluate(state)
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


def main() -> int:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
        stream=sys.stderr,
    )
    config = load_config()
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
