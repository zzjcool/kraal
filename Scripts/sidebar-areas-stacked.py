#!/usr/bin/env python3
"""Check that the sidebar's two scrolling areas are stacked, not side by side.

Reads the `rects="x,y WxH ..."` line that `sidebar-scroll-areas.py` prints. Two panes
of one column start at different y values; two areas at the same y would be a
different layout (side-by-side panes, which is not what the sidebar is).

Prints `tops=[...] stacked`, or exits 1.
"""

import re
import sys

RECT = re.compile(r"(\d+),(\d+) (\d+)x(\d+)")


def tops(text):
    rects = RECT.findall(text)
    if len(rects) != 2:
        return None
    return sorted(int(rect[1]) for rect in rects)


def main():
    if len(sys.argv) != 2:
        print("usage: sidebar-areas-stacked.py AREAS_TXT", file=sys.stderr)
        return 2
    try:
        with open(sys.argv[1]) as handle:
            text = handle.read()
    except OSError as error:
        print(f"cannot read {sys.argv[1]}: {error}", file=sys.stderr)
        return 1
    found = tops(text)
    if found is None:
        print(f"need exactly two areas, got {len(RECT.findall(text))}", file=sys.stderr)
        return 1
    stacked = found[0] < found[1]
    print(f"tops={found} {'stacked' if stacked else 'same-row'}")
    return 0 if stacked else 1


if __name__ == "__main__":
    sys.exit(main())
