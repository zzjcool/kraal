#!/usr/bin/env python3
"""Print the screen y of the sidebar's two pane headings.

The sidebar's panes are stacked, so "spaces above agents" is answerable from where
the two headings sit. Reading the AX frames is what makes that a measurement rather
than an inference from the layout code.

The *spaces* pane's title depends on the machine count, which is upstream's own
split (`render.rs:271-310`): `" spaces"` with one machine, `" machines"` with
several. Both are accepted here — the case is about the two panes being stacked, not
about which of the two titles the top pane happens to carry.

Prints `"<top_y> <agents_y>"`, or exits 1 when either is missing.
"""

import json
import sys

# The top pane's title. Upstream picks by machine count; either one identifies the
# pane this script cares about.
TOP_TITLES = ("spaces", "machines")
BOTTOM_TITLES = ("agents",)
SIDEBAR_MAX_X = 260


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
        if "y" not in frame or frame.get("x", 999) > SIDEBAR_MAX_X:
            continue
        if (value in TOP_TITLES or value in BOTTOM_TITLES) and value not in tops:
            tops[value] = frame["y"]
    top = next((tops[name] for name in TOP_TITLES if name in tops), None)
    bottom = next((tops[name] for name in BOTTOM_TITLES if name in tops), None)
    if top is None or bottom is None:
        return None
    try:
        return int(top), int(bottom)
    except (TypeError, ValueError):
        return None


def main():
    if len(sys.argv) != 2:
        print("usage: sidebar-heading-tops.py AX_JSON", file=sys.stderr)
        return 2
    tops = heading_tops(sys.argv[1])
    if tops is None:
        print(f"no both-heading frame in {sys.argv[1]}", file=sys.stderr)
        return 1
    print(f"{tops[0]} {tops[1]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
