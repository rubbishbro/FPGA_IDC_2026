"""synth_top USE_BC=1：B class 从顶层 load -> commit_ctrl/ctrl_rd_data。"""

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
from class_format import pack_core, pack_ctrl_common, pack_index  # noqa: E402
from _test_runner import build_and_run  # noqa: E402


def _s(v, w):
    v = int(v) & ((1 << w) - 1)
    return v - (1 << w) if v & (1 << (w - 1)) else v


def _i(sig):
    try:
        return int(sig.value)
    except ValueError:
        return 0


def _roms(d):
    os.makedirs(d, exist_ok=True)
    idx = [0] * 8192
    idx[(1 << 11) | 60] = pack_index(present=1, n_modes=4, n_vel=4,
                                     mode_offset=0, ctrl_index=0, version=0,
                                     has_control=1, has_seed=0, class_=1)
    with open(os.path.join(d, "b_index.mem"), "w") as f:
        for w in idx:
            f.write(f"{w:016x}\n")
    ctrl = [0] * 1024
    ctrl[0] = (pack_ctrl_common(class_=1, instrument=0, ctrl_format=1,
                                key_gain=32768)
               | (0x800000 << 16) | (0x800000 << 40)
               | (0x40000000 << 64))
    with open(os.path.join(d, "b_ctrl.mem"), "w") as f:
        for w in ctrl:
            f.write(f"{w:064x}\n")
    coeff = [0] * 16
    for k in range(4):
        coeff[12 + k] = pack_core(G=100 + k, a2=0x800000 + k, a1=-(10 + k))
    with open(os.path.join(d, "b_coeff.mem"), "w") as f:
        for w in coeff:
            f.write(f"{w:018x}\n")
    with open(os.path.join(d, "c_seed.mem"), "w") as f:
        f.write("0" * 16 + "\n")
    with open(os.path.join(d, "a_index.mem"), "w") as f:
        for _ in range(1024):
            f.write("00000\n")
    with open(os.path.join(d, "a_coeff.mem"), "w") as f:
        for _ in range(16):
            f.write("0" * 18 + "\n")


@cocotb.test(timeout_time=120, timeout_unit="sec")
async def t01_b_top_load(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rst_n.value = 0
    for name, value in (("load_valid", 0), ("load_voice", 0),
                        ("load_instrument", 0), ("load_midi", 60),
                        ("load_dyn", 0), ("load_vel", 200), ("load_class", 1),
                        ("load_note_id", 0), ("ctrl_rd_voice", 0),
                        ("b_class_vec", 1), ("b_vel_vec", 32768),
                        ("b_start_mask", 0), ("b_gate_mask", 1),
                        ("b_ratio", 0x8000), ("a1_enable", 0),
                        ("active_mask", 0), ("x_vec", 0),
                        ("rd_en", 0), ("rd_addr", 0),
                        ("buf_wr_en", 0), ("buf_wr_engine", 0),
                        ("buf_wr_addr", 0), ("buf_wr_data", 0),
                        ("res_we", 0), ("res_engine", 0), ("res_bank", 0),
                        ("res_data", 0), ("start", 0)):
        getattr(dut, name).value = value
    for _ in range(4):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)
    await Timer(1, unit="ns")

    dut.load_valid.value = 1
    done = 0
    for _ in range(3000):
        await RisingEdge(dut.clk)
        await Timer(1, unit="ns")
        if _i(dut.load_done):
            done = 1
            break
    dut.load_valid.value = 0
    assert done, "load_done not raised"
    assert _i(dut.loaded_n_modes) == 4
    exp = (pack_ctrl_common(class_=1, instrument=0, ctrl_format=1,
                            key_gain=32768)
           | (0x800000 << 16) | (0x800000 << 40)
           | (0x40000000 << 64))
    assert _i(dut.commit_ctrl) == exp
    for _ in range(2):
        await RisingEdge(dut.clk)
        await Timer(1, unit="ns")
    assert _i(dut.ctrl_rd_data) == exp

    # B 声部：x 由 b_voice_ctrl 生成；外部 x=0，跑几帧应出非零 mix
    dut.b_start_mask.value = 1
    await RisingEdge(dut.clk)
    dut.b_start_mask.value = 0
    dut.active_mask.value = 1
    got = 0
    for _ in range(12):
        for _ in range(200):
            if _i(dut.sample_ready):
                break
            await RisingEdge(dut.clk)
            await Timer(1, unit="ns")
        dut.start.value = 1
        await RisingEdge(dut.clk)
        dut.start.value = 0
        for _ in range(4000):
            await RisingEdge(dut.clk)
            await Timer(1, unit="ns")
            if _i(dut.out_valid):
                if _s(_i(dut.mix_sum), 64) != 0:
                    got = 1
                break
        if got:
            break
    assert got, "B x path produced zero mix_sum"


def _sources():
    C = os.path.join(_ROOT, "rtl", "core")
    S = os.path.join(_ROOT, "rtl", "synth")
    Y = os.path.join(_ROOT, "rtl", "simsynth")
    M = os.path.join(_ROOT, "rtl", "math", "pkg")
    return [os.path.join(M, "fxp_pkg.sv"),
            os.path.join(Y, "modal_step_pkg.sv"),
            os.path.join(C, "class_format_pkg.sv"),
            os.path.join(C, "class_loader.sv"),
            os.path.join(C, "class_loader64.sv"),
            os.path.join(C, "class_loader_mux.sv"),
            os.path.join(C, "poly_modal_lane.sv"),
            os.path.join(C, "modal_poly_bank.sv"),
            os.path.join(C, "modal_engine.sv"),
            os.path.join(C, "b_voice_ctrl.sv"),
            os.path.join(C, "b_a1_refresh.sv"),
            os.path.join(C, "b_a1_engine.sv"),
            os.path.join(C, "b_x_pool.sv"),
            os.path.join(C, "c_voice_timer.sv"),
            os.path.join(S, "synth_buf.sv"),
            os.path.join(S, "eng1_voice_top.sv"),
            os.path.join(S, "eng2_voice_top.sv"),
            os.path.join(S, "synth_top.sv"),
            os.path.join(Y, "modal_engine7.sv"),
            os.path.join(Y, "modal_voice_top.sv")]


if __name__ == "__main__":
    import argparse

    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--build-dir",
                    default=os.path.join(_ROOT, "sim", "build", "synth_top_bc"))
    a = ap.parse_args()
    rom = os.path.join(a.build_dir, "rom")
    _roms(rom)
    q = lambda n: '"' + os.path.join(rom, n) + '"'
    params = {
        "USE_BC": 1, "N_MODES": 4,
        "COEFF_DEPTH": 16, "INDEX_DEPTH": 1024,
        "BC_COEFF_DEPTH": 16, "BC_INDEX_DEPTH": 8192,
        "BC_CTRL_DEPTH": 1024, "BC_SEED_DEPTH": 1,
        "COEFF_FILE": q("a_coeff.mem"), "INDEX_FILE": q("a_index.mem"),
        "BC_COEFF_FILE": q("b_coeff.mem"), "BC_INDEX_FILE": q("b_index.mem"),
        "BC_CTRL_FILE": q("b_ctrl.mem"), "BC_SEED_FILE": q("c_seed.mem"),
    }
    summary = build_and_run(_sources(), "synth_top", "test_synth_top_bc",
                            _HERE, a.build_dir, params, {})
    print(f"[synth_top_bc] {summary['n']} tests PASS")
