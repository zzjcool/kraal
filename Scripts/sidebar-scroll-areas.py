#!/usr/bin/env python3
"""Report the sidebar's scrolling areas.

Upstream keeps a separate `workspace_scroll` and `agent_scroll`
(`src/client/shell/render.rs:239-240`, `state.rs:885-886`), so the two panes are
independent scrollers. In AppKit each becomes its own `AXScrollArea`, which makes
"independent scrolling" measurable without synthesising a wheel event: two areas in
the sidebar column means two containers, and a single shared `ScrollView` can only
ever produce one.

Prints `areas=<n> rects="x,y,wxh ..."` restricted to the sidebar column, or exits 1
when there are none.
"""

import json
import sys

# The sidebar is 220 pt wide on the leading edge. Filtering by a *maximum x* was not
# enough: the tab bar's scroller starts at x=227 (past the sidebar's right edge) but
# is 934 pt wide, so it slipped through. A sidebar scrolling area can never be wider
# than the sidebar, which is the property that actually distinguishes them.
SIDEBAR_MAX_WIDTH = 240


def scroll_areas(path):
    try:
        with open(path) as handle:
            tree = json.load(handle)
    except (OSError, ValueError):
        return None
    rects = []
    for node in tree["nodes"]:
        if node.get("role") != "AXScrollArea":
            continue
        frame = node.get("frame") or {}
        if "x" not in frame or frame.get("w", 9999) > SIDEBAR_MAX_WIDTH:
            continue
        try:
            rects.append(
                f"{int(frame['x'])},{int(frame['y'])}"
                f" {int(frame['w'])}x{int(frame['h'])}"
            )
        except (KeyError, TypeError, ValueError):
            continue
    if not rects:
        return None
    return rects


def main():
    if len(sys.argv) != 2:
        print("usage: sidebar-scroll-areas.py AX_JSON", file=sys.stderr)
        return 2
    found = scroll_areas(sys.argv[1])
    if found is None:
        print(f"no sidebar scroll area in {sys.argv[1]}", file=sys.stderr)
        return 1
    print(f"areas={len(found)} rects=\"{' '.join(found)}\"")
    return 0


if __name__ == "__main__":
    sys.exit(main())
