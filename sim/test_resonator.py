"""cocotb bit-exact test for rtl/core/resonator.sv (module 1).

The reference is the integer recursion in python/modal_sim/fixed_point.py, reproduced
here with the *same* quantiser/rounding constants so the check is "bit for bit".

Formats: state/x Q2.30 (32-bit, FS=30), G Q2.24 (26-bit), a1 Q2.20, a2 UQ0.24.

Coverage (reviewer's list):
  * random_coefficients   -- many random coefficient sets (not one) + edge sets
  * lowfreq_long_tail     -- 55 Hz below the guitar range, ~0.8 s of free decay
  * silence_gaps          -- valid_in low: valid_out low, state holds
  * runtime_reload        -- load mid-stream: state is cleared, new coeffs take over
  * load_valid_conflict   -- load wins when asserted together with valid_in
  * negative_saturation   -- clamps to Y_MIN with sat_out
  * half_lsb_rounding     -- an exact 0.5-LSB case, round-half-up verified

Run:  python sim/test_resonator.py
"""

from __future__ import annotations

import os
import sys

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = os.path.dirname(_HERE)
sys.path.insert(0, os.path.join(_ROOT, "python", "modal_sim"))
from fixed_point import (Y_BITS, Y_FRAC, Y_MIN, Y_MAX,  # noqa: E402
                         A1_FRAC, C_FRAC, G_BITS)

YW = Y_BITS          # 32
YF = Y_FRAC          # 30
GW = G_BITS          # 26
SH = C_FRAC - A1_FRAC
A1W, A2W = 22, 24


# ---------------------------------------------------------------------------
# Python reference: same recursion + the DUT's load/valid/priority semantics
# ---------------------------------------------------------------------------
class Ref:
    def __init__(self):
        self.a1 = self.a2 = self.g = 0
        self.y1 = self.y2 = self.yout = 0

    def _load(self, a1, a2, g):
        self.a1, self.a2, self.g = a1, a2, g
        self.y1 = self.y2 = 0

    def clock(self, op):
        kind = op[0]
        if kind in ("load", "lv"):                    # load has priority
            if kind == "load":
                _, a1, a2, g = op
            else:
                _, a1, a2, g, _x = op
            self._load(a1, a2, g)
            return (0, self.yout, 0)                  # y_out holds, valid/sat forced low
        if kind == "v":
            x = op[1]
            acc = self.g * x - (self.a1 << SH) * self.y1 - self.a2 * self.y2
            yn = (acc + (1 << (C_FRAC - 1))) >> C_FRAC
            sat = int(not (Y_MIN <= yn <= Y_MAX))
            yn = max(Y_MIN, min(Y_MAX, yn))
            self.y2, self.y1, self.yout = self.y1, yn, yn
            return (1, yn, sat)
        return (0, self.yout, 0)                      # 'n': no valid, state holds


def _u(val, w):
    return int(val) & ((1 << w) - 1)


def _s(v, w):
    v = int(v)
    return v - (1 << w) if v >= (1 << (w - 1)) else v


async def _begin(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())


async def _reset(dut):
    dut.rst_n.value = 0
    for sig in ("load", "valid_in", "x_in", "a1_in", "a2_in", "g_in"):
        getattr(dut, sig).value = 0
    for _ in range(4):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1


async def _script(dut, ops):
    """Reset the DUT, then drive one op per clock.  Returns (dut_out, ref_out)."""
    await _reset(dut)
    ref = Ref()
    duts, refs = [], []
    for op in ops:
        kind = op[0]
        if kind == "load":
            _, a1, a2, g = op
            dut.load.value = 1
            dut.a1_in.value = _u(a1, A1W)
            dut.a2_in.value = _u(a2, A2W)
            dut.g_in.value = _u(g, GW)
            dut.valid_in.value = 0
        elif kind == "lv":
            _, a1, a2, g, x = op
            dut.load.value = 1
            dut.a1_in.value = _u(a1, A1W)
            dut.a2_in.value = _u(a2, A2W)
            dut.g_in.value = _u(g, GW)
            dut.valid_in.value = 1
            dut.x_in.value = _u(x, YW)
        elif kind == "v":
            dut.load.value = 0
            dut.valid_in.value = 1
            dut.x_in.value = _u(op[1], YW)
        else:
            dut.load.value = 0
            dut.valid_in.value = 0
        refs.append(ref.clock(op))
        await RisingEdge(dut.clk)
        await Timer(1, unit="ns")
        duts.append((int(dut.valid_out.value), _s(dut.y_out.value, YW),
                     int(dut.sat_out.value)))
    return duts, refs


