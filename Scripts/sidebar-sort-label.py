#!/usr/bin/env python3
"""Read the agents header's ordering label from an AX dump.

Upstream prints `"grouped"` or `"priority"` on the heading's right edge and treats
that text as the toggle (`agent_sidebar.rs:122-146`). SwiftUI puts the label of a
plain-text button in `AXDescription` rather than `AXValue`, so both are checked —
reading only one reports "missing" for a control that is on screen.

Prints the label, or exits 1 when the control is absent.
"""

import json
import sys

SORT_ID = "sidebar.agents.sort"
LABELS = ("grouped", "priority")


def sort_label(path):
    try:
        with open(path) as handle:
            tree = json.load(handle)
    except (OSError, ValueError):
        return None
    for node in tree["nodes"]:
        if node.get("identifier") != SORT_ID:
            continue
        # `desc` is where SwiftUI puts a text button's label; `value` is checked too
        # so the script keeps working if the label ever becomes real text.
        for key in ("desc", "value"):
            candidate = (node.get(key) or "").strip().lower()
            if candidate in LABELS:
                return candidate
    return None


def main():
    if len(sys.argv) != 2:
        print("usage: sidebar-sort-label.py AX_JSON", file=sys.stderr)
        return 2
    label = sort_label(sys.argv[1])
    if label is None:
        print(f"no agents sort label in {sys.argv[1]}", file=sys.stderr)
        return 1
    print(label)
    return 0


if __name__ == "__main__":
    sys.exit(main())
