#!/usr/bin/env python3
"""Regenerate the upstream palette fixture from herdr's Rust source.

The theme table in `Sources/KraalUI/Palette+Builtin.swift` is a transcription of
`src/app/state.rs:78-527` in the Rust daemon: 18 themes x 19 colours. Transcribing 342
numbers by hand gets one wrong, and a wrong colour has no failing test to announce it —
`nord` just looks slightly off, which nobody can report precisely.

So the numbers are pinned against a JSON copy of upstream's table instead. This script
writes that copy; `PaletteUpstreamTests` compares against it field by field.

Usage:
    Scripts/palette-verify.py --source <path-to-herdr>/src/app/state.rs \\
        --out Tests/KraalClientTests/Fixtures/upstream-palettes.json

Run it when upstream's palette changes, not on every build.
"""

import argparse
import json
import re
import sys

# Field order as declared on `struct Palette` in state.rs. Kept explicit rather than
# inferred, so a field added upstream shows up as a missing key instead of silently
# comparing fewer columns.
FIELDS = [
    "accent", "panel_bg", "sidebar_bg", "active_row_bg", "selection_bg",
    "surface0", "surface1", "surface_dim", "overlay0", "overlay1",
    "text", "subtext0", "mauve", "green", "yellow", "red", "blue", "teal", "peach",
]

# `Color::Reset` means "let the terminal decide" and maps to null, not to black.
NAMED = {
    "Reset": None,
    "Blue": 0x5B9BD5,
    "DarkGray": 0x444444,
    "Gray": 0x808080,
    "White": 0xFFFFFF,
}

CANONICAL = {
    "catppuccin": "catppuccin",
    "catppuccin_latte": "catppuccin-latte",
    "terminal": "terminal",
    "tokyo_night": "tokyo-night",
    "tokyo_night_day": "tokyo-night-day",
    "dracula": "dracula",
    "nord": "nord",
    "gruvbox": "gruvbox",
    "gruvbox_light": "gruvbox-light",
    "one_dark": "one-dark",
    "one_light": "one-light",
    "solarized": "solarized",
    "solarized_light": "solarized-light",
    "kanagawa": "kanagawa",
    "kanagawa_lotus": "kanagawa-lotus",
    "rose_pine": "rose-pine",
    "rose_pine_dawn": "rose-pine-dawn",
    "vesper": "vesper",
}


def parse_value(text):
    text = text.strip()
    match = re.match(r"Color::Rgb\((\d+),\s*(\d+),\s*(\d+)\)", text)
    if match:
        red, green, blue = (int(part) for part in match.groups())
        return (red << 16) | (green << 8) | blue
    match = re.match(r"Color::([A-Za-z]+)", text)
    if match:
        return NAMED.get(match.group(1))
    raise ValueError(f"unrecognised colour: {text}")


def parse(source):
    palettes = {}
    lines = source.splitlines()
    index = 0
    while index < len(lines):
        match = re.match(r"\s+pub fn ([a-z_]+)\(\) -> Self \{", lines[index])
        if not match:
            index += 1
            continue
        swift_name = match.group(1)
        if swift_name.startswith("test_"):
            index += 1
            continue
        values = {}
        index += 1
        while index < len(lines) and not re.match(r"\s+\}\s*$", lines[index]):
            field = re.match(r"\s+([a-z_0-9]+): (.*?),?(\s*//.*)?$", lines[index])
            if field and field.group(1) in FIELDS:
                values[field.group(1)] = parse_value(field.group(2))
            index += 1
        missing = [name for name in FIELDS if name not in values]
        if missing:
            raise ValueError(f"{swift_name}: missing {missing}")
        canonical = CANONICAL.get(swift_name)
        if canonical is None:
            raise ValueError(f"{swift_name}: no canonical theme name")
        palettes[canonical] = values
    return palettes


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    # Both reads report the path and give up, rather than raising a traceback: this is a
    # maintenance script run by hand, and a missing or moved upstream checkout is the
    # expected mistake, not an exceptional one.
    try:
        with open(args.source, encoding="utf-8") as handle:
            source = handle.read()
    except OSError as error:
        print(f"cannot read {args.source}: {error}", file=sys.stderr)
        return 1
    try:
        palettes = parse(source)
    except ValueError as error:
        print(f"cannot parse {args.source}: {error}", file=sys.stderr)
        return 1
    if len(palettes) < 18:
        print(f"only {len(palettes)} palettes parsed; expected 18", file=sys.stderr)
        return 1

    document = {
        "_source": "herdr src/app/state.rs (Apache-2.0), extracted by Scripts/palette-verify.py",
        "_note": "null means Color::Reset: let the terminal decide",
        "themes": palettes,
    }
    try:
        with open(args.out, "w", encoding="utf-8") as handle:
            json.dump(document, handle, indent=2, sort_keys=True)
            handle.write("\n")
    except OSError as error:
        print(f"cannot write {args.out}: {error}", file=sys.stderr)
        return 1
    print(f"wrote {len(palettes)} themes x {len(FIELDS)} colours to {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
