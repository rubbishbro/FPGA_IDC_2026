"""b_voice_ctrl 冒烟：NCO 周期、AR 包络、x 非零。"""

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


@cocotb.test(timeout_time=60, timeout_unit="sec")
async def t01_nco_and_env(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rst_n.value = 0
    for name, value in (("start", 0), ("gate", 1), ("base_inc", 0x40000000),
                        ("ratio", 0x8000), ("attack_step", 0x800000),
                        ("release_step", 0x800000), ("vel_q", 32768)):
        getattr(dut, name).value = value
    for _ in range(4):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)
    await Timer(1, unit="ns")

    dut.start.value = 1
    await RisingEdge(dut.clk)
    dut.start.value = 0

    imps, xs = [], []
    for n in range(24):
        await RisingEdge(dut.clk)
        await Timer(1, unit="ns")
        if _i(dut.imp):
            imps.append(n + 1)
            xs.append(_s(_i(dut.x), 32))
    assert 5 <= len(imps) <= 6, imps
    assert all(x > 0 for x in xs), xs
    # 包络应随脉冲递增（attack）
    assert xs == sorted(xs) and xs[-1] > xs[0], xs


def _sources():
    return [os.path.join(_ROOT, "rtl", "core", "b_voice_ctrl.sv")]


if __name__ == "__main__":
    import argparse

    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--build-dir",
                    default=os.path.join(_ROOT, "sim", "build", "b_voice_ctrl"))
    args = ap.parse_args()
    summary = build_and_run(_sources(), "b_voice_ctrl", "test_b_voice_ctrl",
                            _HERE, args.build_dir, {}, {})
    print(f"[b_voice_ctrl] {summary['n']} tests PASS")
