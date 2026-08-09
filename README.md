# EcoFlowBar

Your EcoFlow battery in the Mac menu bar, just like a MacBook's battery
indicator — real time remaining, "is the Mac running on the EcoFlow?"
detection, and tiered automatic protection (notification, low power mode,
clean shutdown with session restore).

Works **100% locally over Bluetooth LE** — no Internet needed once set up —
thanks to the reverse-engineered protocol from
[ha-ef-ble](https://github.com/rabits/ha-ef-ble) (Apache 2.0, vendored in
`vendor/eflib`). Built and tested with a **River 3 Plus**; other models
supported by eflib should work too.

Interface available in **English, French, German, Japanese and Simplified
Chinese** (follows the system language, switchable in Settings).

## Install

Download the latest `EcoFlowBar-x.y.z.dmg` from the
[Releases](../../releases) page, drag the app to Applications, launch it.
The onboarding assistant handles everything: EcoFlow account sign-in,
Bluetooth pairing, and optional admin permissions — no terminal involved.
Requirements: macOS 14+ on Apple Silicon. Nothing else.

## Features

- **Menu bar indicator** — battery %, real time remaining, power draw;
  fully configurable (icon / percentage / time / watts).
- **Rich panel** — hero ring, combined 24 h history chart (battery level,
  wall draw, internal CPU power), live power flows, energy counters.
- **Tiered protection** (all thresholds adjustable, master switch):
  notification → low power mode (`pmset`) → clean shutdown, with hysteresis,
  computed on the *effective* battery window.
- **Charge window management** — write charge/discharge limits to the
  battery (80–85% daily extends LFP lifespan); displayed % and time
  remaining are relative to the usable window.
- **Pseudo-hibernation** — saves your session (apps, Safari tabs, tmux via
  tmux-resurrect), shuts down cleanly, restores everything at next login.
- **UPS events** — notifications on AC↔battery transitions and abnormal
  cell temperature; AC output remote switch.
- **Everything local** — the daemon talks BLE directly to the battery;
  the one-time EcoFlow sign-in (to obtain the account ID required by the
  protocol) is the only network call, straight to EcoFlow's servers.

## Architecture

```
EcoFlow ──BLE──▶ ef_monitor.py — Python daemon, child process of the app
                    │  (lives and dies with it; EOF watchdog on crash)
                    │  writes state.json + history.json, applies protection tiers
                    ▼
            EcoFlowBar.app — SwiftUI menu bar app (panel, settings window,
                             Dia-style onboarding, daemon supervisor)
```

Distributed builds embed the daemon and a standalone Python runtime inside
the app bundle (`Contents/Resources/daemon/`) — see
[RELEASING.md](RELEASING.md).

## Development

```bash
./setup.sh        # venv, build, launch agent for the app
```

The onboarding assistant opens on first launch. Useful bits:

- `release.sh <version>` — self-contained app + DMG (+ signing/notarization
  with the env vars documented inside).
- `assets/make_icon.swift` — the app icon, generated from code.
- `update-vendor.sh` — refresh `vendor/eflib` from upstream ha-ef-ble
  (if an EcoFlow firmware update changes the protocol).
- `swiftbar/ecoflow.5s.py` — alternative text display for
  [SwiftBar](https://github.com/swiftbar/SwiftBar).

## Troubleshooting

- Daemon log: `~/Library/Logs/ecoflow-monitor.log`; restart it from
  Settings → Advanced.
- Bluetooth permission is attributed to EcoFlowBar — if denied, re-enable
  it in System Settings → Privacy & Security → Bluetooth.
- Pairing can't find the battery? The daemon holds the BLE connection,
  which stops the battery from advertising; the onboarding and the
  Account settings pane suspend it automatically during scans.
- The BLE protocol is unofficial: an EcoFlow firmware update may break
  compatibility — run `update-vendor.sh` and rebuild.

## License & credits

BLE protocol library: [ha-ef-ble](https://github.com/rabits/ha-ef-ble)
(Apache 2.0), vendored with its license. Not affiliated with or endorsed
by EcoFlow Inc.
