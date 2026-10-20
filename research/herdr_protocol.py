"""Herdr endpoint 协议的最小客户端实现（Python 版，仅用于调研）。

对应 Swift 实现里的 HerdrProtocol 包：bincode varint 编解码 + u32 长度帧。

这些结构来自 herdr 0.9.x，字段顺序是 wire 兼容契约，不可更改。
参考：herdr-gpui/crates/herdr-protocol/src/{wire,codec,frame}.rs
       （Apache-2.0，见 NOTICE）
"""

from __future__ import annotations

import socket
import struct

SOCKET_PATH = "~/.config/herdr/herdr-client.sock"

MAX_FRAME_SIZE = 2 * 1024 * 1024
MAX_GRAPHICS_FRAME_SIZE = 32 * 1024 * 1024


# --------------------------------------------------------------------------
# bincode 2 "standard" 配置的 varint
# --------------------------------------------------------------------------

def varint(n: int) -> bytes:
    """bincode 长度/整数前缀编码。"""
    if n < 251:
        return bytes([n])
    if n <= 0xFFFF:
        return b"\xfb" + struct.pack("<H", n)
    if n <= 0xFFFFFFFF:
        return b"\xfc" + struct.pack("<I", n)
    return b"\xfd" + struct.pack("<Q", n)


def read_varint(buf: bytes, i: int) -> tuple[int, int]:
    first = buf[i]
    if first < 251:
        return first, i + 1
    if first == 251:
        return struct.unpack("<H", buf[i + 1:i + 3])[0], i + 3
    if first == 252:
        return struct.unpack("<I", buf[i + 1:i + 5])[0], i + 5
    return struct.unpack("<Q", buf[i + 1:i + 9])[0], i + 9


def bstr(s: str | bytes) -> bytes:
    """bincode String：varint 长度 + UTF-8 字节。"""
    raw = s.encode() if isinstance(s, str) else s
    return varint(len(raw)) + raw


# --------------------------------------------------------------------------
# 帧：u32 LE 长度 + 载荷
# --------------------------------------------------------------------------

def frame(payload: bytes) -> bytes:
    return struct.pack("<I", len(payload)) + payload


def read_frame(sock: socket.socket) -> bytes | None:
    header = b""
    while len(header) < 4:
        chunk = sock.recv(4 - len(header))
        if not chunk:
            return None
        header += chunk

    n = struct.unpack("<I", header)[0]
    if n == 0 or n > MAX_GRAPHICS_FRAME_SIZE:
        raise ValueError(f"非法帧长度 {n}")

    body = b""
    while len(body) < n:
        chunk = sock.recv(n - len(body))
        if not chunk:
            return None
        body += chunk
    return body


def read_exact(f, n: int) -> bytes | None:
    """从文件对象（SSH 子进程的 stdout）读 n 字节。"""
    buf = b""
    while len(buf) < n:
        chunk = f.read(n - len(buf))
        if not chunk:
            return None
        buf += chunk
    return buf


def read_frame_from_file(f) -> bytes | None:
    header = read_exact(f, 4)
    if not header:
        return None
    n = struct.unpack("<I", header)[0]
    if n == 0 or n > MAX_GRAPHICS_FRAME_SIZE:
        raise ValueError(f"非法帧长度 {n}")
    return read_exact(f, n)


# --------------------------------------------------------------------------
# 枚举：顺序即 wire tag（bincode 位置编码）
# --------------------------------------------------------------------------

# ClientMessage —— 共 21 个
CLIENT_TERMINAL_HELLO = 0
CLIENT_INPUT = 1
CLIENT_CLIPBOARD_IMAGE = 2
CLIENT_RESIZE = 3
CLIENT_DETACH = 4
CLIENT_ATTACH_TERMINAL = 5
CLIENT_ATTACH_SCROLL = 6
CLIENT_OBSERVE_TERMINAL = 7
CLIENT_CONTROL_TERMINAL = 8
CLIENT_GRAPHICS_TRANSMISSION_RESULT = 9
CLIENT_GRAPHICS_TRANSMISSION_STARTED = 10
CLIENT_CLIENT_SHELL_HELLO = 11
CLIENT_CLIENT_SHELL_RESIZE = 12
CLIENT_CLIENT_SHELL_PANE_INPUT = 13
CLIENT_CLIENT_SHELL_POPUP_INPUT = 14
CLIENT_CLIENT_SHELL_ENDPOINT_REQUEST = 15
CLIENT_ATTACH_MOUSE = 16
CLIENT_CLIENT_SHELL_HOST_THEME = 17
CLIENT_CLIENT_SHELL_FOCUS = 18
CLIENT_CLIENT_SHELL_MOUSE_CAPTURE = 19
CLIENT_ENDPOINT_CONTROL = 20          # ← 注意：不是 11

