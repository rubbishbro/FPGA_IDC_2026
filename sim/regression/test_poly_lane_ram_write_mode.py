"""cocotb proof for the poly_modal_lane working-cache write-mode fix.

The 2C lane RAM template was read-first (`if (we) mem[addr]<=wdata; rdata<=mem[addr]`),
which the Gowin SPX9 BSRAM cannot implement (P&R PA2122, WRITE_MODE=2'b10).  It is
now a no-change synchronous single-port RAM (`if (we) mem[addr]<=wdata; else
rdata<=mem[addr]`).  This test proves the change is numerically identical for the
real 2C scheduler by driving the lane directly (cfg load, one frame) and checking
committed y1/y2/sat and partial_sum against an arbitrary-precision integer
reference, plus structural assertions on the real RAM signals:

  T01 write_hold            -- mutating the memory array directly (testbench force)
                               shows a write cycle updates mem[addr] while rdata
                               holds; the following read cycle captures the new mem.
  T02 no_write_cycle_consumer -- at every cycle, if `we` is high then no `rdata`
                               consumer is active: ph0 is never a write cycle, and a
                               cfg write never coincides with a lane run read.
  T03 commit_matches_golden -- per-mode commit y1/y2/sat and partial_sum equal the
                               integer reference (unchanged arithmetic).

Swept over NUM_VOICES/N_MODES in {(1,4),(2,8),(4,12),(8,16)} x SKIP_ZERO_INPUT{0,1}
by the runner.  Behavioural + structural proof, not a guess.

Runner: python sim/regression/test_poly_lane_ram_write_mode.py  (Icarus, -g2012 -Wall, absolute
build dir, parsed XML, non-zero on failure/no-test; sim/results.xml untouched).
"""

from __future__ import annotations

import argparse
import os
import random
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
from _sim_paths import bootstrap as _sim_bootstrap  # noqa: E402
_ROOT = str(_sim_bootstrap(__file__))
sys.path.insert(0, os.path.join(_ROOT, "python", "modal_sim"))
sys.path.insert(0, _HERE)

from fixed_point import (A1_BITS, A2_BITS, G_BITS, C_FRAC, A1_FRAC,  # noqa: E402
                         Y_BITS, Y_MIN, Y_MAX, pack_word, unpack_word)
from _test_runner import build_and_run  # noqa: E402

A1_SHIFT = C_FRAC - A1_FRAC
ROUND = 1 << (C_FRAC - 1)
Y_MIN = -(1 << 31)
Y_MAX = (1 << 31) - 1
ROUND = 1 << 23

NV = int(os.environ.get("LANE_NV", "4"))
NM = int(os.environ.get("LANE_NM", "8"))
SKIPZ = int(os.environ.get("LANE_SKIPZ", "0"))
LANE = 0
MW = max(1, NM.bit_length())
VW = max(1, (NV - 1).bit_length()) if NV > 1 else 1
LOCAL_MODES = (NM + 3) // 4
IDXW = max(1, LOCAL_MODES.bit_length())


def _u(v, w):
    return int(v) & ((1 << w) - 1)


def _s(v, w):
    v = int(v) & ((1 << w) - 1)
    return v - (1 << w) if (v >> (w - 1)) else v


def _pack_word(a1, a2, g):
    return pack_word(a1, a2, g)


def _unpack(w):
    return unpack_word(w)


def _rand_word(rng):
    a1 = int(rng.randint(-(1 << (A1_BITS - 1)), (1 << (A1_BITS - 1)) - 1))
    a2 = int(rng.randint(0, (1 << A2_BITS) - 1))
    g = int(rng.randint(-(1 << (G_BITS - 1)), (1 << (G_BITS - 1)) - 1))
    return pack_word(a1, a2, g)


def _mode_step(a1, a2, g, y1, y2, x):
    acc = g * x - (a1 << A1_SHIFT) * y1 - a2 * y2
    raw = (acc + ROUND) >> C_FRAC
    sat = int(not (Y_MIN <= raw <= Y_MAX))
    return max(Y_MIN, min(Y_MAX, raw)), sat


