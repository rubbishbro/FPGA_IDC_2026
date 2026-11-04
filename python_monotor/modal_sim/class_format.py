"""统一记录格式（A/B/C）的 Python pack/unpack。

位序必须与 ``history/core_2026-11-01/rtl/core/class_format_pkg.sv`` 完全一致：
  Event 64 / Key 13 / Index 64 / Control 256 / Core 72 / Seed 64
先冻结 ``n_vel = 4``、``band = vel8[7:6]``、
``core_addr = mode_offset + band*n_modes + mode``。

本模块只做位操作，不依赖 numpy，方便 RTL 对拍与生成器复用。
"""

from __future__ import annotations

from typing import Any

# ---------------------------------------------------------------------------
# 通用
# ---------------------------------------------------------------------------
def _u(value: int, width: int) -> int:
    return int(value) & ((1 << width) - 1)


def _s(value: int, width: int) -> int:
    value = int(value) & ((1 << width) - 1)
    return value - (1 << width) if value & (1 << (width - 1)) else value


def _field(word: int, lo: int, width: int, signed: bool = False) -> int:
    value = (int(word) >> lo) & ((1 << width) - 1)
    return _s(value, width) if signed else value


# ---------------------------------------------------------------------------
# Event（64-bit）
# ---------------------------------------------------------------------------
EVENT_FIELDS = {
    "class": (0, 2),
    "reserved_lo": (2, 2),
    "instrument": (4, 4),
    "note": (8, 7),
    "gate": (15, 1),
    "velocity": (16, 8),
    "note_id": (24, 12),
    "event_type": (36, 2),
    "timestamp": (38, 16),
    "reserved_hi": (54, 10),
}


def pack_event(
    *,
    class_: int,
    instrument: int,
    note: int,
    gate: int,
    velocity: int,
    note_id: int = 0,
    event_type: int = 0,
    timestamp: int = 0,
    reserved_lo: int = 0,
    reserved_hi: int = 0,
) -> int:
    word = 0
    for name, value in (
        ("class", class_),
        ("reserved_lo", reserved_lo),
        ("instrument", instrument),
        ("note", note),
        ("gate", gate),
        ("velocity", velocity),
        ("note_id", note_id),
        ("event_type", event_type),
        ("timestamp", timestamp),
        ("reserved_hi", reserved_hi),
    ):
        lo, width = EVENT_FIELDS[name]
        word |= _u(value, width) << lo
    return word


def unpack_event(word: int) -> dict[str, int]:
    return {name: _field(word, lo, width) for name, (lo, width) in EVENT_FIELDS.items()}


# ---------------------------------------------------------------------------
# Key（13-bit）
# ---------------------------------------------------------------------------
def pack_key(*, class_: int, instrument: int, note: int) -> int:
    return (_u(class_, 2) << 11) | (_u(instrument, 4) << 7) | _u(note, 7)


def unpack_key(word: int) -> dict[str, int]:
    return {
        "class": _field(word, 11, 2),
        "instrument": _field(word, 7, 4),
        "note": _field(word, 0, 7),
    }


def key_of(ev: dict[str, int]) -> dict[str, int]:
    return {
        "class": ev["class"],
        "instrument": ev["instrument"],
        "note": ev["note"],
    }


# ---------------------------------------------------------------------------
# Index（64-bit）
# ---------------------------------------------------------------------------
INDEX_FIELDS = {
    "present": (63, 1),
    "n_modes": (56, 7),
    "n_vel": (53, 3),
    "mode_offset": (37, 16),
    "ctrl_index": (25, 12),
    "version": (23, 2),
    "has_control": (22, 1),
    "has_seed": (21, 1),
    "class": (19, 2),
    "flags": (13, 6),
    "reserved": (0, 13),
}