# ServerMessage —— 共 21 个
SERVER_WELCOME = 0
SERVER_TERMINAL = 1
SERVER_GRAPHICS = 2
SERVER_SERVER_SHUTDOWN = 3
SERVER_NOTIFY = 4
SERVER_CLIPBOARD = 5
SERVER_WINDOW_TITLE = 6
SERVER_RELOAD_SOUND_CONFIG = 7
SERVER_MOUSE_CAPTURE = 8
SERVER_TERMINAL_BELL = 9
SERVER_GRAPHICS_FILE = 10
SERVER_GRAPHICS_TRANSMISSION_RETIRED = 11
SERVER_CLIENT_SHELL_SNAPSHOT = 12
SERVER_PANE_SURFACE = 13
SERVER_SEMANTIC_NOTIFICATION = 14
SERVER_CLIENT_SHELL_ERROR = 15
SERVER_DIRECT_TERMINAL_KEYBOARD_PROTOCOL = 16
SERVER_CLIENT_SHELL_KEYBOARD_REPORT_ALL = 17
SERVER_CLIENT_SHELL_ENDPOINT_RESPONSE_CHUNK = 18
SERVER_PANE_SURFACE_PATCH = 19
SERVER_ENDPOINT_CONTROL = 20

# ClientPaneInputEvent —— 共 4 个
INPUT_KEY = 0
INPUT_TEXT_COMMIT = 1
INPUT_MOUSE = 2
INPUT_PASTE = 3

# ClientMouseKind —— 共 14 个
MOUSE_DOWN_LEFT = 0
MOUSE_DOWN_RIGHT = 1
MOUSE_DOWN_MIDDLE = 2
MOUSE_UP_LEFT = 3
MOUSE_UP_RIGHT = 4
MOUSE_UP_MIDDLE = 5
MOUSE_DRAG_LEFT = 6
MOUSE_DRAG_RIGHT = 7
MOUSE_DRAG_MIDDLE = 8
MOUSE_MOVED = 9
MOUSE_SCROLL_UP = 10
MOUSE_SCROLL_DOWN = 11
MOUSE_SCROLL_LEFT = 12
MOUSE_SCROLL_RIGHT = 13

# ClientKeyCode —— 共 18 个
KEY_BACKSPACE = 0
KEY_ENTER = 1
KEY_LEFT = 2
KEY_RIGHT = 3
KEY_UP = 4
KEY_DOWN = 5
KEY_HOME = 6
KEY_END = 7
KEY_PAGE_UP = 8
KEY_PAGE_DOWN = 9
KEY_TAB = 10
KEY_BACK_TAB = 11
KEY_DELETE = 12
KEY_INSERT = 13
KEY_ESC = 14
KEY_CHAR = 15
KEY_F = 16
KEY_NULL = 17


# --------------------------------------------------------------------------
# Surface 解码
# --------------------------------------------------------------------------

# CellData.modifier 位
MODIFIER_BOLD = 1 << 0
MODIFIER_DIM = 1 << 1
MODIFIER_ITALIC = 1 << 2
MODIFIER_UNDERLINE = 1 << 3
MODIFIER_BLINK = 1 << 4
MODIFIER_REVERSE = 1 << 5
MODIFIER_REVERSED = 1 << 6
MODIFIER_HIDDEN = 1 << 7
MODIFIER_STRIKETHROUGH = 1 << 8


def decode_color(raw: int) -> tuple[str, object]:
    """fg/bg 的编码，注意不是 ARGB。

    0..=16          命名色
    0x010000XX      索引色（XX = 0..255）
    0x02RRGGBB      24-bit RGB
    """
    if raw <= 16:
        return "named", raw
    tag = (raw >> 24) & 0xFF
    if tag == 0x01:
        return "indexed", raw & 0xFF
    if tag == 0x02:
        return "rgb", ((raw >> 16) & 0xFF, (raw >> 8) & 0xFF, raw & 0xFF)
    return "unknown", raw


