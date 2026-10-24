#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 zzjcool
"""Announce what a kitty graphics transmission actually was.

Exists for issue #105. The client decoded the graphics scene, measured it against
the cell grid, and then passed `Data()` to the renderer, so a pane with an image
drew nothing — and from outside that is indistinguishable from "the program never
sent an image". So the program sends one and records:

  * the exact bytes it wrote (proof the sequence left the program),
  * a marker file once the write completed, so the harness can tell "the program
    never sent anything" from "it sent it and nothing drew".

Usage: kitty-graphics-probe.py SECONDS OUTFILE
"""

import base64
import os
import select
import sys
import termios
import time
import tty

USAGE = "usage: kitty-graphics-probe.py SECONDS OUTFILE"

# Fixed so the cleanup at the end is unambiguous, and so two runs in one daemon
# cannot collide on the id.
IMAGE_ID = 4242

# Big enough to cover several cells, small enough to stay a handful of sequences.
WIDTH = 64
HEIGHT = 64


def transmit_sequence() -> bytes:
    """`a=T` (transmit and display) of a solid magenta RGBA rectangle."""
    pixel = bytes((0xFF, 0x00, 0xFF, 0xFF))
    payload = base64.b64encode(pixel * (WIDTH * HEIGHT))
    control = f"a=T,f=32,s={WIDTH},v={HEIGHT},i={IMAGE_ID},q=2".encode()
    # kitty caps a chunk at 4096 base64 bytes; `m=1` means "more follows".
    chunks = [payload[index : index + 4096] for index in range(0, len(payload), 4096)]
    out = b""
    for index, chunk in enumerate(chunks):
        more = 1 if index < len(chunks) - 1 else 0
        if index == 0:
            out += b"\x1b_G" + control + b",m=" + str(more).encode() + b";" + chunk + b"\x1b\\"
        else:
            out += b"\x1b_Gm=" + str(more).encode() + b";" + chunk + b"\x1b\\"
    return out


def parse_seconds(text: str) -> float:
    try:
        value = float(text)
    except ValueError:
        raise SystemExit(f"{USAGE}\nSECONDS must be a number, got {text!r}") from None
    if value <= 0:
        raise SystemExit(f"{USAGE}\nSECONDS must be positive, got {value}")
    return value


def main() -> int:
    if len(sys.argv) < 3:
        raise SystemExit(USAGE)
    seconds = parse_seconds(sys.argv[1])
    # The harness owns the path, but require it to be absolute anyway: a relative
    # one would be resolved against the pane's cwd and the marker would land
    # somewhere the harness never looks, turning "the probe wrote its marker" into
    # a flaky timeout.
    out_path = sys.argv[2]
    if not os.path.isabs(out_path):
        raise SystemExit(f"{USAGE}\nOUTFILE must be an absolute path, got {out_path!r}")

    stdin_fd = sys.stdin.fileno()
    saved = termios.tcgetattr(stdin_fd)
    tty.setraw(stdin_fd)
    try:
        # Clear first, so a run that fails to draw leaves an obviously blank
        # screen rather than the shell prompt to compare against.
        os.write(1, b"\x1b[2J\x1b[H")
        sequence = transmit_sequence()
        os.write(1, sequence)
        # The marker records the bytes written. Written *after* the write, so a
        # marker that exists means the sequence really left this process.
        with open(out_path, "w", encoding="utf-8") as out:
            out.write(f"sent={len(sequence)} bytes\n")
            out.write(repr(sequence[:64]) + "\n")
            out.flush()
        with open(out_path + ".ready", "w", encoding="utf-8") as marker:
            marker.write("image transmitted\n")

        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            readable, _, _ = select.select([stdin_fd], [], [], 0.2)
            if readable:
                os.read(stdin_fd, 4096)
        # Drop the image on the way out so it cannot leak into the next case, and
        # record that it happened. A control assertion ("no magenta pixels when the
        # image is gone") is only honest if the image was actually removed, and the
        # harness cannot see the screen without it.
        os.write(1, b"\x1b_Ga=d,d=A\x1b\\")
        with open(out_path + ".deleted", "w", encoding="utf-8") as marker:
            marker.write("image deleted\n")
    finally:
        termios.tcsetattr(stdin_fd, termios.TCSADRAIN, saved)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
