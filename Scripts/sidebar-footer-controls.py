#!/usr/bin/env python3
"""Report whether the footer's two controls are present.

Upstream's footer is `" new"` on the left and `"menu"` on the right
(`src/client/shell/sidebar.rs:379-431`). This reads their accessibility identifiers
rather than their text: the labels are `Text` inside buttons, and at 9 pt the AX
tree exposes the identifier reliably while the label lands in different keys
depending on whether it is a `Menu` or a `Button`.

Prints `new=<0|1> menu=<0|1>`, or exits 1 when neither is found.
"""

import json
import sys

NEW_ID = "sidebar.footer.new"
MENU_ID = "sidebar.footer.menu"


def controls(path):
    try:
        with open(path) as handle:
            tree = json.load(handle)
    except (OSError, ValueError):
        return None
    found = {"new": False, "menu": False}
    for node in tree["nodes"]:
        identifier = node.get("identifier") or ""
        if identifier == NEW_ID:
            found["new"] = True
        elif identifier == MENU_ID:
            found["menu"] = True
    if not found["new"] and not found["menu"]:
        return None
    return found


def main():
    if len(sys.argv) != 2:
        print("usage: sidebar-footer-controls.py AX_JSON", file=sys.stderr)
        return 2
    found = controls(sys.argv[1])
    if found is None:
        print(f"no footer controls in {sys.argv[1]}", file=sys.stderr)
        return 1
    print(f"new={int(found['new'])} menu={int(found['menu'])}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