def decode_cell(buf: bytes, i: int) -> tuple[dict, int]:
    length, i = read_varint(buf, i)
    symbol = buf[i:i + length].decode("utf-8", "replace")
    i += length
    fg, i = read_varint(buf, i)
    bg, i = read_varint(buf, i)
    modifier, i = read_varint(buf, i)
    skip = buf[i]
    i += 1
    has_link = buf[i]
    i += 1
    hyperlink = None
    if has_link:
        hyperlink, i = read_varint(buf, i)
    return {
        "symbol": symbol,
        "fg": fg,
        "bg": bg,
        "modifier": modifier,
        "skip": bool(skip),
        "hyperlink": hyperlink,
    }, i


def decode_frame_data(buf: bytes, i: int) -> tuple[dict, int]:
    count, i = read_varint(buf, i)
    cells = []
    for _ in range(count):
        cell, i = decode_cell(buf, i)
        cells.append(cell)

    width, i = read_varint(buf, i)
    height, i = read_varint(buf, i)

    # cursor: Option<CursorState{x, y, visible, shape}>
    has_cursor = buf[i]
    i += 1
    cursor = None
    if has_cursor:
        x, i = read_varint(buf, i)
        y, i = read_varint(buf, i)
        visible = buf[i]
        i += 1
        shape, i = read_varint(buf, i)
        cursor = {"x": x, "y": y, "visible": bool(visible), "shape": shape}

    # hyperlinks: Vec<String>
    link_count, i = read_varint(buf, i)
    hyperlinks = []
    for _ in range(link_count):
        length, i = read_varint(buf, i)
        hyperlinks.append(buf[i:i + length].decode("utf-8", "replace"))
        i += length

    # graphics: Vec<u8>
    graphics_len, i = read_varint(buf, i)
    graphics = buf[i:i + graphics_len]
    i += graphics_len

    return {
        "cells": cells,
        "width": width,
        "height": height,
        "cursor": cursor,
        "hyperlinks": hyperlinks,
        "graphics": graphics,
    }, i


def _decode_rect(buf: bytes, i: int) -> tuple[tuple[int, int, int, int], int]:
    x, i = read_varint(buf, i)
    y, i = read_varint(buf, i)
    w, i = read_varint(buf, i)
    h, i = read_varint(buf, i)
    return (x, y, w, h), i


def decode_surface(buf: bytes) -> dict:
    """解码 PaneSurfaceFrame。

    布局：boot_id | projection_revision | surface_revision | FrameData | panes | ...
    注意 rect（含边框）与 inner_rect（内容区）的区别——布局必须用 inner_rect。
    """
    i = 1  # 跳过 tag

    length, i = read_varint(buf, i)
    boot_id = buf[i:i + length].decode()
    i += length

    projection_revision, i = read_varint(buf, i)
    surface_revision, i = read_varint(buf, i)

    frame, i = decode_frame_data(buf, i)

    pane_count, i = read_varint(buf, i)
    panes = []
    for _ in range(pane_count):
        length, i = read_varint(buf, i)
        pane_id = buf[i:i + length].decode()
        i += length

        content_revision, i = read_varint(buf, i)
        rect, i = _decode_rect(buf, i)
        inner_rect, i = _decode_rect(buf, i)

        has_scrollbar = buf[i]
        i += 1
        scrollbar_rect = None
        if has_scrollbar:
            scrollbar_rect, i = _decode_rect(buf, i)

        has_scroll = buf[i]
        i += 1
        scroll = None
        if has_scroll:
            offset, i = read_varint(buf, i)
            max_offset, i = read_varint(buf, i)
            viewport_rows, i = read_varint(buf, i)
            scroll = {"offset": offset, "max": max_offset, "rows": viewport_rows}

        focused = buf[i]
        i += 1
        mouse_reporting = buf[i]
        i += 1
        sgr_pixel_mouse = buf[i]
        i += 1
        alternate_screen = buf[i]
        i += 1
        pixel_width, i = read_varint(buf, i)
        pixel_height, i = read_varint(buf, i)

        panes.append({
            "pane_id": pane_id,
            "content_revision": content_revision,
            "rect": rect,
            "inner_rect": inner_rect,
            "scrollbar_rect": scrollbar_rect,
            "scroll": scroll,
            "focused": bool(focused),
            "mouse_reporting": bool(mouse_reporting),
            "sgr_pixel_mouse": bool(sgr_pixel_mouse),
            "alternate_screen_active": bool(alternate_screen),
            "pixel_width": pixel_width,
            "pixel_height": pixel_height,
        })

    return {
        "boot_id": boot_id,
        "projection_revision": projection_revision,
        "surface_revision": surface_revision,
        "frame": frame,
        "panes": panes,
    }


