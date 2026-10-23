"""T-F01: 统一记录格式的 RTL/Python 逐字段对拍。

覆盖 Event 64 / Key 13 / Index 64 / Control 公共头 64 / Core 72 / Seed 64，
以及 ``n_vel=4`` 的 band 边界和 ``core_addr = mode_offset + band*n_modes + mode``。

RTL 侧是 ``sim/unit/core/class_format_probe.sv``（只做 pack/unpack 摊平），
Python 侧是 ``python/modal_sim/class_format.py``；两者位序必须完全一致。
"""

from __future__ import annotations

import os
import random
import sys

import cocotb
from cocotb.triggers import Timer

_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = _HERE
while not (os.path.isdir(os.path.join(_ROOT, "rtl"))
           and os.path.isdir(os.path.join(_ROOT, "sim"))):
    _ROOT = os.path.dirname(_ROOT)
sys.path.insert(0, os.path.join(_ROOT, "python", "modal_sim"))
sys.path.insert(0, os.path.join(_ROOT, "sim", "support"))

from class_format import (  # noqa: E402
    band_of, band_valid, core_addr, pack_core, pack_ctrl_common, pack_event,
    pack_index, pack_seed, unpack_core, unpack_ctrl_common, unpack_event,
    unpack_index, unpack_seed, vel8_from_midi,
)
from _test_runner import build_and_run  # noqa: E402


def _u(value: int, width: int) -> int:
    return int(value) & ((1 << width) - 1)


def _drive(dut, *, event, index, core, seed, ctrl, midi, vel8, mode):
    dut.event_i.value = _u(event, 64)
    dut.index_i.value = _u(index, 64)
    dut.core_i.value = _u(core, 72)
    dut.seed_i.value = _u(seed, 64)
    dut.ctrl_i.value = _u(ctrl, 256)
    dut.midi_i.value = _u(midi, 7)
    dut.vel8_i.value = _u(vel8, 8)
    dut.mode_i.value = _u(mode, 7)


def _read(dut, name, width):
    return _u(int(getattr(dut, name).value), width)


@cocotb.test(timeout_time=120, timeout_unit="sec")
async def t01_event_index_core_seed_roundtrip(dut):
    rng = random.Random(20261020)
    for _ in range(300):
        ev = pack_event(
            class_=rng.randrange(4), instrument=rng.randrange(16),
            note=rng.randrange(128), gate=rng.randrange(2),
            velocity=rng.randrange(256), note_id=rng.randrange(1 << 12),
            event_type=rng.randrange(4), timestamp=rng.randrange(1 << 16),
            reserved_lo=rng.randrange(4), reserved_hi=rng.randrange(1 << 10),
        )
        idx = pack_index(
            present=rng.randrange(2), n_modes=rng.randrange(1, 49),
            n_vel=rng.randrange(1, 9), mode_offset=rng.randrange(1 << 16),
            ctrl_index=rng.randrange(1 << 12), version=rng.randrange(4),
            has_control=rng.randrange(2), has_seed=rng.randrange(2),
            class_=rng.randrange(4), flags=rng.randrange(1 << 6),
            reserved=rng.randrange(1 << 13),
        )
        core = pack_core(
            G=rng.randrange(-(1 << 25), 1 << 25),
            a2=rng.randrange(1 << 24),
            a1=rng.randrange(-(1 << 21), 1 << 21),
        )
        seed = pack_seed(
            y1=rng.randrange(-(1 << 31), 1 << 31),
            y2=rng.randrange(-(1 << 31), 1 << 31),
        )
        ctrl = pack_ctrl_common(
            class_=rng.randrange(4), instrument=rng.randrange(16),
            ctrl_format=rng.randrange(3), key_gain=rng.randrange(1 << 16),
            flags=rng.randrange(16), choke_group=rng.randrange(8),
            tail_samples=rng.randrange(1 << 20),
        )
        midi = rng.randrange(128)
        vel8 = rng.randrange(256)
        mode = rng.randrange(128)

        _drive(dut, event=ev, index=idx, core=core, seed=seed, ctrl=ctrl,
               midi=midi, vel8=vel8, mode=mode)
        await Timer(1, unit="ns")

        e = unpack_event(ev)
        assert _read(dut, "ev_class", 2) == e["class"]
        assert _read(dut, "ev_reserved_lo", 2) == e["reserved_lo"]
        assert _read(dut, "ev_instrument", 4) == e["instrument"]
        assert _read(dut, "ev_note", 7) == e["note"]
        assert _read(dut, "ev_gate", 1) == e["gate"]
        assert _read(dut, "ev_velocity", 8) == e["velocity"]
        assert _read(dut, "ev_note_id", 12) == e["note_id"]
        assert _read(dut, "ev_event_type", 2) == e["event_type"]
        assert _read(dut, "ev_timestamp", 16) == e["timestamp"]

        assert _read(dut, "key_class", 2) == e["class"]
        assert _read(dut, "key_instrument", 4) == e["instrument"]
        assert _read(dut, "key_note", 7) == e["note"]

        i = unpack_index(idx)
        assert _read(dut, "idx_present", 1) == i["present"]
        assert _read(dut, "idx_n_modes", 7) == i["n_modes"]
        assert _read(dut, "idx_n_vel", 3) == i["n_vel"]
        assert _read(dut, "idx_mode_offset", 16) == i["mode_offset"]
        assert _read(dut, "idx_ctrl_index", 12) == i["ctrl_index"]
        assert _read(dut, "idx_version", 2) == i["version"]
        assert _read(dut, "idx_has_control", 1) == i["has_control"]
        assert _read(dut, "idx_has_seed", 1) == i["has_seed"]
        assert _read(dut, "idx_class", 2) == i["class"]
        assert _read(dut, "idx_flags", 6) == i["flags"]
        assert _read(dut, "idx_reserved", 13) == i["reserved"]

        c = unpack_core(core)
        assert _read(dut, "core_G", 26) == _u(c["G"], 26)
        assert _read(dut, "core_a2", 24) == c["a2"]
        assert _read(dut, "core_a1", 22) == _u(c["a1"], 22)

        s = unpack_seed(seed)
        assert _read(dut, "seed_y2", 32) == _u(s["y2"], 32)
        assert _read(dut, "seed_y1", 32) == _u(s["y1"], 32)

        cc = unpack_ctrl_common(ctrl)
        assert _read(dut, "ctrl_class", 2) == cc["class"]
        assert _read(dut, "ctrl_instrument", 4) == cc["instrument"]
        assert _read(dut, "ctrl_format", 8) == cc["ctrl_format"]
        assert _read(dut, "ctrl_key_gain", 16) == cc["key_gain"]
        assert _read(dut, "ctrl_flags", 4) == cc["flags"]
        assert _read(dut, "ctrl_choke_group", 3) == cc["choke_group"]
        assert _read(dut, "ctrl_tail_samples", 20) == cc["tail_samples"]


