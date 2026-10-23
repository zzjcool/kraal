#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 zzjcool
"""Record the raw bytes a program in a pane receives from the keyboard, then exit.

Exists for issue #92: `kraal-gui key --char escape` posted the letter `e` and
exited 0, so a case that meant to press ESC pressed `e` and reported success. From
the outside both are "the pane received a key"; only the program knows which.

This runs in the pane, switches to raw mode so nothing is line-buffered or
signal-handled, writes every read as a Python repr on its own line, and restores
the terminal on the way out.

Usage: key-probe.py SECONDS OUTFILE
"""

import os
import select
import sys
import termios
import time
import tty

USAGE = "usage: key-probe.py SECONDS OUTFILE"


def parse_seconds(text: str) -> float:
    """Read the duration, or say what was wrong with it.

    A bad duration must not silently become a default: a probe that exits
    immediately looks exactly like "the key never arrived".
    """
    try:
        value = float(text)
    except ValueError:
        raise SystemExit(f"{USAGE}\nSECONDS must be a number, got {text!r}") from None
    if value <= 0:
        raise SystemExit(f"{USAGE}\nSECONDS must be positive, got {value}")
    return value


def write_marker(path: str) -> None:
    """Publish that raw mode is on.

    The harness waits for this before sending keys. Sending them earlier is not a
    false pass but a false *failure*: in cooked mode the terminal interprets ESC
    itself and the byte never reaches the program, which looks exactly like the
    bug this probe detects.
    """
    try:
        with open(path, "w", encoding="utf-8") as marker:
            marker.write("raw mode\n")
    except OSError as error:
        raise SystemExit(f"{USAGE}\ncannot write marker {path!r}: {error}") from None


def main() -> int:
    if len(sys.argv) < 3:
        raise SystemExit(USAGE)
    seconds = parse_seconds(sys.argv[1])
    # The caller passes an absolute path it owns; nothing here guesses a name.
    out_path = sys.argv[2]

    stdin_fd = sys.stdin.fileno()
    saved = termios.tcgetattr(stdin_fd)
    tty.setraw(stdin_fd)
    write_marker(out_path + ".ready")
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
        termios.tcsetattr(stdin_fd, termios.TCSADRAIN, saved)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
