#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 zzjcool
"""05 · 远程（SSH）直连 herdr。

iOS 上没有本机 herdr，所有连接都是远程的。这条脚本证明：SSH exec 一条命令，
stdin/stdout 就是 endpoint 协议的二进制流，无需端口转发、无需中转服务。

    python3 05_remote_ssh.py --host hw-nj
    python3 05_remote_ssh.py --host workbox --session agents --cols 100 --rows 30

前置：`ssh <host> herdr --version` 可用（非交互认证，BatchMode）。
远端 herdr 需 >= 0.9.0（endpoint protocol generation 1）。
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time

import herdr_protocol as hp

REMOTE_BRIDGE_CMD = (
    "/bin/sh -c '"
    "candidate=$(command -v herdr 2>/dev/null || :); "
    'for p in "$candidate" "$HOME/.local/bin/herdr" /usr/bin/herdr '
    '/usr/local/bin/herdr /opt/homebrew/bin/herdr; do '
    'if [ -n "$p" ] && [ -x "$p" ]; then '
    'exec "$p" --session {session} remote-client-bridge; '
    "fi; done; exit 127'"
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Connect to a remote Herdr over SSH")
    parser.add_argument("--host", required=True, help="SSH target，如 hw-nj")
    parser.add_argument("--session", default="default")
    parser.add_argument("--cols", type=int, default=120)
    parser.add_argument("--rows", type=int, default=40)
    parser.add_argument("--timeout", type=float, default=20.0)
    return parser.parse_args()


def read_frame(stream) -> bytes | None:
    header = b""
    while len(header) < 4:
        chunk = stream.read(4 - len(header))
        if not chunk:
            return None
        header += chunk
    size = int.from_bytes(header, "little")
    if size == 0 or size > hp.MAX_GRAPHICS_FRAME_SIZE:
        raise ValueError(f"非法帧长度 {size}")
    body = b""
    while len(body) < size:
        chunk = stream.read(size - len(body))
        if not chunk:
            return None
        body += chunk
    return body


def main() -> int:
    args = parse_args()
    remote_cmd = REMOTE_BRIDGE_CMD.format(session=args.session)

    argv = [
        "ssh",
        "-T", "-C",
        "-o", "BatchMode=yes",
        "-o", "NumberOfPasswordPrompts=0",
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", "ConnectTimeout=10",
        "-o", "ServerAliveInterval=15",
        "-o", "ServerAliveCountMax=4",
        args.host,
        remote_cmd,
    ]
    print(f"→ ssh {args.host}  (session={args.session})")

    try:
        child = subprocess.Popen(
            argv,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except FileNotFoundError:
        print("✗ 找不到 ssh 命令", file=sys.stderr)
        return 1

    if child.stdin is None or child.stdout is None:
        print("✗ 无法建立管道", file=sys.stderr)
        return 1

    try:
        started = time.monotonic()
        child.stdin.write(hp.frame(hp.build_hello(args.cols, args.rows)))
        child.stdin.flush()
        print("→ hello 已发送，等待响应…")

        while time.monotonic() - started < args.timeout:
            body = read_frame(child.stdout)
            if body is None:
                stderr = b""
                if child.stderr is not None:
                    stderr = child.stderr.read(400)
                print(f"✗ 连接关闭: {stderr.decode('utf-8', 'replace')}", file=sys.stderr)
                return 1

            elapsed_ms = (time.monotonic() - started) * 1000
            tag = body[0]

            if tag != hp.SERVER_ENDPOINT_CONTROL:
                print(f"  [{elapsed_ms:6.0f} ms] tag={tag} {len(body)} 字节")
                continue

            index = 1
            kind_len, index = hp.read_varint(body, index)
            kind = body[index:index + kind_len].decode()
            index += kind_len
            data_len, index = hp.read_varint(body, index)
            data = body[index:index + data_len].decode()

            print(f"  [{elapsed_ms:6.0f} ms] {kind}  ({len(data)} 字节)")

            if kind == "endpoint.welcome.v1":
                try:
                    welcome = json.loads(data)
                except json.JSONDecodeError:
                    print("  ✗ welcome 不是合法 JSON", file=sys.stderr)
                    return 1
                print(f"       server_version: {welcome.get('server_version')}")
                generation = welcome.get("generation")
                if generation != hp.ENDPOINT_GENERATION:
                    print(f"       ⚠️ generation {generation} != {hp.ENDPOINT_GENERATION}")
                    return 1

            if kind == "shell.snapshot.v1":
                try:
                    snapshot = json.loads(data)
                except json.JSONDecodeError:
                    print("  ✗ snapshot 不是合法 JSON", file=sys.stderr)
                    return 1
                print(f"       workspaces={len(snapshot.get('workspaces', []))} "
                      f"tabs={len(snapshot.get('tabs', []))} "
                      f"panes={len(snapshot.get('panes', []))} "
                      f"agents={len(snapshot.get('agents', []))}")

            if tag == hp.SERVER_PANE_SURFACE or tag == hp.SERVER_PANE_SURFACE_PATCH:
                print(f"       {len(body)} 字节 cell 网格")
                print(f"\n✅ 远程连接成功（{(time.monotonic() - started) * 1000:.0f} ms 完成握手）")
                return 0

        print("✗ 超时", file=sys.stderr)
        return 1
    finally:
        child.kill()
        child.wait()


if __name__ == "__main__":
    raise SystemExit(main())
