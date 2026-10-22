#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 zzjcool
"""Send one request to herdr's API socket and print the result.

    herdr-api.py --socket PATH --method command.invoke --params '{"command_id":"..."}'

Why this exists rather than `herdr <verb>`: the CLI exposes a fixed set of verbs
(`workspace`, `pane`, `tab`, …) and no generic "call this method". `command.invoke`
is exactly the method a client uses to open a popup, so a GUI case that needs a
popup has to speak the protocol itself.

The protocol is one JSON line per direction: a request object terminated by a
newline, then one response line (`api/client.rs:186-193`, `224`). Requests carry
an `id`; the response echoes it and puts the payload under `result`.

Exits non-zero and prints the daemon's error on refusal, so a caller can use it as
a plain command rather than parsing output.
"""

import argparse
import json
import socket
import sys


def call(socket_path, method, params, timeout=20.0):
    request = {"id": "kraal-gui", "method": method, "params": params}
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        # A blocking connect/recv with no timeout is how a dead daemon turns into a
        # hung test run instead of a failure.
        sock.settimeout(timeout)
        sock.connect(socket_path)
        sock.sendall(json.dumps(request).encode() + b"\n")
        buffer = b""
        while b"\n" not in buffer:
            chunk = sock.recv(65536)
            if not chunk:
                break
            buffer += chunk
    line = buffer.split(b"\n", 1)[0]
    if not line:
        raise RuntimeError("daemon closed the connection without a response")
    # Parsed with its own handler so a malformed frame names the method and shows
    # what arrived. A bare `json.loads` failure would surface as "Expecting value:
    # line 1 column 1", which says nothing about which request produced it.
    try:
        return json.loads(line)
    except ValueError as error:
        preview = line[:200].decode("utf-8", "replace")
        raise RuntimeError(
            f"malformed response to {method}: {error} — got {preview!r}"
        ) from error


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", required=True)
    parser.add_argument("--method", required=True)
    parser.add_argument("--params", default="{}")
    parser.add_argument("--timeout", type=float, default=20.0)
    parser.add_argument(
        "--field",
        help="print only this key of result instead of the whole JSON",
    )
    args = parser.parse_args()

    try:
        response = call(args.socket, args.method, json.loads(args.params), args.timeout)
    except (OSError, ValueError, RuntimeError) as error:
        print(f"herdr-api: {error}", file=sys.stderr)
        return 2

    # The daemon reports refusals in band: a complete frame, valid JSON, an `error`
    # object instead of `result`. Treating that as success is the mistake
    # `EndpointConnection.throwIfErrorEnvelope` exists to prevent.
    if "error" in response:
        error = response["error"] or {}
        print(
            f"herdr-api: refused by the daemon: {error.get('code')} — "
            f"{error.get('message')}",
            file=sys.stderr,
        )
        return 1

    result = response.get("result")
    if args.field:
        value = (result or {}).get(args.field)
        if value is None:
            print(f"herdr-api: no '{args.field}' in the result", file=sys.stderr)
            return 1
        print(value)
        return 0
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
