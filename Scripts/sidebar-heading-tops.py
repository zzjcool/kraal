#!/usr/bin/env python3
"""Print the screen y of the sidebar's two pane headings.

The sidebar's panes are stacked, so "spaces above agents" is answerable from where
the two headings sit. Reading the AX frames is what makes that a measurement rather
than an inference from the layout code.

Prints `"<spaces_y> <agents_y>"`, or exits 1 when either is missing.
"""

import json
import sys


def heading_tops(path):
    try:
        with open(path) as handle:
            tree = json.load(handle)
    except (OSError, ValueError):
        return None
    tops = {}
    for node in tree["nodes"]:
        if node.get("role") != "AXStaticText":
            continue
        value = (node.get("value") or "").strip().lower()
        frame = node.get("frame") or {}
        # The sidebar is the leading 220 pt; anything further right is the terminal.
        if "y" not in frame or frame.get("x", 999) > 260:
            continue
        if value in ("spaces", "agents") and value not in tops:
            tops[value] = frame["y"]
    if len(tops) != 2:
        return None
    try:
        return int(tops["spaces"]), int(tops["agents"])
    except (TypeError, ValueError):
        return None


def main():
    if len(sys.argv) != 2:
        print("usage: sidebar-heading-tops.py AX_JSON", file=sys.stderr)
        return 2
    tops = heading_tops(sys.argv[1])
    if tops is None:
        print(f"no both-headings frame in {sys.argv[1]}", file=sys.stderr)
        return 1
    print(f"{tops[0]} {tops[1]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
