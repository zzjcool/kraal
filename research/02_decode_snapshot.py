#!/usr/bin/env python3
"""02 · 解码 shell.snapshot.v1（侧边栏数据）。

这是侧边栏 UI 的全部数据来源：workspaces / tabs / panes / agents / commands。

    python3 02_decode_snapshot.py
    python3 02_decode_snapshot.py --json   # 输出原始 JSON
"""

from __future__ import annotations

import argparse
import json
import os
import socket
import sys

import herdr_protocol as hp


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Decode Herdr shell snapshot")
    parser.add_argument("--cols", type=int, default=120)
    parser.add_argument("--rows", type=int, default=40)
    parser.add_argument("--socket", default=os.path.expanduser(hp.SOCKET_PATH))
    parser.add_argument("--json", action="store_true", help="输出原始 snapshot JSON")
    return parser.parse_args()


def fetch_snapshot(socket_path: str, cols: int, rows: int) -> dict | None:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(10)
    sock.connect(socket_path)
    try:
        sock.sendall(hp.frame(hp.build_hello(cols, rows)))
        for _ in range(12):
            body = hp.read_frame(sock)
            if body is None:
                return None
            if body[0] != hp.SERVER_ENDPOINT_CONTROL:
                continue

            index = 1
            kind_len, index = hp.read_varint(body, index)
            kind = body[index:index + kind_len].decode()
            index += kind_len
            data_len, index = hp.read_varint(body, index)

            if kind != "shell.snapshot.v1":
                continue

            raw = body[index:index + data_len].decode()
            try:
                return json.loads(raw)
            except json.JSONDecodeError as exc:
                print(f"✗ snapshot 不是合法 JSON: {exc}", file=sys.stderr)
                return None
        return None
    finally:
        sock.close()


def status_dot(status: str) -> str:
    return {
        "blocked": "🔴",
        "working": "🟡",
        "done": "🟢",
        "idle": "⚪",
        "unknown": "⚫",
    }.get(status, "⚫")


def print_snapshot(snap: dict) -> None:
    print(f"boot_id   : {snap['boot_id']}")
    print(f"revision  : {snap['revision']}")
    print(f"focused   : ws={snap.get('focused_workspace_id')} "
          f"tab={snap.get('focused_tab_id')} "
          f"pane={snap.get('focused_pane_id')}")
    print()

    workspaces = {w["workspace_id"]: w for w in snap.get("workspaces", [])}
    tabs = {t["tab_id"]: t for t in snap.get("tabs", [])}
    panes = {p["pane_id"]: p for p in snap.get("panes", [])}
    agents = snap.get("agents", [])

    print(f"=== Workspaces（{len(workspaces)}）===")
    for ws in snap.get("workspaces", []):
        mark = "▸" if ws["focused"] else " "
        branch = f" [{ws['branch']}]" if ws.get("branch") else ""
        ahead_behind = ""
        if ws.get("git_ahead_behind"):
            ahead, behind = ws["git_ahead_behind"]
            ahead_behind = f" ↑{ahead}↓{behind}"
        worktree = " (worktree)" if ws.get("worktree") else ""
        print(f" {mark} {status_dot(ws['agent_status'])} "
              f"w{ws['number']} {ws['label']}{branch}{ahead_behind}{worktree}")
        if ws.get("tokens"):
            print(f"      tokens: {ws['tokens']}")

    print()
    print(f"=== Tabs（{len(tabs)}）===")
    for tab in snap.get("tabs", []):
        mark = "▸" if tab["focused"] else " "
        zoom = " [zoomed]" if tab.get("zoomed") else ""
        print(f" {mark} {status_dot(tab['agent_status'])} "
              f"{tab['tab_id']} #{tab['number']} {tab['label']}{zoom}")

    print()
    print(f"=== Panes（{len(panes)}）===")
    for pane in snap.get("panes", []):
        mark = "▸" if pane["focused"] else " "
        agent = f" ({pane['agent']})" if pane.get("agent") else ""
        title = pane.get("terminal_title_stripped") or ""
        print(f" {mark} {pane['pane_id']}  cwd={pane.get('cwd')}{agent}")
        if title:
            print(f"      title: {title}")

    print()
    print(f"=== Agents（{len(agents)}）===")
    for agent in agents:
        mark = "▸" if agent["focused"] else " "
        name = agent.get("display_agent") or agent.get("agent") or "?"
        title = agent.get("terminal_title_stripped") or agent.get("title") or ""
        print(f" {mark} {status_dot(agent['agent_status'])} "
              f"{agent['pane_id']} {name:12s} {title}")
        labels = agent.get("state_labels") or []
        if labels:
            print(f"      state_labels: {labels}")

    print()
    order = snap.get("agent_order") or []
    if order:
        print("=== Agent 排序 ===")
        print(f"  {' → '.join(order)}")
        print()

    commands = snap.get("commands") or []
    print(f"=== 自定义命令（{len(commands)}）===")
    for command in commands:
        print(f"  {command['binding_label']:18s} "
              f"[{command['action']}] "
              f"{command.get('description') or ''}")

    tab_bar = snap.get("tab_bar_right") or []
    if tab_bar:
        print()
        print(f"=== 右侧标签栏（分隔符 {snap.get('tab_bar_right_separator')!r}）===")
        for segment in tab_bar:
            print(f"  {'★' if segment['accent'] else ' '} {segment['text']}")


def main() -> int:
    args = parse_args()
    try:
        snap = fetch_snapshot(args.socket, args.cols, args.rows)
    except (ConnectionRefusedError, TimeoutError, OSError) as exc:
        print(f"✗ 连接失败: {exc}", file=sys.stderr)
        return 1

    if snap is None:
        print("✗ 未收到 shell.snapshot.v1", file=sys.stderr)
        return 1

    if args.json:
        print(json.dumps(snap, indent=2, ensure_ascii=False))
    else:
        print_snapshot(snap)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
