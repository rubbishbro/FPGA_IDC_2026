"""cocotb regression for rtl/core/modal_poly_bank.sv (module 2C, bank direct).

Drives the bank's cfg/clear/sample ports directly (no loader) so that every
mode count, mask and illegal request can be injected.  Checks per-commit state
and saturation, per-voice sums, the mix sum and saturation count against an
arbitrary-precision integer reference, including real 72-bit notes.

Runner: ``python sim/unit/core/test_modal_poly_bank.py``.  Icarus + always=True, explicit
-g2012/-Wall, absolute paths, parsed XML, non-zero on any failure/no-test.
Artefacts under ``sim/build/modal_poly_bank/``; ``sim/results.xml`` untouched.
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

from fixed_point import (A1_BITS, A1_FRAC, A2_BITS, G_BITS, C_FRAC,  # noqa: E402
                         Y_BITS, Y_FRAC, Y_MIN, Y_MAX, pack_word, unpack_word)
from _test_runner import build_and_run  # noqa: E402

PARAMS = os.path.join(_ROOT, "FFT_results", "params")
A1_SHIFT = C_FRAC - A1_FRAC

N_CFG = int(os.environ.get("POLYBANK_NMODES", "48"))
V_CFG = int(os.environ.get("POLYBANK_NUMVOICES", "32"))
SKIPZ = int(os.environ.get("POLYBANK_SKIPZERO", "0"))
MW = max(1, N_CFG.bit_length())
VW = max(1, (V_CFG - 1).bit_length()) if V_CFG > 1 else 1
SW = max(1, (V_CFG * N_CFG).bit_length())

_MEM_CACHE = {}


def _inst_mem(name):
    if name not in _MEM_CACHE:
        _MEM_CACHE[name] = [int(l.strip(), 16)
                            for l in open(os.path.join(PARAMS, f"{name}_coeff.mem"))
                            if l.strip()]
    return _MEM_CACHE[name]


def _inst_index(name):
    import json
    return json.load(open(os.path.join(PARAMS, f"{name}_coeffindex.json")))


def _note_words(name, midi, dyn):
    idx = _inst_index(name)
    meta = idx[f"{midi}|{dyn}"]
    mem = _inst_mem(name)
    return mem[meta["offset"]:meta["offset"] + meta["n_modes"]]


def _u(v, w):
    return int(v) & ((1 << w) - 1)


def _s(v, w):
    v = int(v) & ((1 << w) - 1)
    return v - (1 << w) if (v >> (w - 1)) else v


def _i(sig):
    try:
        return int(sig.value)
    except ValueError:
        return 0


def _field(sig, total, lo, width):
    b = str(sig.value)
    field = b[total - lo - width: total - lo]
    if any(c in field for c in "xzXZ"):
        return None
    return int(field, 2)


def _mode_step(a1, a2, G, y1, y2, x):
    acc = G * x - (a1 << A1_SHIFT) * y1 - a2 * y2
    raw = (acc + (1 << (C_FRAC - 1))) >> C_FRAC
    sat = int(not (Y_MIN <= raw <= Y_MAX))
    return max(Y_MIN, min(Y_MAX, raw)), sat


def _rand_word(rng):
    a1 = int(rng.integers(-(1 << (A1_BITS - 1)), 1 << (A1_BITS - 1)))
    a2 = int(rng.integers(0, 1 << A2_BITS))
    G = int(rng.integers(-(1 << (G_BITS - 1)), 1 << (G_BITS - 1)))
    return pack_word(a1, a2, G)


def _rand_x(rng):
    return int(rng.integers(-(1 << (Y_BITS - 1)), (1 << (Y_BITS - 1))))


class RefPoly:
    """Arbitrary-precision reference for the whole multi-voice bank."""

    def __init__(self, nv=V_CFG, nm=N_CFG):
        self.nv, self.nm = nv, nm
        self.words = [dict() for _ in range(nv)]
        self.y1 = [[0] * nm for _ in range(nv)]
        self.y2 = [[0] * nm for _ in range(nv)]

    def cfg(self, v, m, w):
        self.words[v][m] = w

    def clear(self, v):
        self.y1[v] = [0] * self.nm
        self.y2[v] = [0] * self.nm

    def loaded(self, v, n):
        return all(m in self.words[v] for m in range(n))

    def step(self, act, nvec, xvec):
        commits, voices = {}, {}
        newy = {}
        sat_total = 0
        for v in range(self.nv):
            if not act[v]:
                continue
            n = nvec[v]
            acc_sum = 0
            newy[v] = [0] * n
            for k in range(n):
                a1, a2, G = unpack_word(self.words[v][k])
                yn, s = _mode_step(a1, a2, G, self.y1[v][k], self.y2[v][k],
                                   xvec[v])
                newy[v][k] = yn
                commits[(v, k)] = (yn, self.y1[v][k], s)
                acc_sum += yn
                sat_total += s
            voices[v] = acc_sum
        for v in range(self.nv):
            if not act[v]:
                continue
            for k in range(len(newy[v])):
                self.y2[v][k] = self.y1[v][k]
                self.y1[v][k] = newy[v][k]
        return commits, voices, sat_total


# ---------------------------------------------------------------------------
# drivers
# ---------------------------------------------------------------------------
async def _begin(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())


async def _reset(dut):
    dut.rst_n.value = 0
    for name, val in (("cfg_valid", 0), ("cfg_voice", 0), ("cfg_mode", 0),
                      ("cfg_word", 0), ("clear_valid", 0), ("clear_voice", 0),
                      ("sample_valid", 0), ("active_mask", 0),
                      ("n_modes_vec", 0), ("x_vec", 0)):
        getattr(dut, name).value = val
    for _ in range(4):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)
    await Timer(1, unit="ns")


async def _cfg(dut, voice, mode, word):
    dut.cfg_valid.value = 1
    dut.cfg_voice.value = _u(voice, VW)
    dut.cfg_mode.value = _u(mode, MW)
    dut.cfg_word.value = _u(word, 72)
    await Timer(1, unit="ns")
    guard = 0
    while not _i(dut.cfg_ready):
        await RisingEdge(dut.clk)
        await Timer(1, unit="ns")
        guard += 1
        assert guard < 100, "cfg_ready stuck"
    await RisingEdge(dut.clk)
    dut.cfg_valid.value = 0
    await Timer(1, unit="ns")
    return _i(dut.error_valid), _i(dut.error_code)


async def _clear(dut, voice):
    dut.clear_valid.value = 1
    dut.clear_voice.value = _u(voice, VW)
    await Timer(1, unit="ns")
    guard = 0
    while not _i(dut.clear_ready):
        await RisingEdge(dut.clk)
        await Timer(1, unit="ns")
        guard += 1
        assert guard < 100
    await RisingEdge(dut.clk)
    dut.clear_valid.value = 0
    await Timer(1, unit="ns")
    return _i(dut.error_valid), _i(dut.error_code), _i(dut.clear_done)


def _pack_nvec(nvec):
    w = 0
    for v, n in enumerate(nvec):
        w |= (int(n) & ((1 << MW) - 1)) << (v * MW)
    return w


def _pack_xvec(xvec):
    w = 0
    for v, x in enumerate(xvec):
        w |= _u(x, 32) << (v * 32)
    return w


async def _frame(dut, act, nvec, xvec, timeout=400000):
    dut.active_mask.value = _u(act, V_CFG)
    dut.n_modes_vec.value = _pack_nvec(nvec)
    dut.x_vec.value = _pack_xvec(xvec)
    dut.sample_valid.value = 1
    await Timer(1, unit="ns")
    guard = 0
    while not _i(dut.sample_ready):
        await RisingEdge(dut.clk)
        await Timer(1, unit="ns")
        guard += 1
        assert guard < 200, "sample_ready stuck"
    await RisingEdge(dut.clk)
    dut.sample_valid.value = 0
    await Timer(1, unit="ns")

    commits, voices = {}, []
    cyc = 0
    while True:
        cv = _i(dut.commit_valid)
        for i in range(4):
            if (cv >> i) & 1:
                v = _field(dut.commit_voice, 4 * VW, i * VW, VW)
                m = _field(dut.commit_mode, 4 * MW, i * MW, MW)
                y1 = _field(dut.commit_y1, 128, i * 32, 32)
                y2 = _field(dut.commit_y2, 128, i * 32, 32)
                assert None not in (v, m, y1, y2), "X on the commit bus"
                y1, y2 = _s(y1, 32), _s(y2, 32)
                key = (v, m)
                assert key not in commits, f"duplicate commit {key}"
                commits[key] = (y1, y2, (_i(dut.commit_sat) >> i) & 1)
        if _i(dut.voice_valid):
            voices.append((_i(dut.voice_id), _s(_i(dut.voice_sum), 64)))
        if _i(dut.out_valid):
            return (cyc, commits, voices, _s(_i(dut.mix_sum), 64),
                    _i(dut.sat_count))
        cyc += 1
        assert cyc < timeout, "frame did not finish"
        await RisingEdge(dut.clk)
        await Timer(1, unit="ns")


def _compare(res, exp_commits, exp_voices, exp_sat, where=""):
    cyc, commits, voices, mix, sat = res
    assert set(commits) == set(exp_commits), \
        f"{where}: commit set differs: {sorted(set(commits) ^ set(exp_commits))}"
    for k in exp_commits:
        assert commits[k] == exp_commits[k], \
            f"{where}: commit {k} dut {commits[k]} != ref {exp_commits[k]}"
    got_voices = dict(voices)
    assert got_voices == exp_voices, \
        f"{where}: voice sums differ: {got_voices} != {exp_voices}"
    assert sum(exp_voices.values()) == mix, \
        f"{where}: mix {mix} != {sum(exp_voices.values())}"
    assert sat == exp_sat, f"{where}: sat_count {sat} != {exp_sat}"
    return cyc


# ---------------------------------------------------------------------------
# B01 -- reset, zero mask
# ---------------------------------------------------------------------------
@cocotb.test(timeout_time=60, timeout_unit="sec")
async def b01_reset_zero_mask(dut):
    await _begin(dut)
    await _reset(dut)
    for name in ("busy", "out_valid", "voice_valid", "error_valid", "clear_done",
                 "commit_valid"):
        assert getattr(dut, name).value.is_resolvable, f"{name} X after reset"
    assert _i(dut.cfg_ready) == 1 and _i(dut.clear_ready) == 1
    assert _i(dut.sample_ready) == 1
    res = await _frame(dut, 0, [0] * V_CFG, [0] * V_CFG)
    cyc, commits, voices, mix, sat = res
    assert commits == {} and voices == [] and mix == 0 and sat == 0, res
    assert _i(dut.busy) == 0, "busy still high after out_valid"
    dut._log.info(f"B01 reset/zero-mask OK ({cyc} cycles)")


# ---------------------------------------------------------------------------
# B02 -- direct cfg mode counts and masks
# ---------------------------------------------------------------------------
@cocotb.test(timeout_time=900, timeout_unit="sec")
async def b02_counts_masks(dut):
    await _begin(dut)
    import numpy as np
    rng = np.random.default_rng(2026)
    await _reset(dut)
    ref = RefPoly()
    NMAX = min(N_CFG, 48)
    words = [_rand_word(rng) for _ in range(NMAX)]
    for v in range(V_CFG):
        for m in range(NMAX):
            ev, ec = await _cfg(dut, v, m, words[m])
            assert ev == 0 and ec == 0
            ref.cfg(v, m, words[m])

    counts = [n for n in (0, 1, 3, 4, 5, 47, 48) if n <= N_CFG]
    masks = {
        "none": 0,
        "v0": 1,
        "vlast": 1 << (V_CFG - 1),
        "interleave": int(sum(1 << v for v in range(0, V_CFG, 2))),
        "all": (1 << V_CFG) - 1,
    }
    worst = 0
    for name, act in masks.items():
        for n in counts:
            nvec = [0] * V_CFG
            xvec = [0] * V_CFG
            for v in range(V_CFG):
                if (act >> v) & 1:
                    nvec[v] = n
                    xvec[v] = _rand_x(rng)
            res = await _frame(dut, act, nvec, xvec)
            exp_c, exp_v, exp_s = ref.step(
                [bool((act >> v) & 1) for v in range(V_CFG)], nvec, xvec)
            cyc = _compare(res, exp_c, exp_v, exp_s, f"B02 {name} n={n}")
            worst = max(worst, cyc)
    budget = 1800
    assert worst <= budget, f"B02 worst frame {worst} > {budget}"
    dut._log.info(f"B02 counts/masks bit-exact, worst {worst}<={budget}")


# ---------------------------------------------------------------------------
# B03 -- inactive frozen, reactivation resumes, address isolation
# ---------------------------------------------------------------------------
@cocotb.test(timeout_time=600, timeout_unit="sec")
async def b03_frozen_isolation(dut):
    await _begin(dut)
    import numpy as np
    rng = np.random.default_rng(3)
    await _reset(dut)
    ref = RefPoly()
    n = min(N_CFG, 12)
    # distinct marker word per (voice, mode): a cross-voice address bug shows up
    for v in range(V_CFG):
        for m in range(n):
            w = _rand_word(rng) ^ ((v * 131 + m * 17) & 0xFFFF)
            ev, ec = await _cfg(dut, v, m, w)
            assert ev == 0
            ref.cfg(v, m, w)

    masks = [0b1, 0b10, 0b11, 0b101, (1 << V_CFG) - 1,
             0b1001, (1 << (V_CFG - 1))]
    seq = []
    for i, act in enumerate(masks):
        act &= (1 << V_CFG) - 1
        nvec = [n] * V_CFG
        xvec = [_rand_x(rng) for _ in range(V_CFG)]
        res = await _frame(dut, act, nvec, xvec)
        exp_c, exp_v, exp_s = ref.step(
            [bool((act >> v) & 1) for v in range(V_CFG)], nvec, xvec)
        _compare(res, exp_c, exp_v, exp_s, f"B03 seq {i} act={act:#x}")
        seq.append(act)
    dut._log.info("B03 inactive frozen, reactivation correct, no cross-voice leak")


# ---------------------------------------------------------------------------
# B04 -- real piano MIDI21 forte across all voices, >=100 frames
# ---------------------------------------------------------------------------
@cocotb.test(timeout_time=1800, timeout_unit="sec")
async def b04_real_piano_32voice(dut):
    await _begin(dut)
    import numpy as np
    if N_CFG < 48 or V_CFG < 2:
        dut._log.info("B04 skipped (requires N>=48 and V>=2)")
        return
    words = _note_words("piano", 21, "forte")
    assert len(words) == 48
    await _reset(dut)
    ref = RefPoly()
    for v in range(V_CFG):
        for m, w in enumerate(words):
            ev, ec = await _cfg(dut, v, m, w)
            assert ev == 0 and ec == 0, (v, m, ev, ec)
            ref.cfg(v, m, w)
    rng = np.random.default_rng(4)
    act = (1 << V_CFG) - 1
    nvec = [48] * V_CFG
    worst = 0
    total_commits = 0
    # deterministic, distinct x per voice that grows into a decaying sequence
    xstate = [int(rng.integers(-(1 << 20), 1 << 20)) for _ in range(V_CFG)]
    for f in range(100):
        xvec = []
        for v in range(V_CFG):
            xstate[v] = int((xstate[v] * 1103515245 + 12345 + v * 7919)
                            & 0x7FFFFFFF) - (1 << 30)
            xvec.append(xstate[v])
        res = await _frame(dut, act, nvec, xvec)
        exp_c, exp_v, exp_s = ref.step([True] * V_CFG, nvec, xvec)
        cyc = _compare(res, exp_c, exp_v, exp_s, f"B04 frame {f}")
        worst = max(worst, cyc)
        total_commits += len(res[1])
    assert worst <= 1800, f"B04 worst frame {worst} > 1800"
    assert total_commits == 100 * V_CFG * 48
    dut._log.info(f"B04 32-voice piano21forte x100 frames bit-exact, worst "
                  f"{worst} cycles ({total_commits} commits)")


# ---------------------------------------------------------------------------
# B05 -- errors, whole-frame precheck
# ---------------------------------------------------------------------------
@cocotb.test(timeout_time=600, timeout_unit="sec")
async def b05_errors_precheck(dut):
    await _begin(dut)
    import numpy as np
    rng = np.random.default_rng(5)
    await _reset(dut)
    # cfg out of range
    if (1 << MW) - 1 > N_CFG:
        ev, ec = await _cfg(dut, 0, N_CFG, _rand_word(rng))
        assert (ev, ec) == (1, 1), f"cfg OOB {ev},{ec}"
    # clear out of range only representable when VW has room
    if (1 << VW) > V_CFG:
        ev, ec, cd = await _clear(dut, V_CFG)
        assert (ev, ec) == (1, 1), f"clear OOB {ev},{ec}"
        assert cd == 0
    # n out of range: needs MW room above N_MODES
    if (1 << MW) - 1 > N_CFG:
        ev, ec = await _frame_err(dut, 0b1, [N_CFG + 1] + [0] * (V_CFG - 1))
        assert (ev, ec) == (1, 2), f"n OOB {ev},{ec}"
    # active but coefficient not loaded -> error 3, no state update
    await _reset(dut)
    ref = RefPoly()
    n = min(N_CFG, 4)
    for m in range(n):
        w = _rand_word(rng)
        ev, ec = await _cfg(dut, 0, m, w)
        assert ev == 0
        ref.cfg(0, m, w)
    # voice 1 active but not configured
    ev, ec = await _frame_err(dut, 0b11, [n, n] + [0] * (V_CFG - 2))
    assert (ev, ec) == (1, 3), f"unloaded active {ev},{ec}"
    # the valid voice 0 must not have advanced
    x = _rand_x(rng)
    ex_c, ex_v, ex_s = ref.step([True] + [False] * (V_CFG - 1), [n] * V_CFG,
                                [x] * V_CFG)
    res = await _frame(dut, 0b1, [n] * V_CFG, [x] * V_CFG)
    _compare(res, ex_c, ex_v, ex_s, "B05 after error")
    # error in a later voice must not commit an earlier voice
    dut._log.info("B05 error codes and whole-frame precheck OK")


async def _frame_err(dut, act, nvec):
    dut.active_mask.value = _u(act, V_CFG)
    dut.n_modes_vec.value = _pack_nvec(nvec)
    dut.x_vec.value = 0
    dut.sample_valid.value = 1
    await Timer(1, unit="ns")
    guard = 0
    while not _i(dut.sample_ready):
        await RisingEdge(dut.clk)
        await Timer(1, unit="ns")
        guard += 1
        assert guard < 200
    await RisingEdge(dut.clk)
    dut.sample_valid.value = 0
    await Timer(1, unit="ns")
    ev, ec = _i(dut.error_valid), _i(dut.error_code)
    assert _i(dut.busy) == 0, "busy asserted on rejected frame"
    assert _i(dut.out_valid) == 0
    return ev, ec


# ---------------------------------------------------------------------------
# B06 -- clear keeps coefficients and other voices
# ---------------------------------------------------------------------------
@cocotb.test(timeout_time=600, timeout_unit="sec")
async def b06_clear_scope(dut):
    await _begin(dut)
    import numpy as np
    rng = np.random.default_rng(6)
    await _reset(dut)
    ref = RefPoly()
    n = min(N_CFG, 8)
    for v in range(V_CFG):
        for m in range(n):
            w = _rand_word(rng)
            ev, ec = await _cfg(dut, v, m, w)
            assert ev == 0
            ref.cfg(v, m, w)
    # run once so every voice has history
    act = (1 << V_CFG) - 1
    nvec = [n] * V_CFG
    xvec = [_rand_x(rng) for _ in range(V_CFG)]
    res = await _frame(dut, act, nvec, xvec)
    exp_c, exp_v, exp_s = ref.step([True] * V_CFG, nvec, xvec)
    _compare(res, exp_c, exp_v, exp_s, "B06 pre-clear")
    assert any(any(y != 0 for y in ref.y1[v]) for v in range(V_CFG))

    target = min(1, V_CFG - 1)
    ev, ec, cd = await _clear(dut, target)
    assert (ev, ec, cd) == (0, 0, 1), (ev, ec, cd)
    ref.clear(target)
    # coefficients survive and other voices keep their history
    xvec2 = [_rand_x(rng) for _ in range(V_CFG)]
    xvec2[target] = 0
    res = await _frame(dut, act, nvec, xvec2)
    exp_c, exp_v, exp_s = ref.step([True] * V_CFG, nvec, xvec2)
    _compare(res, exp_c, exp_v, exp_s, "B06 post-clear")
    # target voice was zeroed: with x=0 its feedback is zero
    dut._log.info("B06 clear scoped to one voice, coefficients kept")


# ---------------------------------------------------------------------------
# B07 -- priority and busy
# ---------------------------------------------------------------------------
@cocotb.test(timeout_time=300, timeout_unit="sec")
async def b07_priority_busy(dut):
    await _begin(dut)
    import numpy as np
    rng = np.random.default_rng(7)
    await _reset(dut)
    n = min(N_CFG, 4)
    for m in range(n):
        await _cfg(dut, 0, m, _rand_word(rng))
    # clear beats cfg and sample
    dut.clear_valid.value = 1
    dut.clear_voice.value = 0
    dut.cfg_valid.value = 1
    dut.cfg_voice.value = 0
    dut.cfg_mode.value = 0
    dut.cfg_word.value = pack_word(0, 0, 0)
    dut.sample_valid.value = 1
    dut.active_mask.value = 1
    dut.n_modes_vec.value = _pack_nvec([n] + [0] * (V_CFG - 1))
    dut.x_vec.value = 1
    await Timer(1, unit="ns")
    assert _i(dut.clear_ready) == 1
    assert _i(dut.cfg_ready) == 0 and _i(dut.sample_ready) == 0
    await RisingEdge(dut.clk)
    await Timer(1, unit="ns")
    assert _i(dut.clear_done) == 1 and _i(dut.busy) == 0
    dut.clear_valid.value = 0
    dut.cfg_valid.value = 0
    dut.sample_valid.value = 0
    # busy: ready low, conflicts ignored
    x = _rand_x(rng)
    dut.sample_valid.value = 1
    dut.active_mask.value = 1
    dut.n_modes_vec.value = _pack_nvec([n] + [0] * (V_CFG - 1))
    dut.x_vec.value = _pack_xvec([x] + [0] * (V_CFG - 1))
    await Timer(1, unit="ns")
    guard = 0
    while not _i(dut.sample_ready):
        await RisingEdge(dut.clk)
        await Timer(1, unit="ns")
        guard += 1
        assert guard < 100
    await RisingEdge(dut.clk)
    await Timer(1, unit="ns")
    assert _i(dut.busy) == 1
    assert _i(dut.cfg_ready) == 0 and _i(dut.clear_ready) == 0
    dut.sample_valid.value = 0
    dut.cfg_valid.value = 1
    dut.clear_valid.value = 1
    while not _i(dut.out_valid):
        await RisingEdge(dut.clk)
        await Timer(1, unit="ns")
    dut.cfg_valid.value = 0
    dut.clear_valid.value = 0
    dut._log.info("B07 priority and busy ready gating OK")


# ---------------------------------------------------------------------------
# B08 -- half-LSB, positive/negative saturation, >63 sat, wide mix
# ---------------------------------------------------------------------------
@cocotb.test(timeout_time=300, timeout_unit="sec")
async def b08_saturation(dut):
    await _begin(dut)
    await _reset(dut)
    w_unit = pack_word(0, 0, 1)
    for v in range(V_CFG):
        ev, ec = await _cfg(dut, v, 0, w_unit)
        assert ev == 0
    act = (1 << V_CFG) - 1
    nvec = [1] * V_CFG
    # +0.5 LSB and -0.5 LSB across each voice
    xh = 1 << 23
    res = await _frame(dut, act, nvec, [xh] * V_CFG)
    assert all(c == (1, 0, 0) for c in res[1].values()), res[1]
    res = await _frame(dut, act, nvec, [-xh] * V_CFG)
    # commit tuple is (new y1, new y2 = old y1, sat)
    assert all(c == (0, 1, 0) for c in res[1].values()), res[1]

    # saturation: G max, x max -> each mode saturates positive
    w_sat = pack_word(0, 0, (1 << (G_BITS - 1)) - 1)
    await _reset(dut)
    for v in range(V_CFG):
        await _cfg(dut, v, 0, w_sat)
    res = await _frame(dut, act, nvec, [(1 << (Y_BITS - 1)) - 1] * V_CFG)
    assert all(c == (Y_MAX, 0, 1) for c in res[1].values())
    assert res[4] == V_CFG, f"sat total {res[4]} != {V_CFG}"
    res = await _frame(dut, act, nvec, [-(1 << (Y_BITS - 1))] * V_CFG)
    # previous frame left y1=Y_MAX, so the new y2 is Y_MAX
    assert all(c == (Y_MIN, Y_MAX, 1) for c in res[1].values()), res[1]

    # sat total beyond 63: use many modes per voice
    n = min(N_CFG, 48)
    await _reset(dut)
    for v in range(V_CFG):
        for m in range(n):
            await _cfg(dut, v, m, w_sat)
    res = await _frame(dut, act, [n] * V_CFG, [(1 << (Y_BITS - 1)) - 1] * V_CFG)
    total_sat = V_CFG * n
    if total_sat > 63:
        assert res[4] == total_sat, f"sat total {res[4]} != {total_sat}"
        assert res[4] > 63

    # mix sum beyond 32 bits must not be pre-clamped to int32
    w_one = pack_word(0, 0, 1 << 24)          # G = 1.0 in Q2.24
    await _reset(dut)
    for v in range(V_CFG):
        await _cfg(dut, v, 0, w_one)
    xbig = 1 << 30
    res = await _frame(dut, act, [1] * V_CFG, [xbig] * V_CFG)
    expected = V_CFG * xbig
    if expected > (1 << 31) - 1:
        assert res[3] == expected, f"mix {res[3]} != {expected} (pre-clamped?)"
        assert res[4] == 0
    dut._log.info(f"B08 rounding/saturation exact (total sat {res[4]}, "
                  f"mix {res[3]})")


# ---------------------------------------------------------------------------
# B09 -- reset at every phase of a frame
# ---------------------------------------------------------------------------
@cocotb.test(timeout_time=600, timeout_unit="sec")
async def b09_reset_phases(dut):
    await _begin(dut)
    import numpy as np
    rng = np.random.default_rng(9)
    n = min(N_CFG, 48)
    nv = min(V_CFG, 4)
    for delay in range(0, 3 * ((n + 3) // 4) + 12):
        await _reset(dut)
        for v in range(nv):
            for m in range(n):
                await _cfg(dut, v, m, _rand_word(rng))
        act = (1 << nv) - 1
        nvec = [n] * nv + [0] * (V_CFG - nv)
        xvec = [_rand_x(rng) for _ in range(nv)] + [0] * (V_CFG - nv)
        dut.active_mask.value = act
        dut.n_modes_vec.value = _pack_nvec(nvec)
        dut.x_vec.value = _pack_xvec(xvec)
        dut.sample_valid.value = 1
        await Timer(1, unit="ns")
        while not _i(dut.sample_ready):
            await RisingEdge(dut.clk)
            await Timer(1, unit="ns")
        await RisingEdge(dut.clk)
        dut.sample_valid.value = 0
        await Timer(1, unit="ns")
        for _ in range(delay):
            await RisingEdge(dut.clk)
            await Timer(1, unit="ns")
        dut.rst_n.value = 0
        for _ in range(3):
            await RisingEdge(dut.clk)
            await Timer(1, unit="ns")
        assert _i(dut.busy) == 0 and _i(dut.out_valid) == 0
        assert _i(dut.commit_valid) == 0
        dut.rst_n.value = 1
        await RisingEdge(dut.clk)
        await Timer(1, unit="ns")
    dut._log.info(f"B09 reset at {3 * ((n + 3) // 4) + 12} phases clean")


# ---------------------------------------------------------------------------
# runner
# ---------------------------------------------------------------------------
def _sources():
    return [os.path.join(_ROOT, "rtl", "core", "poly_modal_lane.sv"),
            os.path.join(_ROOT, "rtl", "core", "modal_poly_bank.sv")]


def _params(nmodes, nvoices, skipz):
    return {"N_MODES": nmodes, "NUM_VOICES": nvoices,
            "SKIP_ZERO_INPUT": skipz}


def _run_one(nmodes, nvoices, skipz, build_dir, testcase=None):
    env = {"POLYBANK_NMODES": str(nmodes), "POLYBANK_NUMVOICES": str(nvoices),
           "POLYBANK_SKIPZERO": str(skipz)}
    return build_and_run(_sources(), "modal_poly_bank", "test_modal_poly_bank",
                         _HERE, build_dir, _params(nmodes, nvoices, skipz),
                         env, testcase=testcase)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--n-modes", type=int, default=48)
    ap.add_argument("--num-voices", type=int, default=32)
    ap.add_argument("--skip-zero-input", type=int, default=0, choices=(0, 1))
    ap.add_argument("--build-dir",
                    default=os.path.join(_ROOT, "sim", "build", "modal_poly_bank"))
    ap.add_argument("--testcase", default=None)
    ap.add_argument("--matrix", action="store_true")
    args = ap.parse_args(argv)

    global N_CFG, V_CFG, MW, VW, SW
    if args.matrix:
        base = os.path.abspath(os.path.expanduser(args.build_dir))
        ok = True
        for n in (1, 7, 48):
            for v in (1, 3, 32):
                for s in (0, 1):
                    label = f"N{n}_V{v}_s{s}"
                    print(f"[matrix] {label}")
                    try:
                        _run_one(n, v, s, os.path.join(base, label),
                                 testcase="b02_counts_masks")
                    except RuntimeError as exc:
                        print(f"[matrix] FAIL {label}: {exc}", file=sys.stderr)
                        ok = False
        print("[matrix] OK" if ok else "[matrix] FAIL")
        return 0 if ok else 1

    N_CFG, V_CFG, MW = args.n_modes, args.num_voices, \
        max(1, args.n_modes.bit_length())
    VW = max(1, (args.num_voices - 1).bit_length()) if args.num_voices > 1 else 1
    SW = max(1, (args.num_voices * args.n_modes).bit_length())
    try:
        summary = _run_one(args.n_modes, args.num_voices, args.skip_zero_input,
                           args.build_dir, args.testcase)
    except RuntimeError as exc:
        print(f"[FAIL] {exc}", file=sys.stderr)
        return 1
    print(f"[modal_poly_bank] {summary['n']} tests PASS "
          f"(N={args.n_modes}, V={args.num_voices}, skip={args.skip_zero_input})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
