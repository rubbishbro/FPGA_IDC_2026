"""class_loader64 的 B/C 装载测试：64-bit index、4 力度带、Control、C seed。

用合成 ROM（写在 build 目录），不依赖真实 B/C 表：
  * B：n_vel=4、velocity=200 -> band 3、4 个 core 词、无 seed；
  * C：n_vel=1、has_seed=1、4 个 core 词 + 4 个 seed 词。
"""

from __future__ import annotations

import os
import sys

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = _HERE
while not (os.path.isdir(os.path.join(_ROOT, "rtl"))
           and os.path.isdir(os.path.join(_ROOT, "sim"))):
    _ROOT = os.path.dirname(_ROOT)
sys.path.insert(0, os.path.join(_ROOT, "python", "modal_sim"))
sys.path.insert(0, os.path.join(_ROOT, "sim", "support"))

from class_format import pack_core, pack_ctrl_common, pack_index, pack_seed  # noqa: E402
from _test_runner import build_and_run  # noqa: E402

INDEX_DEPTH = 1 << 13
CTRL_DEPTH = 1024
COEFF_DEPTH = 32
SEED_DEPTH = 64


def _i(sig):
    try:
        return int(sig.value)
    except ValueError:
        return 0


def _write_roms(rom_dir):
    os.makedirs(rom_dir, exist_ok=True)

    index = [0] * INDEX_DEPTH
    # B: class=1, inst=0, note=60, n_vel=4, mode_offset=0, ctrl=0
    addr_b = (1 << 11) | (0 << 7) | 60
    index[addr_b] = pack_index(present=1, n_modes=4, n_vel=4,
                               mode_offset=0, ctrl_index=0, version=0,
                               has_control=1, has_seed=0, class_=1)
    # C: class=2, inst=0, note=36, n_vel=1, mode_offset=4, ctrl=1, has_seed
    addr_c = (2 << 11) | (0 << 7) | 36
    index[addr_c] = pack_index(present=1, n_modes=4, n_vel=1,
                               mode_offset=4, ctrl_index=1, version=2,
                               has_control=1, has_seed=1, class_=2)
    with open(os.path.join(rom_dir, "index.mem"), "w") as fh:
        for w in index:
            fh.write(f"{w:016x}\n")

    ctrl = [0] * CTRL_DEPTH
    ctrl[0] = pack_ctrl_common(class_=1, instrument=0, ctrl_format=1,
                               key_gain=32768)
    ctrl[1] = pack_ctrl_common(class_=2, instrument=0, ctrl_format=2,
                               key_gain=16384)
    with open(os.path.join(rom_dir, "ctrl.mem"), "w") as fh:
        for w in ctrl:
            fh.write(f"{w:064x}\n")

    coeff = [0] * COEFF_DEPTH
    # B band 3 -> mode_offset 0 + 3*4 = 12..15
    for k in range(4):
        coeff[12 + k] = pack_core(G=100 + k, a2=0x800000 + k, a1=-(10 + k))
    # C mode_offset 4 -> 4..7
    for k in range(4):
        coeff[4 + k] = pack_core(G=200 + k, a2=0x900000 + k, a1=-(20 + k))
    with open(os.path.join(rom_dir, "coeff.mem"), "w") as fh:
        for w in coeff:
            fh.write(f"{w:018x}\n")

    seed = [0] * SEED_DEPTH
    # C: seed_base = mode_offset*4 + variant*4；note_id=1 -> variant 1 -> 20..23
    for k in range(4):
        seed[20 + k] = pack_seed(y1=0x1000 + k, y2=-0x2000 - k)
    with open(os.path.join(rom_dir, "seed.mem"), "w") as fh:
        for w in seed:
            fh.write(f"{w:016x}\n")


async def _begin(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())


async def _reset(dut):
    dut.rst_n.value = 0
    for name, value in (
        ("load_valid", 0), ("load_voice", 0), ("ev_class", 0),
        ("ev_layer", 0), ("ev_instrument", 0), ("ev_note", 0),
        ("ev_velocity", 0), ("ev_note_id", 0), ("ev_gate", 1),
        ("ev_event_type", 0), ("clear_ready", 1), ("cfg_ready", 1),
        ("seed_ready", 1),
    ):
        getattr(dut, name).value = value
    for _ in range(4):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)
    await Timer(1, unit="ns")


