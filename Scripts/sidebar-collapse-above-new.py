#!/usr/bin/env python3
"""Check that the collapse control is in the header, above the spaces pane's rows.

The herdr UI puts the collapse control on the `WORKSPACES` title row, next to the
window-level controls. In the footer it competed with `new` and `menu`, which act on
the space list rather than on the sidebar itself.

Measured as "the toggle's y is above `new`'s y": both are plausible positions until
you compare them, and the difference is exactly which row the control belongs to.

Prints `toggle_y=<y> new_y=<y>`; exits 1 when either is missing or the toggle is not
above.
"""

import json
import sys

TOGGLE_ID = "sidebar.collapse.toggle"
NEW_ID = "sidebar.footer.new"


def locate(path):
    try:
        with open(path) as handle:
            tree = json.load(handle)
    except (OSError, ValueError):
        return None
    toggle = None
    new = None
    for node in tree["nodes"]:
        identifier = node.get("identifier") or ""
        frame = node.get("frame") or {}
        if "y" not in frame:
            continue
        if identifier == TOGGLE_ID:
            toggle = int(frame["y"])
        elif identifier == NEW_ID:
            new = int(frame["y"])
    if toggle is None or new is None:
        return None
    return toggle, new


def main():
    if len(sys.argv) != 2:
        print("usage: sidebar-collapse-above-new.py AX_JSON", file=sys.stderr)
        return 2
    found = locate(sys.argv[1])
    if found is None:
        print(f"no collapse toggle or new button in {sys.argv[1]}", file=sys.stderr)
        return 1
    toggle, new = found
    print(f"toggle_y={toggle} new_y={new}")
    return 0 if toggle < new else 1


if __name__ == "__main__":
    sys.exit(main())
