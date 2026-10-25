#!/usr/bin/env python3
"""List the agents pane's rows as `<status>@<machine>`, top to bottom.

The pane shows every machine's agents (`endpoint_agents.rs:132-174`), and each row
carries its machine label. Reading both, in screen order, is what makes a
*ordering* claim checkable: the priority mode is supposed to interleave machines by
status, so the assertion is about which row is above which.

Row identity is taken from the row's own label plus the nearest preceding machine
text on the same pane, because a row's machine is rendered as part of it rather than
as a separate accessibility element.

Prints one `status@machine` per line. Exits 1 when no rows are found.
"""

import json
import sys

# The agents pane sits in the leading sidebar column.
SIDEBAR_MAX_X = 260
# Status words the daemon reports (schema AgentStatus). A row's status is rendered
# as text next to its name in this client.
STATUSES = ("blocked", "done", "working", "idle", "unknown")


def rows(path):
    try:
        with open(path) as handle:
            tree = json.load(handle)
    except (OSError, ValueError):
        return None
    texts = []
    for node in tree["nodes"]:
        frame = node.get("frame") or {}
        if "y" not in frame or frame.get("x", 999) > SIDEBAR_MAX_X:
            continue
        # Two shapes on screen, one per element kind:
        #
        #   the status glyph   -> AXUnknown, with the state in `AXDescription`
        #   the machine label  -> AXStaticText, with the text in AXValue
        #
        # Reading only AXStaticText is what made the first version report "no agent
        # rows" for a pane that plainly had two.
        if node.get("role") == "AXStaticText":
            text = (node.get("value") or "").strip()
        elif node.get("role") == "AXUnknown":
            text = (node.get("desc") or "").strip()
        else:
            continue
        if text:
            texts.append((int(frame["y"]), text))
    # Screen order is the whole point, so sort by y; the y is then dropped.
    texts.sort(key=lambda entry: entry[0])

    # Each agent row is several elements at the same or nearly the same y: the status
    # glyph (`AXUnknown`, state in AXDescription) and the row's texts, among them the
    # machine label. Pair a status with the machine name on its own row.
    #
    # A machine name also appears as the *workspace* rows' label in the pane above, so
    # a global "nearest name" pairing would attribute those. Rows are therefore grouped
    # by y first: an agent row's name sits within a few points of its glyph.
    # Only rows in the agents pane. The spaces pane above draws the same status words
    # on its workspace rows, so without the divider they would be counted as agents —
    # the first version reported five rows for a pane that had two.
    divider = None
    for node in tree["nodes"]:
        if (node.get("identifier") or "") == "sidebar.section.divider":
            frame = node.get("frame") or {}
            if "y" in frame:
                divider = int(frame["y"])
    status_rows = [
        (y, text) for y, text in texts
        if text.lower() in STATUSES and (divider is None or y > divider)
    ]
    if not status_rows:
        return None
    found = []
    for status_y, status_text in status_rows:
        machine = None
        for other_y, text in texts:
            if abs(other_y - status_y) > 6:
                continue
            for candidate in ("alpha-a", "alpha-b", "Local"):
                if candidate.lower() == text.lower():
                    machine = candidate
        found.append(f"{status_text.lower()}@{machine or '?'}")
    return found


def main():
    if len(sys.argv) != 2:
        print("usage: sidebar-agent-order.py AX_JSON", file=sys.stderr)
        return 2
    found = rows(sys.argv[1])
    if found is None:
        print(f"no agent rows in {sys.argv[1]}", file=sys.stderr)
        return 1
    print(" ".join(found))
    return 0


if __name__ == "__main__":
    sys.exit(main())