def pack_index(
    *,
    present: int = 1,
    n_modes: int,
    n_vel: int = 4,
    mode_offset: int,
    ctrl_index: int = 0,
    version: int = 0,
    has_control: int = 0,
    has_seed: int = 0,
    class_: int = 0,
    flags: int = 0,
    reserved: int = 0,
) -> int:
    word = 0
    for name, value in (
        ("present", present),
        ("n_modes", n_modes),
        ("n_vel", n_vel),
        ("mode_offset", mode_offset),
        ("ctrl_index", ctrl_index),
        ("version", version),
        ("has_control", has_control),
        ("has_seed", has_seed),
        ("class", class_),
        ("flags", flags),
        ("reserved", reserved),
    ):
        lo, width = INDEX_FIELDS[name]
        word |= _u(value, width) << lo
    return word


def unpack_index(word: int) -> dict[str, int]:
    return {name: _field(word, lo, width) for name, (lo, width) in INDEX_FIELDS.items()}


# ---------------------------------------------------------------------------
# Core（72-bit）
# ---------------------------------------------------------------------------
def pack_core(*, G: int, a2: int, a1: int) -> int:
    return (_u(G, 26) << 46) | (_u(a2, 24) << 22) | _u(a1, 22)


def unpack_core(word: int) -> dict[str, int]:
    return {
        "G": _field(word, 46, 26, signed=True),
        "a2": _field(word, 22, 24),
        "a1": _field(word, 0, 22, signed=True),
    }


# ---------------------------------------------------------------------------
# Seed（64-bit）
# ---------------------------------------------------------------------------
def pack_seed(*, y1: int, y2: int) -> int:
    return (_u(y2, 32) << 32) | _u(y1, 32)


def unpack_seed(word: int) -> dict[str, int]:
    return {
        "y2": _field(word, 32, 32, signed=True),
        "y1": _field(word, 0, 32, signed=True),
    }


# ---------------------------------------------------------------------------
# Control 公共头（word0，64-bit）
# ---------------------------------------------------------------------------
CTRL_COMMON_FIELDS = {
    "class": (0, 2),
    "reserved_lo": (2, 2),
    "instrument": (4, 4),
    "ctrl_format": (8, 8),
    "key_gain": (16, 16),
    "flags": (32, 4),
    "choke_group": (36, 3),
    "tail_samples": (39, 20),
    "reserved_hi": (59, 5),
}


def pack_ctrl_common(
    *,
    class_: int,
    instrument: int,
    ctrl_format: int,
    key_gain: int = 32768,
    flags: int = 0,
    choke_group: int = 0,
    tail_samples: int = 0,
    reserved_lo: int = 0,
    reserved_hi: int = 0,
) -> int:
    word = 0
    for name, value in (
        ("class", class_),
        ("reserved_lo", reserved_lo),
        ("instrument", instrument),
        ("ctrl_format", ctrl_format),
        ("key_gain", key_gain),
        ("flags", flags),
        ("choke_group", choke_group),
        ("tail_samples", tail_samples),
        ("reserved_hi", reserved_hi),
    ):
        lo, width = CTRL_COMMON_FIELDS[name]
        word |= _u(value, width) << lo
    return word


def unpack_ctrl_common(word: int) -> dict[str, int]:
    return {
        name: _field(word, lo, width)
        for name, (lo, width) in CTRL_COMMON_FIELDS.items()
    }


# ---------------------------------------------------------------------------
# 力度带与地址
# ---------------------------------------------------------------------------
def vel8_from_midi(midi: int) -> int:
    """MIDI 0..127 -> 8-bit（×2，0..254）。"""
    return _u(midi, 7) << 1


def band_of(vel8: int, n_vel: int = 4) -> int:
    if n_vel == 4:
        return _u(vel8, 8) >> 6
    if n_vel == 8:
        return _u(vel8, 8) >> 5
    if n_vel == 2:
        return _u(vel8, 8) >> 7
    if n_vel == 1:
        return 0
    raise ValueError(f"unsupported n_vel={n_vel}")


def band_valid(index: dict[str, int], band: int) -> bool:
    return 0 <= band < int(index["n_vel"])


def core_addr(index: dict[str, int], band: int, mode: int) -> int:
    return int(index["mode_offset"]) + band * int(index["n_modes"]) + int(mode)


# ---------------------------------------------------------------------------
# 便捷：从 Event 取 Key
# ---------------------------------------------------------------------------
def event_key(word: int) -> int:
    return pack_key(**key_of(unpack_event(word)))
