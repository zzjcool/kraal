#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 zzjcool
"""04 · ANSI 与权威 cell 网格的一致性校验（整个方案的地基）。

核心假设：herdr 通过 `terminal attach` 输出的 ANSI 是标准 VT 序列，
任何正确的 VT 模拟器解析后，结果应与 herdr 自己渲染的 PaneSurface 完全一致。
如果这个假设成立，我们就可以把 pane 内容交给 Ghostty 渲染，而不必自己实现终端。

做法：
  1. endpoint 连接 → PaneSurface → 取目标 pane 的 inner_rect（内容区尺寸）
  2. terminal attach 连接 → 拿到该 pane 的 ANSI 字节流
  3. 用 pyte（标准 VT 模拟器）解析 ANSI
  4. 与 PaneSurface 中 inner_rect 区域的文本逐行比对

    python3 04_ansi_vs_surface.py
    python3 04_ansi_vs_surface.py --pane wP:p8
    python3 04_ansi_vs_surface.py --save-ansi out.ansi

依赖：pyte（见 requirements.txt）
"""

from __future__ import annotations

import argparse
import importlib
import json
import os
import socket
import subprocess
import sys
import time
import types
import unicodedata

import herdr_protocol as hp


def load_pyte() -> types.ModuleType | None:
    """延迟导入 pyte，避免在未安装时产生静态分析噪音。"""
    try:
        return importlib.import_module("pyte")
    except ModuleNotFoundError:
        print("✗ 需要 pyte: pip install -r requirements.txt", file=sys.stderr)
        return None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Compare Herdr ANSI against its own surface",
    )
    parser.add_argument("--cols", type=int, default=120)
    parser.add_argument("--rows", type=int, default=40)
    parser.add_argument("--pane", help="目标 pane_id，默认取 focused pane")
    parser.add_argument("--socket", default=os.path.expanduser(hp.SOCKET_PATH))
    parser.add_argument("--save-ansi", metavar="PATH", help="把抓到的 ANSI 写入文件")
    return parser.parse_args()


# --------------------------------------------------------------------------
# 步骤 1：拿 PaneSurface
# --------------------------------------------------------------------------

def fetch_surface(socket_path: str, cols: int, rows: int) -> dict | None:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(15)
    sock.connect(socket_path)
    try:
        sock.sendall(hp.frame(hp.build_hello(cols, rows)))
        for _ in range(16):
            body = hp.read_frame(sock)
            if body is None:
                return None
            if body[0] == hp.SERVER_PANE_SURFACE:
                return hp.decode_surface(body)
        return None
    finally:
        sock.close()


# --------------------------------------------------------------------------
# 步骤 2：拿 ANSI
# --------------------------------------------------------------------------