def _assert_eq(duts, refs, where=""):
    assert len(duts) == len(refs)
    for k, (d, r) in enumerate(zip(duts, refs)):
        assert d == r, f"{where} cycle {k}: dut {d} != ref {r}"


# ---------------------------------------------------------------------------
@cocotb.test()
async def random_coefficients(dut):
    """Many random coefficient sets (and edge sets), ~3k samples each, bit exact."""
    await _begin(dut)
    import numpy as np
    rng = np.random.default_rng(0)

    edge = [
        (0, 0, 0),
        (-(1 << 21) + 1, 0, 0),
        ((1 << 21) - 1, 0, 0),
        (0, (1 << 24) - 1, 0),
        (-(1 << 21) + 1, (1 << 24) - 1, (1 << (GW - 1)) - 1),
        (0, 0, -(1 << (GW - 1))),
    ]
    sets = list(edge)
    for _ in range(6):
        sets.append((int(rng.integers(-(1 << 21) + 1, 1 << 21)),
                     int(rng.integers(0, 1 << 24)),
                     int(rng.integers(-(1 << (GW - 1)), 1 << (GW - 1)))))

    total_sat = 0
    for t, (a1, a2, g) in enumerate(sets):
        ops = [("load", a1, a2, g)]
        for _ in range(3000):
            if rng.random() < 0.08:
                ops.append(("n",))
            else:
                ops.append(("v", int(rng.integers(-(1 << (YW - 1)), 1 << (YW - 1)))))
        duts, refs = await _script(dut, ops)
        _assert_eq(duts, refs, f"coeff set {t} {a1,a2,g}")
        total_sat += sum(d[2] for d in duts)
    dut._log.info(f"random: {len(sets)} coeff sets x 3000 samples bit-exact, "
                  f"{total_sat} saturations exercised")


@cocotb.test()
async def lowfreq_long_tail(dut):
    """55 Hz, r=0.99999, calibrated G, 7-sample pulse + ~0.83 s of free decay."""
    await _begin(dut)
    import math
    import numpy as np
    sr = 48000.0
    f, r = 55.0, 0.99999
    a1q = int(round(-2.0 * r * math.cos(2 * math.pi * f / sr) * (1 << A1_FRAC)))
    a2q = int(round(r * r * (1 << 24)))
    plen, theta = 7, 2.0 * math.pi * f / sr
    n = np.arange(plen)
    pulse = 0.5 - 0.5 * np.cos(2.0 * np.pi * n / plen)
    P = float(np.abs(np.exp(-1j * theta * n).dot(pulse)))
    gq = int(round(1.0 * math.sin(theta) / P * (1 << 24)))

    ops = [("load", a1q, a2q, gq)]
    ops += [("v", int(round(pulse[i] * (1 << YF)))) for i in range(plen)]
    ops += [("v", 0)] * 40000
    duts, refs = await _script(dut, ops)
    _assert_eq(duts, refs, "lowfreq")
    assert sum(d[2] for d in duts) == 0, "unexpected saturation"
    dut._log.info("lowfreq long tail: 40007 samples bit-exact, no saturation")


@cocotb.test()
async def silence_gaps(dut):
    """valid_in low -> valid_out low and the state holds; resume stays bit exact."""
    await _begin(dut)
    ops = [("load", 0, int(0.9 * (1 << 24)), 1 << 20)]
    ops += [("v", 1 << 28)] * 20
    ops += [("n",)] * 50
    ops += [("v", 0)] * 100
    duts, refs = await _script(dut, ops)
    _assert_eq(duts, refs, "silence")
    for k in range(21, 71):                         # the gap region (ops 21..70)
        assert duts[k][0] == 0, f"valid_out high during gap at {k}"
        assert duts[k][1] == refs[k][1] == duts[20][1], "state did not hold in gap"
    dut._log.info("silence gaps: valid_out gated, state held, bit-exact")


