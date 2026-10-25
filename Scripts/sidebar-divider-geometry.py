#!/usr/bin/env python3
"""Locate the sidebar's draggable divider and report where to grab it.

The divider carries an accessibility identifier (`sidebar.section.divider`) so the
GUI case can aim at its real rectangle. Two earlier versions estimated the position
from the two pane headings and both landed inside the spaces pane: the split is
`heights(total, ratio).spaces` tall, which is not a fixed offset from either heading,
and the window origin the driver reports disagreed with the app's own.

Prints `cx=<x> cy=<y> spaces_y=<y> agents_y=<y>`, all screen points. Exits 1 when the
divider or a heading is missing, so a case cannot silently measure nothing.
"""

import json
import sys

DIVIDER_ID = "sidebar.section.divider"


def locate(path):
    try:
        with open(path) as handle:
            tree = json.load(handle)
    except (OSError, ValueError):
        return None
    divider = None
    heads = {}
    for node in tree["nodes"]:
        if node.get("identifier") == DIVIDER_ID:
            divider = node.get("frame")
        if node.get("role") != "AXStaticText":
            continue
        value = (node.get("value") or "").strip().lower()
        frame = node.get("frame") or {}
        if "y" in frame and frame.get("x", 999) < 260 and value in ("spaces", "agents"):
            heads.setdefault(value, frame["y"])
    if divider is None or "y" not in divider or len(heads) != 2:
        return None
    try:
        # The frames come from the AX dump, so a key can be missing or null when a
        # view reports no geometry. Raising here would surface as a Python traceback
        # instead of the case's "cannot locate the divider".
        return {
            "cx": int(divider["x"] + divider["w"] / 2),
            "cy": int(divider["y"] + divider["h"] / 2),
            "spaces_y": int(heads["spaces"]),
            "agents_y": int(heads["agents"]),
        }
    except (KeyError, TypeError, ValueError):
        return None


def main():
    if len(sys.argv) != 2:
        print("usage: sidebar-divider-geometry.py AX_JSON", file=sys.stderr)
        return 2
    found = locate(sys.argv[1])
    if found is None:
        print(f"no divider or headings in {sys.argv[1]}", file=sys.stderr)
        return 1
    print(f"cx={found['cx']} cy={found['cy']} "
          f"spaces_y={found['spaces_y']} agents_y={found['agents_y']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
