"""b_x_pool 冒烟：两个 B 声部、不同周期、class 门控。"""

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


def _ctrl(base_inc, atk=0x800000, rel=0x800000, period=4):
    return (base_inc << 64) | (rel << 40) | (atk << 16) | period


def _x(dut, v):
    return _s((_i(dut.x_vec) >> (v * 32)) & 0xFFFFFFFF, 32)


@cocotb.test(timeout_time=60, timeout_unit="sec")
async def t01_two_voices(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rst_n.value = 0
    dut.ctrl_vec.value = (_ctrl(0x20000000) << 256) | _ctrl(0x40000000)
    dut.class_vec.value = 0b0101        # 两个都是 B（每声部 2-bit = 1）
    dut.vel_vec.value = (32768 << 16) | 32768
    dut.start_mask.value = 0b11
    dut.gate_mask.value = 0b11
    dut.ratio.value = 0x8000
    for _ in range(4):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)
    if _i(dut.start_mask):
        dut.start_mask.value = 0       # start 是单拍；这里让第一拍生效
    await Timer(1, unit="ns")

    counts = [0, 0]
    for _ in range(20):
        await RisingEdge(dut.clk)
        await Timer(1, unit="ns")
        for v in range(2):
            if _x(dut, v) != 0:
                counts[v] += 1
    assert counts[0] >= 3, counts
    assert counts[1] >= 1, counts
    assert counts[0] > counts[1], counts


@cocotb.test(timeout_time=60, timeout_unit="sec")
async def t02_class_gate(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rst_n.value = 0
    dut.ctrl_vec.value = _ctrl(0x40000000) | (_ctrl(0x40000000) << 256)
    dut.class_vec.value = 0b01          # voice1 = A，不应出声
    dut.vel_vec.value = (32768 << 16) | 32768
    dut.start_mask.value = 0b11
    dut.gate_mask.value = 0b11
    dut.ratio.value = 0x8000
    for _ in range(4):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)
    await Timer(1, unit="ns")

    for _ in range(20):
        await RisingEdge(dut.clk)
        await Timer(1, unit="ns")
        assert _x(dut, 1) == 0, "class A voice produced B x"


def _sources():
    return [os.path.join(_ROOT, "rtl", "core", "b_voice_ctrl.sv"),
            os.path.join(_ROOT, "rtl", "core", "b_x_pool.sv")]


if __name__ == "__main__":
    import argparse

    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--build-dir",
                    default=os.path.join(_ROOT, "sim", "build", "b_x_pool"))
    a = ap.parse_args()
    summary = build_and_run(_sources(), "b_x_pool", "test_b_x_pool",
                            _HERE, a.build_dir, {"NUM_VOICES": 2}, {})
    print(f"[b_x_pool] {summary['n']} tests PASS")
