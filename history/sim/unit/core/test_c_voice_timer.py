"""c_voice_timer 冒烟：length 到期与 choke 缩短。"""

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


async def _begin(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())


async def _reset(dut):
    dut.rst_n.value = 0
    for name, value in (("start", 0), ("length", 0), ("choke", 0)):
        getattr(dut, name).value = value
    for _ in range(4):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)
    await Timer(1, unit="ns")


@cocotb.test(timeout_time=60, timeout_unit="sec")
async def t01_length_and_choke(dut):
    await _begin(dut)
    await _reset(dut)

    # 正常到期
    dut.length.value = 10
    dut.start.value = 1
    await RisingEdge(dut.clk)
    dut.start.value = 0
    n = 0
    while not _i(dut.done) and n < 40:
        await RisingEdge(dut.clk)
        await Timer(1, unit="ns")
        n += 1
    assert _i(dut.done) == 1, f"done not raised after {n}"
    assert 9 <= n <= 12, n

    # choke 缩短长尾
    await _reset(dut)
    dut.length.value = 1000
    dut.start.value = 1
    await RisingEdge(dut.clk)
    dut.start.value = 0
    for _ in range(5):
        await RisingEdge(dut.clk)
    dut.choke.value = 1
    await RisingEdge(dut.clk)
    dut.choke.value = 0
    n = 0
    while not _i(dut.done) and n < 400:
        await RisingEdge(dut.clk)
        await Timer(1, unit="ns")
        n += 1
    assert _i(dut.done) == 1, "choked timer never finished"
    assert 235 <= n <= 245, n


def _sources():
    return [os.path.join(_ROOT, "rtl", "core", "c_voice_timer.sv")]


if __name__ == "__main__":
    import argparse

    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--build-dir",
                    default=os.path.join(_ROOT, "sim", "build", "c_voice_timer"))
    args = ap.parse_args()
    summary = build_and_run(_sources(), "c_voice_timer", "test_c_voice_timer",
                            _HERE, args.build_dir, {}, {})
    print(f"[c_voice_timer] {summary['n']} tests PASS")
