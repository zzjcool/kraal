#!/usr/bin/env python3
"""Report the two sidebar pane headings, by role.

The sidebar is two stacked panes: spaces (or machines, when several are configured)
above, agents below. Both headings being present at once is the claim of issue #115;
which of the two top titles appears is a separate question, answered by the machine
count (`render.rs:271-310`).

Prints `top=<name> agents=<0|1>`. Exits 1 when the top pane's heading is missing.
"""

import json
import sys

# Upstream picks the top title by machine count. Either identifies the same pane.
TOP_TITLES = ("spaces", "machines")
SIDEBAR_MAX_X = 260


def headings(path):
    try:
        with open(path) as handle:
            tree = json.load(handle)
    except (OSError, ValueError):
        return None
    top = None
    agents = False
    for node in tree["nodes"]:
        if node.get("role") != "AXStaticText":
            continue
        value = (node.get("value") or "").strip().lower()
        frame = node.get("frame") or {}
        # The sidebar is the leading 220 pt; anything further right is the terminal.
        if "x" not in frame or frame["x"] > SIDEBAR_MAX_X:
            continue
        if value in TOP_TITLES and top is None:
            top = value
        elif value == "agents":
            agents = True
    if top is None:
        return None
    return top, agents


def main():
    if len(sys.argv) != 2:
        print("usage: sidebar-pane-headings.py AX_JSON", file=sys.stderr)
        return 2
    found = headings(sys.argv[1])
    if found is None:
        print(f"no top-pane heading in {sys.argv[1]}", file=sys.stderr)
        return 1
    print(f"top={found[0]} agents={int(found[1])}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