@cocotb.test()
async def runtime_reload(dut):
    """Load mid-stream clears the state and switches coefficients."""
    await _begin(dut)
    a1, a2, g = 0, int(0.95 * (1 << 24)), 1 << 24
    b1, b2, bg = -(1 << 20), int(0.5 * (1 << 24)), 1 << 24
    ops = [("load", a1, a2, g)]
    ops += [("v", 1 << 29)] * 300
    ops += [("load", b1, b2, bg)]                   # <-- reload
    ops += [("v", 1 << 29)] * 300
    duts, refs = await _script(dut, ops)
    _assert_eq(duts, refs, "reload")
    assert duts[301][0] == 0, "valid_out must be low on the load cycle"
    dut._log.info("runtime reload: state cleared, new coefficients, bit-exact")


@cocotb.test()
async def load_valid_conflict(dut):
    """load asserted together with valid_in must win (load priority)."""
    await _begin(dut)
    a1, a2, g = 0, int(0.9 * (1 << 24)), 1 << 24
    b1, b2, bg = -(1 << 20), int(0.9 * (1 << 24)), 1 << 24
    ops = [("load", a1, a2, g)]
    ops += [("v", 1 << 29)] * 50
    ops += [("lv", b1, b2, bg, 1 << 30)]            # conflict
    ops += [("v", 1 << 29)] * 50
    duts, refs = await _script(dut, ops)
    _assert_eq(duts, refs, "conflict")
    assert duts[51][0] == 0, "load must force valid_out low on the conflict cycle"
    dut._log.info("load/valid conflict: load priority, bit-exact")


@cocotb.test()
async def negative_saturation(dut):
    """G*x driven far negative must clamp to Y_MIN with sat_out high."""
    await _begin(dut)
    a1, a2, g = 0, 0, (1 << (GW - 1)) - 1           # G ~ +2
    x = -(1 << (YW - 1))                            # most negative x
    ops = [("load", a1, a2, g), ("v", x), ("v", x)]
    duts, refs = await _script(dut, ops)
    _assert_eq(duts, refs, "negsat")
    assert duts[1] == (1, Y_MIN, 1), f"expected clamp to Y_MIN, got {duts[1]}"
    dut._log.info("negative saturation: clamped to Y_MIN with sat_out, bit-exact")


@cocotb.test()
async def half_lsb_rounding(dut):
    """Exact 0.5-LSB case -> round half up.

    a1 = 2^-1 (Q2.20), a2 = 0, G = 1.  Step with x = 2^30+1 sets y1 = 2^30+1 (odd).
    Next step (x=0) gives acc/2^24 = -(2^30+1)/2 = -2^29 - 0.5  ->  -2^29.
    """
    await _begin(dut)
    a1 = 1 << (A1_FRAC - 1)                          # 2^19 = Q2.20 0.5
    a2 = 0
    g = 1 << 24                                      # G = 1.0
    ops = [("load", a1, a2, g), ("v", (1 << 30) + 1), ("v", 0)]
    duts, refs = await _script(dut, ops)
    _assert_eq(duts, refs, "half-lsb")
    expect = -(1 << (YF - 1))                         # -2^29
    assert refs[2] == (1, expect, 0), f"model half-up wrong: {refs[2]}"
    assert duts[2] == refs[2], f"rtl half-up {duts[2]} != model {refs[2]}"
    dut._log.info(f"half-LSB: round-half-up -> {expect} (model and RTL agree)")


# ---------------------------------------------------------------------------
if __name__ == "__main__":
    from cocotb_tools.runner import get_runner

    runner = get_runner("icarus")
    build_dir = os.path.join(_HERE, "build", "resonator")
    src = os.path.join(_ROOT, "rtl", "core", "resonator.sv")
    runner.build(sources=[src], hdl_toplevel="resonator",
                 build_dir=build_dir, waves=True)
    runner.test(hdl_toplevel="resonator", test_module="test_resonator",
                test_dir=_HERE, build_dir=build_dir, waves=True)