def surface_columns(frame: dict) -> list[list[str]]:
    """把 cell 网格还原成「按列索引」的文本。

    返回 rows[r][c]，其中：
      - 普通字符：该字符本身
      - 宽字符（中文/emoji）：首列放字符，**次列放空串**（占位）
      - skip=True 或空单元：空串

    **不要用字符串下标去切这个网格**：宽字符是 1 个字符占 2 列，
    字符串长度与列号不等。需要取 pane 区域时，按列范围对 rows[r] 切片。

    宽字符的真实形态（实测 herdr 0.9.x）：一个真实字符 + 一个普通空单元
    （skip=False, symbol=" "）占据后一列，保证 cell 流与终端列号逐格对齐。
    而 VT 模拟器（pyte / Ghostty）让宽字符自身占 2 列，次列为空。
    两者按列比对时完全等价。
    """
    width = frame["width"]
    cells = frame["cells"]

    def is_wide(symbol: str) -> bool:
        if not symbol:
            return False
        codepoint = ord(symbol[0])
        return (
            0x1100 <= codepoint <= 0x115F
            or 0x2E80 <= codepoint <= 0xA4CF
            or 0xAC00 <= codepoint <= 0xD7A3
            or 0xF900 <= codepoint <= 0xFAFF
            or 0xFE30 <= codepoint <= 0xFE6F
            or 0xFF00 <= codepoint <= 0xFF60
            or 0xFFE0 <= codepoint <= 0xFFE6
            or 0x1F300 <= codepoint <= 0x1F9FF
        )

    rows: list[list[str]] = []
    for r in range(frame["height"]):
        columns: list[str] = [""] * width
        padding = 0
        for c in range(width):
            cell = cells[r * width + c]
            symbol = cell["symbol"]
            if cell["skip"]:
                continue
            if padding > 0 and symbol in ("", " "):
                padding -= 1
                continue
            padding = 0
            columns[c] = symbol
            if symbol and is_wide(symbol):
                padding = 1
        rows.append(columns)
    return rows


def join_columns(columns: list[str]) -> str:
    """把一行的列数组拼成人类可读文本（丢掉宽字符占位列）。"""
    return "".join(columns)


def surface_text(frame: dict) -> list[str]:
    """整屏文本行（丢掉宽字符占位列，用于人眼阅读与整行比对）。"""
    return [join_columns(row) for row in surface_columns(frame)]


# --------------------------------------------------------------------------
# 握手
# --------------------------------------------------------------------------

ENDPOINT_GENERATION = 1


def build_hello(cols: int, rows: int, *, cell_width_px: int = 10,
                cell_height_px: int = 20, surface_active: bool = True,
                optional_codecs: bool = False) -> bytes:
    """构造 endpoint.hello.v1（ClientMessage::EndpointControl）。"""
    import json

    hello = {
        "generation": ENDPOINT_GENERATION,
        "cell_width_px": cell_width_px,
        "cell_height_px": cell_height_px,
        "surface_size": {"cols": cols, "rows": rows},
        "pixel_mouse": False,
        "direct_graphics": False,
        "endpoint_keybindings": False,
        "mouse_capture": False,
        "surface_active": surface_active,
        # 三个可选压缩编码；第一版全部关闭，降低实现复杂度
        "surface_reuse": optional_codecs,
        "surface_delta": optional_codecs,
        "surface_scroll": optional_codecs,
        "snapshot_codecs": ["shell.snapshot.v1"],
        "surface_codecs": ["shell.surface.v1"],
        "input_codecs": ["shell.input.semantic.v1"],
        "blob_codecs": ["shell.blob.v1"],
    }
    return (bytes([CLIENT_ENDPOINT_CONTROL])
            + bstr("endpoint.hello.v1")
            + bstr(json.dumps(hello)))