@cocotb.test(timeout_time=120, timeout_unit="sec")
async def t02_band_and_addr(dut):
    # velocity -> band 边界：4 带，每带 64
    idx4 = pack_index(n_modes=48, n_vel=4, mode_offset=1000, class_=1,
                      version=0, has_control=1)
    idx1 = pack_index(n_modes=48, n_vel=1, mode_offset=0, class_=2,
                      version=2, has_seed=1)

    for vel8, want in ((0, 0), (63, 0), (64, 1), (127, 1),
                       (128, 2), (191, 2), (192, 3), (255, 3)):
        _drive(dut, event=0, index=idx4, core=0, seed=0, ctrl=0,
               midi=0, vel8=vel8, mode=47)
        await Timer(1, unit="ns")
        got = _read(dut, "band_o", 2)
        assert got == want, f"vel8={vel8}: band {got} != {want}"
        idx_d = unpack_index(idx4)
        assert _read(dut, "core_addr_o", 18) == core_addr(idx_d, want, 47)
        assert _read(dut, "band_valid_o", 1) == 1

    # MIDI -> 8-bit
    for midi, want in ((0, 0), (1, 2), (63, 126), (127, 254)):
        _drive(dut, event=0, index=idx4, core=0, seed=0, ctrl=0,
               midi=midi, vel8=0, mode=0)
        await Timer(1, unit="ns")
        assert _read(dut, "vel8_from_midi_o", 8) == want

    # n_vel=1：band 0 合法，band 2 非法
    _drive(dut, event=0, index=idx1, core=0, seed=0, ctrl=0,
           midi=0, vel8=0, mode=0)
    await Timer(1, unit="ns")
    assert _read(dut, "band_valid_o", 1) == 1
    _drive(dut, event=0, index=idx1, core=0, seed=0, ctrl=0,
           midi=0, vel8=128, mode=0)
    await Timer(1, unit="ns")
    assert _read(dut, "band_valid_o", 1) == 0


def _sources():
    return [os.path.join(_ROOT, "rtl", "core", "class_format_pkg.sv"),
            os.path.join(_HERE, "class_format_probe.sv")]


if __name__ == "__main__":
    import argparse

    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--build-dir",
                    default=os.path.join(_ROOT, "sim", "build", "class_format"))
    args = ap.parse_args()
    summary = build_and_run(_sources(), "class_format_probe",
                            "test_class_format", _HERE, args.build_dir, {}, {})
    print(f"[class_format] {summary['n']} tests PASS")