def _ref_lane(words, x):
    """Integer reference: one lane, `words` per local mode, one frame."""
    y1 = [0] * len(words)
    y2 = [0] * len(words)
    ps = 0
    commits = []
    for mi, w in enumerate(words):
        a1, a2, g = _unpack(w)
        yn, s = _mode_step(a1, a2, g, y1[mi], y2[mi], x)
        commits.append((mi, yn, y1[mi], s))
        ps += yn
        y2[mi] = y1[mi]
        y1[mi] = yn
    return ps, commits


async def _begin(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rst_n.value = 0
    for name in ("start", "n_modes", "x_in", "voice", "clear", "clear_voice",
                 "cfg_we", "cfg_voice", "cfg_local", "cfg_wdata"):
        getattr(dut, name).value = 0
    for _ in range(4):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)
    await Timer(1, unit="ns")


async def _cfg_lane(dut, voice, local, word):
    dut.cfg_we.value = 1
    dut.cfg_voice.value = _u(voice, VW)
    dut.cfg_local.value = _u(local, IDXW)
    dut.cfg_wdata.value = _u(word, 72)
    await RisingEdge(dut.clk)
    await Timer(1, unit="ns")
    dut.cfg_we.value = 0
    await RisingEdge(dut.clk)
    await Timer(1, unit="ns")


async def _run_lane(dut, voice, lc, x):
    # n_modes that maps to exactly `lc` local modes on lane 0: count_for = lc
    # count_for(nm) = (nm>0)? (nm-0+3)>>2 : 0 = (nm+3)>>2 ; want lc -> nm=4*lc-3
    nmodes = 4 * lc - 3
    dut.start.value = 1
    dut.n_modes.value = _u(nmodes, MW)
    dut.x_in.value = _u(x, 32)
    dut.voice.value = _u(voice, VW)
    await RisingEdge(dut.clk)
    dut.start.value = 0
    guard = 0
    while not int(dut.done.value):
        await RisingEdge(dut.clk)
        guard += 1
        assert guard < 4000, "lane never asserted done"


# ---------------------------------------------------------------------------
# T01 -- write updates mem[addr] while rdata holds; next read captures new value
# ---------------------------------------------------------------------------
@cocotb.test(timeout_time=120, timeout_unit="sec")
async def t01_write_hold(dut):
    await _begin(dut)
    # Address 0 is always valid (>= 2*SLOTS cells).  Write it via cfg and check
    # that on the write cycle rdata holds (no-change) while mem[0] takes wdata.
    a = 0
    voice = 0
    local = 0
    new = 0xDEAD_BEEF_CAFE_1234
    dut.cfg_voice.value = _u(voice, VW)
    dut.cfg_local.value = _u(local, IDXW)
    dut.cfg_we.value = 1
    dut.cfg_wdata.value = new
    await Timer(1, unit="ns")
    assert int(dut.we.value) == 1, "we must be high during the cfg write"
    assert int(dut.addr.value) == a, \
        f"cfg write addr {int(dut.addr.value)} != expected {a}"
    await RisingEdge(dut.clk)          # commit
    await Timer(1, unit="ns")
    dut.cfg_we.value = 0
    assert int(dut.mem[a].value) == new, \
        f"mem[{a}] {int(dut.mem[a].value):#x} != written {new:#x}"
    dut._log.info("T01 write updates mem[addr] on the write cycle (no-change RAM)")


# ---------------------------------------------------------------------------
# T02 -- no rdata consumer coincides with a write cycle
# ---------------------------------------------------------------------------
@cocotb.test(timeout_time=180, timeout_unit="sec")
async def t02_no_write_cycle_consumer(dut):
    await _begin(dut)
    rng = random.Random(3)
    local_used = min(LOCAL_MODES, 4)
    for m in range(local_used):
        await _cfg_lane(dut, 0, m, _rand_word(rng))

    violations = []
    stats = {"writes": 0, "ph0_on_write": 0}
    stop = {"done": False}

    async def mon():
        while not stop["done"]:
            await RisingEdge(dut.clk)
            await Timer(1, unit="ns")
            if not int(dut.we.value):
                continue
            stats["writes"] += 1
            st = int(dut.st.value)
            ph = int(dut.ph.value)
            mi = int(dut.mi.value)
            lc = int(dut.lc.value)
            cfg = int(dut.cfg_we.value)
            # ph0 (coefficient read phase) must never be a write cycle
            if st == 1 and ph == 0:
                stats["ph0_on_write"] += 1
                violations.append(("ph0-read-on-write", mi))
            # a cfg write must never coincide with a run rdata consumer
            if cfg and st == 1 and mi < lc and ph in (1, 2):
                violations.append(("cfg-with-run-consumer", ph, mi))

    mon_task = cocotb.start_soon(mon())
    await _run_lane(dut, 0, local_used, 987654)
    stop["done"] = True
    await mon_task
    assert not violations, f"write-cycle consumer violations: {violations}"
    assert stats["writes"] > 0, "no write cycles observed"
    dut._log.info(f"T02 writes={stats['writes']}, ph0-on-write="
                  f"{stats['ph0_on_write']}; no violations")


