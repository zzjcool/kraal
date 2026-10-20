#!/usr/bin/env python3
"""06 · 抓取真实协议 fixture（供 Swift 单测用）。

产出到 Fixtures/：
  welcome.json          endpoint.welcome.v1
  snapshot.json         shell.snapshot.v1
  surface_120x40.bin    PaneSurface 原始帧（含 tag）
  surface_120x40.txt    该帧解出的文本，便于人眼核对

    python3 06_capture_fixtures.py
    python3 06_capture_fixtures.py --host hw-nj   # 从远端抓

注意：surface/snapshot fixture 含本机真实的 workspace 名与路径。
如果要公开发布，请先用一次性环境生成，或手动脱敏。
"""

from __future__ import annotations

import argparse
import json
import os
import socket
import sys

import herdr_protocol as hp


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Capture Herdr protocol fixtures")
    parser.add_argument("--cols", type=int, default=120)
    parser.add_argument("--rows", type=int, default=40)
    parser.add_argument("--socket", default=os.path.expanduser(hp.SOCKET_PATH))
    parser.add_argument("--out", default="Fixtures")
    return parser.parse_args()


def capture(socket_path: str, cols: int, rows: int) -> tuple[dict, bytes] | None:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(15)
    sock.connect(socket_path)
    try:
        sock.sendall(hp.frame(hp.build_hello(cols, rows)))
        welcome: dict = {}
        surface_raw = b""
        for _ in range(16):
            body = hp.read_frame(sock)
            if body is None:
                break
            if body[0] == hp.SERVER_ENDPOINT_CONTROL:
                index = 1
                kind_len, index = hp.read_varint(body, index)
                kind = body[index:index + kind_len].decode()
                index += kind_len
                data_len, index = hp.read_varint(body, index)
                if kind == "endpoint.welcome.v1":
                    try:
                        welcome = json.loads(body[index:index + data_len].decode())
                    except json.JSONDecodeError as exc:
                        print(f"✗ welcome 解析失败: {exc}", file=sys.stderr)
                        return None
            elif body[0] == hp.SERVER_PANE_SURFACE:
                surface_raw = body
                break
        if not welcome or not surface_raw:
            return None
        return welcome, surface_raw
    finally:
        sock.close()


def write_bytes(path: str, data: bytes) -> bool:
    try:
        with open(path, "wb") as handle:
            handle.write(data)
        return True
    except OSError as exc:
        print(f"✗ 写入 {path} 失败: {exc}", file=sys.stderr)
        return False


def write_text(path: str, text: str) -> bool:
    try:
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(text)
        return True
    except OSError as exc:
        print(f"✗ 写入 {path} 失败: {exc}", file=sys.stderr)
        return False


def main() -> int:
    args = parse_args()
    try:
        os.makedirs(args.out, exist_ok=True)
    except OSError as exc:
        print(f"✗ 无法创建 {args.out}: {exc}", file=sys.stderr)
        return 1

    try:
        result = capture(args.socket, args.cols, args.rows)
    except (ConnectionRefusedError, TimeoutError, OSError) as exc:
        print(f"✗ 连接失败: {exc}", file=sys.stderr)
        return 1

    if result is None:
        print("✗ 抓取失败", file=sys.stderr)
        return 1

    welcome, surface_raw = result

    welcome_path = os.path.join(args.out, "welcome.json")
    if not write_text(welcome_path,
                      json.dumps(welcome, indent=2, ensure_ascii=False) + "\n"):
        return 1
    print(f"✓ {welcome_path}")

    surface = hp.decode_surface(surface_raw)
    name = f"surface_{args.cols}x{args.rows}"
    bin_path = os.path.join(args.out, f"{name}.bin")
    if not write_bytes(bin_path, surface_raw):
        return 1
    print(f"✓ {bin_path}  ({len(surface_raw)} 字节)")

    rows = hp.surface_text(surface["frame"])
    txt_path = os.path.join(args.out, f"{name}.txt")
    if not write_text(txt_path, "\n".join(r.rstrip() for r in rows) + "\n"):
        return 1
    print(f"✓ {txt_path}")

    meta = {
        "width": surface["frame"]["width"],
        "height": surface["frame"]["height"],
        "cells": len(surface["frame"]["cells"]),
        "panes": [
            {
                "pane_id": p["pane_id"],
                "rect": p["rect"],
                "inner_rect": p["inner_rect"],
                "focused": p["focused"],
            }
            for p in surface["panes"]
        ],
    }
    meta_path = os.path.join(args.out, f"{name}.meta.json")
    if not write_text(meta_path, json.dumps(meta, indent=2) + "\n"):
        return 1
    print(f"✓ {meta_path}")

    print(f"\n✅ 抓到 {meta['width']}×{meta['height']} = {meta['cells']} cells，"
          f"{len(meta['panes'])} 个 pane")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