def list_panes() -> dict[str, dict]:
    """通过 herdr CLI 取 pane → terminal_id 映射。"""
    result = subprocess.run(
        ["herdr", "pane", "list"],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        return {}
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError:
        return {}
    return {p["pane_id"]: p for p in payload.get("result", {}).get("panes", [])}


def fetch_ansi(terminal_id: str, cols: int, rows: int) -> bytes | None:
    """terminal attach 握手 → 收集 TerminalFrame 的 ANSI 字节。"""
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(10)
    sock.connect(os.path.expanduser(hp.SOCKET_PATH))
    try:
        # TerminalHello{version, cols, rows, cell_w, cell_h, pixel_mouse}
        hello = (
            bytes([hp.CLIENT_TERMINAL_HELLO])
            + hp.varint(22)
            + hp.varint(cols)
            + hp.varint(rows)
            + hp.varint(10)
            + hp.varint(20)
            + b"\x00"
        )
        sock.sendall(hp.frame(hello))

        welcome = hp.read_frame(sock)
        if welcome is None or welcome[0] != hp.SERVER_WELCOME:
            return None

        # AttachTerminal{terminal_id, takeover: bool} → tag 5
        sock.sendall(
            hp.frame(bytes([hp.CLIENT_ATTACH_TERMINAL])
                     + hp.bstr(terminal_id)
                     + b"\x01")
        )

        buf = b""
        deadline = time.monotonic() + 2.5
        sock.settimeout(0.2)
        while time.monotonic() < deadline:
            try:
                body = hp.read_frame(sock)
            except TimeoutError:
                continue
            if body is None:
                break
            if body[0] == hp.SERVER_CLIENT_SHELL_ERROR:
                print(f"✗ attach 被拒: {body[1:180]!r}", file=sys.stderr)
                return None
            if body[0] != hp.SERVER_TERMINAL:
                continue

            index = 1
            _seq, index = hp.read_varint(body, index)
            _w, index = hp.read_varint(body, index)
            _h, index = hp.read_varint(body, index)
            index += 1  # full: bool
            length, index = hp.read_varint(body, index)
            buf += body[index:index + length]

        return buf or None
    finally:
        sock.close()


def save_ansi(path: str, data: bytes) -> bool:
    try:
        with open(path, "wb") as handle:
            handle.write(data)
        return True
    except OSError as exc:
        print(f"✗ 写文件失败 {path}: {exc}", file=sys.stderr)
        return False


# --------------------------------------------------------------------------
# 步骤 3：比对
# --------------------------------------------------------------------------

def compare(
    surface: dict,
    pane_id: str,
    ansi: bytes,
    pyte: types.ModuleType,
) -> tuple[int, int]:
    """返回 (真实不一致行数, 仅归一化不同的行数)。pane 不存在时返回 (-1, 0)。"""
    pane = next((p for p in surface["panes"] if p["pane_id"] == pane_id), None)
    if pane is None:
        print(f"✗ PaneSurface 里没有 {pane_id}", file=sys.stderr)
        return -1, 0

    ix, iy, iw, ih = pane["inner_rect"]
    print(f"目标 pane : {pane_id}")
    print(f"  rect      : {pane['rect']}")
    print(f"  inner_rect: {pane['inner_rect']}  ← 内容区 {iw}×{ih}")

    # 按列索引取 pane 区域；不能用字符串下标（宽字符 1 字符占 2 列）
    surface_columns = hp.surface_columns(surface["frame"])

    screen = pyte.Screen(iw, ih)
    pyte.ByteStream(screen).feed(ansi)

    diffs = 0
    normalization_only = 0
    for r in range(ih):
        surface_line = hp.join_columns(surface_columns[iy + r][ix:ix + iw]).rstrip()
        ansi_line = screen.display[r].rstrip()
        if surface_line == ansi_line:
            continue

        # 组合字符（如 e + U+0301 vs é）只差归一化形式，视觉上完全等价。
        # 这不是渲染差异：Ghostty 会把组合序列整理成多个 glyph，结果一致。
        if unicodedata.normalize("NFC", surface_line) == unicodedata.normalize("NFC", ansi_line):
            normalization_only += 1
            continue

        diffs += 1
        if diffs <= 6:
            print(f"\n--- 行 {r} 不一致 ---")
            print(f"  surface: {surface_line[:150]!r}")
            print(f"  pyte   : {ansi_line[:150]!r}")

    if normalization_only:
        print(f"\n注：{normalization_only} 行仅 Unicode 归一化形式不同（视觉等价，不计入差异）")

    return diffs, normalization_only


def main() -> int:
    args = parse_args()

    pyte = load_pyte()
    if pyte is None:
        return 1

    try:
        surface = fetch_surface(args.socket, args.cols, args.rows)
    except (ConnectionRefusedError, TimeoutError, OSError) as exc:
        print(f"✗ 连接失败: {exc}", file=sys.stderr)
        return 1
    if surface is None:
        print("✗ 未收到 PaneSurface", file=sys.stderr)
        return 1

    pane_id = args.pane
    if pane_id is None:
        focused = next((p for p in surface["panes"] if p["focused"]), None)
        if focused is None:
            print("✗ PaneSurface 里没有 focused pane", file=sys.stderr)
            return 1
        pane_id = focused["pane_id"]

    panes = list_panes()
    if pane_id not in panes:
        print(f"✗ 找不到 pane {pane_id}", file=sys.stderr)
        return 1

    terminal_id = panes[pane_id]["terminal_id"]
    pane = next(p for p in surface["panes"] if p["pane_id"] == pane_id)
    _, _, iw, ih = pane["inner_rect"]

    print(f"ANSI 源   : {terminal_id}  (以 {iw}×{ih} attach)")
    print()

    try:
        ansi = fetch_ansi(terminal_id, iw, ih)
    except (ConnectionRefusedError, TimeoutError, OSError) as exc:
        print(f"✗ attach 失败: {exc}", file=sys.stderr)
        return 1

    if not ansi:
        print("✗ 未收到 ANSI 帧", file=sys.stderr)
        return 1

    if args.save_ansi and save_ansi(args.save_ansi, ansi):
        print(f"ANSI 已保存: {args.save_ansi}")

    print(f"ANSI      : {len(ansi)} 字节")
    print()

    diffs, normalization_only = compare(surface, pane_id, ansi, pyte)
    if diffs < 0:
        return 1

    if diffs == 0:
        print(f"\n✅ {ih}/{ih} 行一致" + (f"（其中 {normalization_only} 行为 Unicode 归一化等价）" if normalization_only else ""))
        print("   → herdr 的 ANSI 是标准 VT 序列，可交给 Ghostty 渲染")
        return 0

    print(f"\n⚠️  {diffs}/{ih} 行不一致")
    print("   常见原因：attach 的 cols/rows 与 inner_rect 不匹配（会触发远端 resize）")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
