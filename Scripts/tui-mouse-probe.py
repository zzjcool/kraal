#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 zzjcool
"""Record the raw bytes a TUI receives from the mouse, then exit.

Exists for issue #95: a click in a pane whose program reports the mouse either
never arrives or arrives malformed, and from the outside those look identical —
the program simply does nothing. This makes the program say what it got.

It asks for SGR mouse reporting (`?1000h ?1006h`) the same way a real TUI does,
writes every read as a Python repr on its own line, and restores the terminal on
the way out so the pane stays usable.

Usage: tui-mouse-probe.py SECONDS OUTFILE
"""

import os
import select
import sys
import termios
import time
import tty

MOUSE_ON = b"\x1b[?1000h\x1b[?1006h"
MOUSE_OFF = b"\x1b[?1000l\x1b[?1006l"


def main() -> int:
    seconds = float(sys.argv[1]) if len(sys.argv) > 1 else 30.0
    # The caller passes an absolute path it owns; nothing here guesses a name.
    out_path = sys.argv[2] if len(sys.argv) > 2 else "mouse-events.txt"

    stdin_fd = sys.stdin.fileno()
    saved = termios.tcgetattr(stdin_fd)
    tty.setraw(stdin_fd)
    os.write(1, MOUSE_ON)
    # Tell the harness the claim is on the wire. The daemon-side mouse state is not
    # readable over the CLI's JSON API (`session.snapshot` has no surface), and a
    # click sent before the program asked for the mouse would be a false negative —
    # the app is *correct* to not forward it.
    with open(out_path + ".ready", "w", encoding="utf-8") as marker:
        marker.write("mouse reporting claimed\n")
    deadline = time.monotonic() + seconds
    try:
        with open(out_path, "w", encoding="utf-8") as out:
            while time.monotonic() < deadline:
                readable, _, _ = select.select([stdin_fd], [], [], 0.2)
                if not readable:
                    continue
                chunk = os.read(stdin_fd, 4096)
                if not chunk:
                    break
                out.write(repr(chunk) + "\n")
                out.flush()
    finally:
        os.write(1, MOUSE_OFF)
        termios.tcsetattr(stdin_fd, termios.TCSADRAIN, saved)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