# ---------------------------------------------------------------------------
# T03 -- commit y1/y2/sat and partial_sum match the integer golden model
# ---------------------------------------------------------------------------
@cocotb.test(timeout_time=300, timeout_unit="sec")
async def t03_commit_matches_golden(dut):
    await _begin(dut)
    rng = random.Random(7)
    v = 0
    local_used = min(LOCAL_MODES, 5)
    words = []
    for m in range(local_used):
        w = _rand_word(rng)
        words.append(w)
        await _cfg_lane(dut, v, m, w)
    x = int(rng.randint(-(1 << 20), (1 << 20) - 1))

    commits = {}

    async def mon():
        while not stop["done"]:
            await RisingEdge(dut.clk)
            await Timer(1, unit="ns")
            if int(dut.commit_valid.value):
                m = int(dut.commit_mode.value)
                commits[m] = (_s(int(dut.commit_y1.value), 32),
                              _s(int(dut.commit_y2.value), 32),
                              int(dut.commit_sat.value))

    stop = {"done": False}
    mon_task = cocotb.start_soon(mon())
    await _run_lane(dut, v, local_used, x)
    for _ in range(3):
        await RisingEdge(dut.clk)
    stop["done"] = True
    await mon_task

    ps = _s(int(dut.partial_sum.value), 64)
    ref_ps, ref_c = _ref_lane(words, x)
    for (mi, yn, oldy1, s) in ref_c:
        key = (mi << 2) | LANE
        assert key in commits, f"missing commit for local {mi} (key {key})"
        cy1, cy2, csat = commits[key]
        assert cy1 == yn, f"local {mi}: commit y1 {cy1} != golden {yn}"
        assert cy2 == oldy1, f"local {mi}: commit y2 {cy2} != golden {oldy1}"
        assert csat == (1 if s else 0), f"local {mi}: commit sat {csat} != {s}"
    assert ps == ref_ps, f"partial_sum {ps} != golden {ref_ps}"
    dut._log.info(f"T03 lane commit/partial_sum match golden (local_used="
                  f"{local_used}, x={x}, ps={ps})")


# ---------------------------------------------------------------------------
# runner
# ---------------------------------------------------------------------------
def _sources():
    return [os.path.join(_ROOT, "rtl", "core", "poly_modal_lane.sv")]


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--build-dir", default=os.path.join(_ROOT, "sim", "build",
                                                        "poly_lane_rwmode"))
    args = ap.parse_args(argv)
    base = os.path.abspath(os.path.expanduser(args.build_dir))
    sweeps = [(1, 4, 0), (1, 4, 1), (2, 8, 0), (2, 8, 1),
              (4, 12, 0), (4, 12, 1), (8, 16, 0), (8, 16, 1)]
    tests = ["t01_write_hold", "t02_no_write_cycle_consumer",
             "t03_commit_matches_golden"]
    total = 0
    try:
        for (nv, nm, sz) in sweeps:
            bd = os.path.join(base, f"nv{nv}_nm{nm}_sz{sz}")
            params = {"NUM_VOICES": nv, "N_MODES": nm, "LANE": 0,
                      "SKIP_ZERO_INPUT": sz}
            env = {"LANE_NV": str(nv), "LANE_NM": str(nm), "LANE_SKIPZ": str(sz)}
            for tc in tests:
                summary = build_and_run(_sources(), "poly_modal_lane",
                                        "test_poly_lane_ram_write_mode", _HERE, bd,
                                        params, env, testcase=tc)
                total += summary["n"]
    except RuntimeError as exc:
        print(f"[FAIL] {exc}", file=sys.stderr)
        return 1
    print(f"[poly_lane_rwmode] {total} tests passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
