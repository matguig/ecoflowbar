#!/usr/bin/env python3
"""Modify the ecoflow-monitor configuration (used by the SwiftBar menu).

Usage:
  ef_config.py set <dotted.key> <value>       e.g. set thresholds.notify 25
  ef_config.py toggle <dotted.key>            e.g. toggle actions.shutdown

The daemon hot-reloads the configuration (mtime watching).
"""

import sys

from common import load_config, save_config


def parse_value(raw: str):
    if raw.lower() in ("none", "null"):
        return None
    if raw.lower() in ("true", "false"):
        return raw.lower() == "true"
    try:
        return int(raw)
    except ValueError:
        try:
            return float(raw)
        except ValueError:
            return raw


def resolve(config: dict, dotted: str):
    *parents, leaf = dotted.split(".")
    node = config
    for part in parents:
        node = node.setdefault(part, {})
    return node, leaf


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2

    command, dotted = sys.argv[1], sys.argv[2]
    config = load_config()
    node, leaf = resolve(config, dotted)

    if command == "set":
        node[leaf] = parse_value(sys.argv[3])
    elif command == "toggle":
        node[leaf] = not bool(node.get(leaf))
    else:
        print(f"Unknown command: {command}", file=sys.stderr)
        return 2

    # Hysteresis consistency: without a margin between lowpower and restore, eco
    # mode would enable/disable in a loop around the threshold
    thresholds = config["thresholds"]
    if thresholds["restore"] < thresholds["lowpower"] + 3:
        thresholds["restore"] = thresholds["lowpower"] + 3

    save_config(config)
    print(f"{dotted} = {node[leaf]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
