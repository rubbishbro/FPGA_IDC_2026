"""synth_top 冒烟测试：ENG1 A 路径经共享 BUF 顶层的 load -> sample -> result。

不是逐位 golden（那个由 core/engine 覆盖）；这里只验证新顶层的
load_done / start / sample_ready / out_valid / mix_sum 通路和 BUF 写口。
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
sys.path.insert(0, os.path.join(_ROOT, "sim", "support"))
from _test_runner import build_and_run  # noqa: E402


def _i(sig):
    try:
        return int(sig.value)
    except ValueError:
        return 0


def _s(value, width):
    value = int(value) & ((1 << width) - 1)
    return value - (1 << width) if value & (1 << (width - 1)) else value


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
        ("c_length_vec", 0), ("c_choke_mask", 0),
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
async def t01_load_and_one_frame(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)

    # 装载 piano 21 forte
    dut.load_valid.value = 1
    dut.load_voice.value = 0
    dut.load_instrument.value = 1
    dut.load_midi.value = 21
    dut.load_dyn.value = 1
    dut.load_vel.value = 255
    load_done = 0
    for _ in range(2000):
        await RisingEdge(dut.clk)
        await Timer(1, unit="ns")
        if _i(dut.load_done):
            load_done = 1
            break
    dut.load_valid.value = 0
    dut._log.info("dbg ready=%d busy=%d err=%d code=%d n=%d done=%d",
                  _i(dut.load_ready), _i(dut.busy), _i(dut.error_valid),
                  _i(dut.error_code), _i(dut.loaded_n_modes), _i(dut.load_done))
    assert load_done, "load_done 未拉高"
    assert _i(dut.loaded_n_modes) > 0

    # 两帧：先等 sample_ready，再打一拍 start
    async def frame(x):
        for _ in range(200):
            if _i(dut.sample_ready):
                break
            await RisingEdge(dut.clk)
            await Timer(1, unit="ns")
        assert _i(dut.sample_ready), "sample_ready 未拉高"
        dut.active_mask.value = 1
        dut.x_vec.value = x
        dut.start.value = 1
        await RisingEdge(dut.clk)
        dut.start.value = 0
        for _ in range(6000):
            await RisingEdge(dut.clk)
            await Timer(1, unit="ns")
            if _i(dut.out_valid):
                return _s(_i(dut.mix_sum), 64)
        assert False, "out_valid 未拉高"

    y0 = await frame(1 << 30)
    assert y0 != 0, "第一帧 mix_sum 为 0"
    # 结果 BUF 读口：第一帧写 bank0
    dut.rd_en.value = 1
    dut.rd_addr.value = 0
    await RisingEdge(dut.clk)
    dut.rd_en.value = 0
    for _ in range(10):
        await RisingEdge(dut.clk)
        await Timer(1, unit="ns")
        if _i(dut.rd_valid):
            assert _s(_i(dut.rd_data), 64) == y0
            break
    y1 = await frame(0)
    assert y1 != 0, "第二帧 mix_sum 为 0"


def _sources():
    C = os.path.join(_ROOT, "rtl", "core")
    S = os.path.join(_ROOT, "rtl", "synth")
    Y = os.path.join(_ROOT, "rtl", "simsynth")
    M = os.path.join(_ROOT, "rtl", "math", "pkg")
    return [os.path.join(M, "fxp_pkg.sv"),
            os.path.join(Y, "modal_step_pkg.sv"),
            os.path.join(S, "synth_buf.sv"),
            os.path.join(S, "eng1_voice_top.sv"),
            os.path.join(S, "eng2_voice_top.sv"),
            os.path.join(S, "synth_top.sv"),
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
            os.path.join(Y, "modal_engine7.sv"),
            os.path.join(Y, "modal_voice_top.sv")]


if __name__ == "__main__":
    import argparse

    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--build-dir",
                    default=os.path.join(_ROOT, "sim", "build", "synth_top"))
    args = ap.parse_args()
    rom = os.path.join(_ROOT, "rtl", "rom")
    params = {
        "COEFF_FILE": '"' + os.path.join(rom, "modal_coeff.mem") + '"',
        "INDEX_FILE": '"' + os.path.join(rom, "modal_index.mem") + '"',
    }
    summary = build_and_run(_sources(), "synth_top", "test_synth_top",
                            _HERE, args.build_dir, params, {})
    print(f"[synth_top] {summary['n']} tests PASS")