async def _load(dut, *, cls, note, velocity, note_id, voice=0):
    dut.load_valid.value = 1
    dut.load_voice.value = voice
    dut.ev_class.value = cls
    dut.ev_layer.value = 0
    dut.ev_instrument.value = 0
    dut.ev_note.value = note
    dut.ev_velocity.value = velocity
    dut.ev_note_id.value = note_id
    dut.ev_gate.value = 1
    dut.ev_event_type.value = 0
    await Timer(1, unit="ns")
    assert _i(dut.load_ready) == 1, "load_ready 未就绪"

    cfgs, seeds = [], []
    done = committed = None
    for _ in range(2000):
        await RisingEdge(dut.clk)
        await Timer(1, unit="ns")
        cv = _i(dut.cfg_valid)
        sv = _i(dut.seed_valid)
        cr = _i(dut.cfg_ready)
        sr = _i(dut.seed_ready)
        if cv and cr:
            cfgs.append((_i(dut.cfg_mode), _i(dut.cfg_word)))
        if sv and sr:
            seeds.append((_i(dut.seed_mode), _i(dut.seed_word)))
        if _i(dut.load_done):
            done = True
            committed = (_i(dut.commit_class), _i(dut.commit_n_modes),
                         _i(dut.commit_velocity), _i(dut.commit_ctrl))
            break
    dut.load_valid.value = 0
    assert done, "load_done 未拉高"
    return cfgs, seeds, committed


@cocotb.test(timeout_time=120, timeout_unit="sec")
async def t01_b_class_band3(dut):
    await _begin(dut)
    await _reset(dut)
    cfgs, seeds, committed = await _load(dut, cls=1, note=60, velocity=200,
                                         note_id=2)
    assert [m for m, _ in cfgs] == [0, 1, 2, 3], cfgs
    assert seeds == [], seeds
    base = 12  # mode_offset 0 + band 3 * n_modes 4
    assert [w for _, w in cfgs] == [pack_core(G=100 + k, a2=0x800000 + k,
                                              a1=-(10 + k)) for k in range(4)]
    assert committed[0] == 1 and committed[1] == 4
    assert committed[2] == 200


@cocotb.test(timeout_time=120, timeout_unit="sec")
async def t02_c_class_seed(dut):
    await _begin(dut)
    await _reset(dut)
    cfgs, seeds, committed = await _load(dut, cls=2, note=36, velocity=0,
                                         note_id=1)
    assert [m for m, _ in cfgs] == [0, 1, 2, 3], cfgs
    assert [m for m, _ in seeds] == [0, 1, 2, 3], seeds
    assert [w for _, w in cfgs] == [pack_core(G=200 + k, a2=0x900000 + k,
                                              a1=-(20 + k)) for k in range(4)]
    assert [w for _, w in seeds] == [pack_seed(y1=0x1000 + k, y2=-0x2000 - k)
                                     for k in range(4)]
    assert committed[0] == 2 and committed[1] == 4


def _sources():
    return [os.path.join(_ROOT, "rtl", "core", "class_format_pkg.sv"),
            os.path.join(_ROOT, "rtl", "core", "class_loader64.sv")]


if __name__ == "__main__":
    import argparse

    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--build-dir",
                    default=os.path.join(_ROOT, "sim", "build", "class_loader64"))
    args = ap.parse_args()
    rom = os.path.join(args.build_dir, "rom")
    _write_roms(rom)
    params = {
        "COEFF_FILE": '"' + os.path.join(rom, "coeff.mem") + '"',
        "INDEX_FILE": '"' + os.path.join(rom, "index.mem") + '"',
        "CTRL_FILE": '"' + os.path.join(rom, "ctrl.mem") + '"',
        "SEED_FILE": '"' + os.path.join(rom, "seed.mem") + '"',
        "COEFF_DEPTH": COEFF_DEPTH,
        "INDEX_DEPTH": INDEX_DEPTH,
        "CTRL_DEPTH": CTRL_DEPTH,
        "SEED_DEPTH": SEED_DEPTH,
        "N_MODES": 4,
    }
    summary = build_and_run(_sources(), "class_loader64",
                            "test_class_loader64", _HERE, args.build_dir,
                            params, {})
    print(f"[class_loader64] {summary['n']} tests PASS")
