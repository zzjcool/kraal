#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 zzjcool
"""01 · 握手：连接本机 herdr-client.sock，完成 endpoint.hello.v1 → welcome。

验证：服务端返回 endpoint.welcome.v1，且 generation 为 1。

    python3 01_handshake.py
    python3 01_handshake.py --cols 100 --rows 30
"""

from __future__ import annotations

import argparse
import json
import os
import socket
import sys

import herdr_protocol as hp


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Herdr endpoint handshake probe")
    parser.add_argument("--cols", type=int, default=120)
    parser.add_argument("--rows", type=int, default=40)
    parser.add_argument("--socket", default=os.path.expanduser(hp.SOCKET_PATH))
    return parser.parse_args()


def print_welcome(data: str) -> bool:
    """打印 welcome 内容，返回 generation 是否兼容。"""
    try:
        welcome = json.loads(data)
    except json.JSONDecodeError as exc:
        print(f"  ✗ welcome 不是合法 JSON: {exc}")
        return False

    print(f"  server_version : {welcome.get('server_version')}")
    print(f"  generation     : {welcome.get('generation')}")
    print(f"  snapshot_codec : {welcome.get('snapshot_codec')}")
    print(f"  surface_codec  : {welcome.get('surface_codec')}")
    print(f"  capabilities   : {', '.join(welcome.get('capabilities', []))}")

    methods = welcome.get("methods", [])
    print(f"  methods        : {len(methods)} 个")
    for method in methods:
        print(f"      {method}")

    generation = welcome.get("generation")
    if generation != hp.ENDPOINT_GENERATION:
        print(f"\n⚠️ generation {generation} 与客户端 {hp.ENDPOINT_GENERATION} 不匹配")
        return False

    print("\n✅ 握手成功")
    return True


def run(socket_path: str, cols: int, rows: int) -> int:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(10)
    sock.connect(socket_path)

    try:
        hello = hp.build_hello(cols, rows)
        sock.sendall(hp.frame(hello))
        print(f"→ hello 已发送（{len(hello)} 字节）")

        # 最多读 8 帧，welcome 之后的数据流不再关心
        for _ in range(8):
            body = hp.read_frame(sock)
            if body is None:
                print("✗ 连接被关闭")
                return 1

            tag = body[0]
            if tag != hp.SERVER_ENDPOINT_CONTROL:
                print(f"  [tag={tag}] {len(body)} 字节")
                continue

            index = 1
            kind_len, index = hp.read_varint(body, index)
            kind = body[index:index + kind_len].decode()
            index += kind_len
            data_len, index = hp.read_varint(body, index)
            data = body[index:index + data_len].decode()

            print(f"← {kind}")

            if kind == "endpoint.welcome.v1":
                return 0 if print_welcome(data) else 1

            if kind == "endpoint.agent-completions.v1":
                print(f"  {data[:160]}")

            if kind == "shell.snapshot.v1":
                print(f"  snapshot {len(data)} 字节（数据流已开始，握手完成）")
                return 0

        print("✗ 未收到 welcome")
        return 1
    finally:
        sock.close()


def main() -> int:
    args = parse_args()
    try:
        return run(args.socket, args.cols, args.rows)
    except FileNotFoundError:
        print(f"✗ socket 不存在: {args.socket}\n  herdr 是否在运行？", file=sys.stderr)
        return 1
    except (ConnectionRefusedError, TimeoutError, OSError) as exc:
        print(f"✗ 连接失败: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
