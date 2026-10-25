#!/usr/bin/env python3
"""Check that the footer sits inside the spaces pane, above the divider.

Upstream draws the footer at `workspace_area.bottom() - 1`
(`src/client/shell/sidebar.rs:379-381`), which is the bottom of the *top* pane — not
the bottom of the sidebar. Under both panes the controls would read as sidebar-wide,
and `menu` would sit below the agents list it has nothing to do with.

The check is geometric because the difference between the two placements is exactly
"which pane contains this row": both look plausible in isolation, and only the y
ordering against the divider separates them.

Prints `footer_y=<y> divider_y=<y>`, or exits 1 when either element is missing.
Exits 1 as well when the footer is at or below the divider.
"""

import json
import sys

FOOTER_ID = "sidebar.footer.new"
DIVIDER_ID = "sidebar.section.divider"


def locate(path):
    try:
        with open(path) as handle:
            tree = json.load(handle)
    except (OSError, ValueError):
        return None
    footer = None
    divider = None
    for node in tree["nodes"]:
        identifier = node.get("identifier") or ""
        frame = node.get("frame") or {}
        if "y" not in frame:
            continue
        if identifier == FOOTER_ID:
            footer = int(frame["y"])
        elif identifier == DIVIDER_ID:
            divider = int(frame["y"])
    if footer is None or divider is None:
        return None
    return footer, divider


def main():
    if len(sys.argv) != 2:
        print("usage: sidebar-footer-above-divider.py AX_JSON", file=sys.stderr)
        return 2
    found = locate(sys.argv[1])
    if found is None:
        print(f"no footer or divider in {sys.argv[1]}", file=sys.stderr)
        return 1
    footer, divider = found
    print(f"footer_y={footer} divider_y={divider}")
    return 0 if footer < divider else 1


if __name__ == "__main__":
    sys.exit(main())
