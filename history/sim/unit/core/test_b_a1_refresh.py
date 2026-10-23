"""b_a1_refresh 冒烟：ratio=1 回到 a1_nom；小 ratio 偏移接近精确 cos。"""

from __future__ import annotations

import math
import os
import sys

import cocotb
from cocotb.triggers import Timer

_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = _HERE
while not (os.path.isdir(os.path.join(_ROOT, "rtl"))
           and os.path.isdir(os.path.join(_ROOT, "sim"))):
    _ROOT = os.path.dirname(_ROOT)
sys.path.insert(0, os.path.join(_ROOT, "sim", "support"))
from _test_runner import build_and_run  # noqa: E402


def _s(v, w):
    v = int(v) & ((1 << w) - 1)
    return v - (1 << w) if v & (1 << (w - 1)) else v


def _q(v, frac, width):
    return int(round(v * (1 << frac))) & ((1 << width) - 1)


@cocotb.test(timeout_time=60, timeout_unit="sec")
async def t01_ratio(dut):
    r = 0.999
    theta = 0.5
    a1 = -2.0 * r * math.cos(theta)
    a2 = r * r
    a1_q = _q(a1, 20, 22)
    a2_q = _q(a2, 24, 24)
    th_q = _q(theta, 14, 16)

    dut.a1_nom.value = a1_q
    dut.a2.value = a2_q
    dut.theta.value = th_q

    for ratio, tol in ((1.0, 2), (1.01, 3000), (0.99, 3000)):
        dut.ratio.value = _q(ratio, 15, 16)
        await Timer(1, unit="ns")
        got = _s(dut.a1_new.value, 22)
        exp = -2.0 * r * math.cos(theta * ratio)
        exp_q = int(round(exp * (1 << 20)))
        assert abs(got - exp_q) <= tol, (
            f"ratio={ratio}: got {got} exp {exp_q} (a1 {a1:.6f})")
        if ratio == 1.0:
            assert abs(got - _s(a1_q, 22)) <= 2, (got, a1_q)


def _sources():
    return [os.path.join(_ROOT, "rtl", "core", "b_a1_refresh.sv")]


if __name__ == "__main__":
    import argparse

    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--build-dir",
                    default=os.path.join(_ROOT, "sim", "build", "b_a1_refresh"))
    a = ap.parse_args()
    summary = build_and_run(_sources(), "b_a1_refresh", "test_b_a1_refresh",
                            _HERE, a.build_dir, {}, {})
    print(f"[b_a1_refresh] {summary['n']} tests PASS")
