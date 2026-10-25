#!/usr/bin/env python3
"""Measure the sidebar's width from an AX dump.

The sidebar is the leading pane of the window. Expanded, it is an `AXScrollArea` at
x=0; collapsed, it is a handful of `AXStaticText` rows with no container of its own
(the strip is drawn as plain text), so measuring only scroll areas reports "missing"
exactly when the collapse worked.

So: take every element at the leading edge that is narrower than a sidebar could be,
and report the rightmost edge among them. That covers both shapes and no window
chrome is wide-but-leading-edge.

Prints the width in points, or exits 1 when nothing qualifies.
"""

import json
import sys

# Anything narrower than this at the leading edge is the sidebar. The window is
# ~1180 pt wide, so a 60 pt ceiling cannot pick up a main-area view.
SIDEBAR_MAX_WIDTH = 260


def sidebar_width(path):
    try:
        with open(path) as handle:
            tree = json.load(handle)
    except (OSError, ValueError):
        return None
    right = 0
    for node in tree["nodes"]:
        frame = node.get("frame") or {}
        try:
            x, width = int(frame["x"]), int(frame["w"])
            height = int(frame["h"])
        except (KeyError, TypeError, ValueError):
            continue
        # At the leading edge, tall enough to be a row rather than the window's own
        # hairline, and narrow enough that it cannot be the main area.
        if x > 12 or width <= 0 or width > SIDEBAR_MAX_WIDTH or height < 10:
            continue
        right = max(right, x + width)
    return right or None


def main():
    if len(sys.argv) != 2:
        print("usage: sidebar-width.py AX_JSON", file=sys.stderr)
        return 2
    width = sidebar_width(sys.argv[1])
    if width is None:
        print(f"no sidebar container in {sys.argv[1]}", file=sys.stderr)
        return 1
    print(width)
    return 0


if __name__ == "__main__":
    sys.exit(main())
