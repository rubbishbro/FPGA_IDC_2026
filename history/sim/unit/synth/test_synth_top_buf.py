"""synth_top USE_BUF=1：A 的系数从 BUF 读，而不是 coeff_rom。"""

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
sys.path.insert(0, os.path.join(_ROOT, "sim", "support"))
from _test_runner import build_and_run  # noqa: E402


def _i(sig):
    try:
        return int(sig.value)
    except ValueError:
        return 0


def _s(v, w):
    v = int(v) & ((1 << w) - 1)
    return v - (1 << w) if v & (1 << (w - 1)) else v


async def _reset(dut):
    dut.rst_n.value = 0
    for name, value in (
        ("buf_wr_en", 0), ("buf_wr_engine", 0), ("buf_wr_addr", 0),
        ("buf_wr_data", 0), ("res_we", 0), ("res_engine", 0),
        ("res_bank", 0), ("res_data", 0),
        ("load_valid", 0), ("load_voice", 0), ("load_instrument", 0),
        ("load_midi", 0), ("load_dyn", 1), ("load_vel", 255),
        ("load_class", 0), ("load_note_id", 0), ("ctrl_rd_voice", 0),
        ("b_class_vec", 0), ("b_vel_vec", 0), ("b_start_mask", 0),
        ("b_gate_mask", 0), ("b_ratio", 0x8000), ("a1_enable", 0),
        ("start", 0), ("active_mask", 0), ("x_vec", 0),
        ("rd_en", 0), ("rd_addr", 0),
    ):
        getattr(dut, name).value = value
    for _ in range(4):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)
    await Timer(1, unit="ns")


@cocotb.test(timeout_time=120, timeout_unit="sec")
async def t01_buf_coeff(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)

    # 把 A 的系数表写进 BUF（ENG1 region）
    rom = os.path.join(_ROOT, "rtl", "rom", "modal_coeff.mem")
    words = [int(line.strip(), 16) for line in open(rom) if line.strip()]
    for addr, w in enumerate(words):
        dut.buf_wr_en.value = 1
        dut.buf_wr_engine.value = 0
        dut.buf_wr_addr.value = addr
        dut.buf_wr_data.value = w
        await RisingEdge(dut.clk)
    dut.buf_wr_en.value = 0
    await RisingEdge(dut.clk)
    await Timer(1, unit="ns")
    dut._log.info("mem1[0]=%x mem1[12]=%x words0=%x",
                  int(dut.u_buf.mem1[0].value),
                  int(dut.u_buf.mem1[12].value), words[0])

    dut.load_valid.value = 1
    dut.load_voice.value = 0
    dut.load_instrument.value = 1
    dut.load_midi.value = 21
    dut.load_dyn.value = 1
    dut.load_vel.value = 255
    done = 0
    seen = 0
    u = dut.u_eng1.u_engine.u_loader
    for _ in range(3000):
        await RisingEdge(dut.clk)
        await Timer(1, unit="ns")
        if _i(dut.load_done):
            done = 1
            break
    dut.load_valid.value = 0
    assert done, "load_done not raised"
    assert _i(dut.loaded_n_modes) > 0

    for _ in range(200):
        if _i(dut.sample_ready):
            break
        await RisingEdge(dut.clk)
        await Timer(1, unit="ns")
    dut.active_mask.value = 1
    dut.x_vec.value = 1 << 30
    dut.start.value = 1
    await RisingEdge(dut.clk)
    dut.start.value = 0
    got = 0
    for _ in range(6000):
        await RisingEdge(dut.clk)
        await Timer(1, unit="ns")
        if _i(dut.out_valid):
            got = _s(_i(dut.mix_sum), 64)
            break
    assert got != 0, "BUF-read A produced zero mix_sum"


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
                    default=os.path.join(_ROOT, "sim", "build", "synth_top_buf"))
    a = ap.parse_args()
    rom = os.path.join(_ROOT, "rtl", "rom")
    q = lambda n: '"' + os.path.join(rom, n) + '"'
    params = {
        "USE_BUF": 1, "N_MODES": 48,
        "COEFF_DEPTH": 5483, "INDEX_DEPTH": 1024,
        "COEFF_FILE": q("modal_coeff.mem"), "INDEX_FILE": q("modal_index.mem"),
    }
    summary = build_and_run(_sources(), "synth_top", "test_synth_top_buf",
                            _HERE, a.build_dir, params, {})
    print(f"[synth_top_buf] {summary['n']} tests PASS")
