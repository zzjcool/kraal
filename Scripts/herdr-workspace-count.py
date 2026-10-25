#!/usr/bin/env python3
"""Count workspaces in `herdr workspace list` output.

Prints the count, or exits 1 when the payload is not the expected shape. Separate
from the case so a daemon that changes its JSON fails here, with a message about
JSON, rather than as a mystery "new created no workspace".
"""

import json
import sys


def count(path):
    try:
        with open(path) as handle:
            payload = json.load(handle)
    except (OSError, ValueError):
        return None
    workspaces = (payload.get("result") or {}).get("workspaces")
    return len(workspaces) if isinstance(workspaces, list) else None


def main():
    if len(sys.argv) != 2:
        print("usage: herdr-workspace-count.py JSON", file=sys.stderr)
        return 2
    found = count(sys.argv[1])
    if found is None:
        print(f"no workspaces array in {sys.argv[1]}", file=sys.stderr)
        return 1
    print(found)
    return 0


if __name__ == "__main__":
    sys.exit(main())
