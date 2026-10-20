#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 zzjcool
"""03 · 解码 PaneSurface（cell 网格 + 分屏几何）。

这是"自己画 cell"路线所需的全部数据。它也提供 pane 的 inner_rect，
用于给 Ghostty 视图计算位置和尺寸。

    python3 03_decode_surface.py
    python3 03_decode_surface.py --screenshot   # 打印整屏文本
    python3 03_decode_surface.py --dump-panes   # 只打印几何信息
"""

from __future__ import annotations

import argparse
import os
import socket
import sys
import time

import herdr_protocol as hp


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Decode Herdr PaneSurface")
    parser.add_argument("--cols", type=int, default=120)
    parser.add_argument("--rows", type=int, default=40)
    parser.add_argument("--socket", default=os.path.expanduser(hp.SOCKET_PATH))
    parser.add_argument("--screenshot", action="store_true", help="打印整屏文本")
    parser.add_argument("--dump-panes", action="store_true", help="打印 pane 几何")
    return parser.parse_args()


def fetch_surface(socket_path: str, cols: int, rows: int) -> tuple[dict, float] | None:
    """返回 (解码后的 surface, 从发 hello 到收到 surface 的毫秒数)。"""
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(15)
    sock.connect(socket_path)
    try:
        started = time.monotonic()
        sock.sendall(hp.frame(hp.build_hello(cols, rows)))

        for _ in range(16):
            body = hp.read_frame(sock)
            if body is None:
                return None
            if body[0] == hp.SERVER_PANE_SURFACE:
                elapsed_ms = (time.monotonic() - started) * 1000
                return hp.decode_surface(body), elapsed_ms
            if body[0] == hp.SERVER_CLIENT_SHELL_ERROR:
                print(f"✗ 服务端错误: {body[1:200]!r}", file=sys.stderr)
                return None
        return None
    finally:
        sock.close()


def dump_panes(surface: dict) -> None:
    frame = surface["frame"]
    print(f"整屏: {frame['width']} × {frame['height']} "
          f"= {len(frame['cells'])} cells")
    print(f"boot: {surface['boot_id']}")
    print(f"revision: projection={surface['projection_revision']} "
          f"surface={surface['surface_revision']}")
    print()
    print(f"=== Panes（{len(surface['panes'])}）===")
    for pane in surface["panes"]:
        x, y, w, h = pane["rect"]
        ix, iy, iw, ih = pane["inner_rect"]
        print(f"  {pane['pane_id']}"
              f"{'  ← focused' if pane['focused'] else ''}")
        print(f"      rect       : x={x} y={y} w={w} h={h}")
        print(f"      inner_rect : x={ix} y={iy} w={iw} h={ih}   ← 内容区")
        print(f"      mouse_reporting: {pane['mouse_reporting']}"
              f"  sgr_pixel_mouse: {pane['sgr_pixel_mouse']}")
        print(f"      alternate_screen: {pane['alternate_screen_active']}")
        print(f"      pixel_size : {pane['pixel_width']}×{pane['pixel_height']}")
        if pane["scroll"]:
            scroll = pane["scroll"]
            print(f"      scroll     : {scroll['offset']}/{scroll['max']} "
                  f"(viewport {scroll['rows']} 行)")
        print()


def main() -> int:
    args = parse_args()
    try:
        result = fetch_surface(args.socket, args.cols, args.rows)
    except (ConnectionRefusedError, TimeoutError, OSError) as exc:
        print(f"✗ 连接失败: {exc}", file=sys.stderr)
        return 1

    if result is None:
        print("✗ 未收到 PaneSurface", file=sys.stderr)
        return 1

    surface, elapsed_ms = result
    frame = surface["frame"]

    print(f"✅ PaneSurface 到手：{elapsed_ms:.0f} ms")
    print()

    if args.dump_panes:
        dump_panes(surface)
        return 0

    print(f"整屏: {frame['width']} × {frame['height']} "
          f"= {len(frame['cells'])} cells")
    print(f"panes: {len(surface['panes'])}")
    for pane in surface["panes"]:
        ix, iy, iw, ih = pane["inner_rect"]
        print(f"  {pane['pane_id']}  inner_rect=({ix},{iy},{iw}×{ih})"
              f"{'  focused' if pane['focused'] else ''}")
    cursor = frame["cursor"]
    if cursor:
        print(f"cursor: ({cursor['x']}, {cursor['y']}) "
              f"visible={cursor['visible']}")
    print()

    if args.screenshot:
        for row_index, line in enumerate(hp.surface_text(frame)):
            print(f"{row_index:2d}|{line.rstrip()}")
    else:
        rows = hp.surface_text(frame)
        print("--- 前 8 行 ---")
        for row_index, line in enumerate(rows[:8]):
            print(f"{row_index:2d}|{line.rstrip()}")
        print("   ...")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
