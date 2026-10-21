"""cocotb regression for rtl/core/modal_bank.sv (module 2A).

Bit-exact checks of the four-lane, single-voice TDM modal bank against

  * the integer recurrence of python/modal_sim/fixed_point.py (verification
    chain step 2), for synthetic/directed/edge vectors, and
  * ``FixedModalSynth(max_poly=1, free_thr=0).step()`` driven with the raw
    72-bit ``*.mem`` coefficient files, for real notes (T06).

The reference model used for the synthetic tests reproduces the *documented*
per-mode recurrence with Python arbitrary-precision integers, so a wrong RTL
rounding/clamp/lane-mapping shows up as a mismatch (per-commit and total).

Runner (``python sim/unit/core/test_modal_bank.py``) builds with Icarus and writes all
artefacts under ``sim/build/modal_bank/`` (never over ``sim/results.xml``).
"""

from __future__ import annotations

import argparse
import hashlib
import json
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
from _sim_paths import bootstrap as _sim_bootstrap  # noqa: E402
_ROOT = str(_sim_bootstrap(__file__))
sys.path.insert(0, os.path.join(_ROOT, "python", "modal_sim"))

from fixed_point import (A1_BITS, A1_FRAC, A2_BITS, G_BITS,  # noqa: E402
                         C_FRAC, Y_BITS, Y_FRAC, Y_MIN, Y_MAX,
                         pack_word, unpack_word, CoeffTable, FixedModalSynth)

PARAMS = os.path.join(_ROOT, "FFT_results", "params")

# configuration selected by the runner via environment variables
N_CFG = int(os.environ.get("MODAL_BANK_NMODES", "48"))
SKIPZ = int(os.environ.get("MODAL_BANK_SKIPZERO", "0"))
MW = N_CFG.bit_length()
DIGEST_OUT = os.environ.get("MODAL_BANK_DIGEST_OUT")
HEAVY = (N_CFG >= 48)

A1_SHIFT = C_FRAC - A1_FRAC


# ---------------------------------------------------------------------------
# small helpers
# ---------------------------------------------------------------------------
def _u(v, w):
    return int(v) & ((1 << w) - 1)


def _s(v, w):
    v = int(v) & ((1 << w) - 1)
    return v - (1 << w) if (v >> (w - 1)) else v


def _field(sig, total, lo, width):
    """Extract one bit field without converting the whole (possibly X) vector."""
    b = str(sig.value)
    field = b[total - lo - width: total - lo]
    if any(c in field for c in "xzXZ"):
        return None
    return int(field, 2)


def _collect_commits(dut):
    """Return {mode: (y1, y2, sat)} for the committing lanes this cycle."""
    out = {}
    cv = int(dut.commit_valid.value)
    if cv == 0:
        return out
    for i in range(4):
        if (cv >> i) & 1:
            m = _field(dut.commit_mode, 4 * MW, i * MW, MW)
            y1 = _field(dut.commit_y1, 128, i * 32, 32)
            y2 = _field(dut.commit_y2, 128, i * 32, 32)
            assert m is not None and y1 is not None and y2 is not None, \
                f"X on commit lane {i}: mode={m} y1={str(dut.commit_y1.value)} " \
                f"y2={str(dut.commit_y2.value)}"
            assert m % 4 == i, f"commit lane {i} reported mode {m} (m%4 != lane)"
            assert m not in out, f"lane {i} mode {m} duplicated within one cycle"
            out[m] = (_s(y1, 32), _s(y2, 32),
                      (int(dut.commit_sat.value) >> i) & 1)
    return out


def _merge_commits(commits, new, where=""):
    """Merge a cycle's commits, rejecting duplicate mode commits across frames."""
    for m, v in new.items():
        assert m not in commits, f"{where}: mode {m} committed more than once"
        commits[m] = v
    return commits


def _mode_step(a1, a2, G, y1, y2, x):
    """Documented per-mode recurrence, arbitrary precision."""
    acc = G * x - (a1 << A1_SHIFT) * y1 - a2 * y2
    raw = (acc + (1 << (C_FRAC - 1))) >> C_FRAC
    sat = int(not (Y_MIN <= raw <= Y_MAX))
    return max(Y_MIN, min(Y_MAX, raw)), sat


class RefBank:
    """Integer reference for one frame of the modal bank."""

    def __init__(self, n=N_CFG):
        self.n = n
        self.word = [None] * n
        self.y1 = [0] * n
        self.y2 = [0] * n

    @property
    def loaded(self):
        return all(w is not None for w in self.word)

    def clear(self):
        self.y1 = [0] * self.n
        self.y2 = [0] * self.n

    def cfg(self, mode, word):
        assert 0 <= mode < self.n, mode
        self.word[mode] = word

    def step(self, x, n):
        """Returns (commits{mode:(y1,y2,sat)}, total, sat_count)."""
        commits = {}
        newy = [0] * n
        total = 0
        satc = 0
        for k in range(n):
            a1, a2, G = unpack_word(self.word[k])
            yn, s = _mode_step(a1, a2, G, self.y1[k], self.y2[k], x)
            newy[k] = yn
            commits[k] = (yn, self.y1[k], s)
            total += yn
            satc += s
        for k in range(n):
            self.y2[k] = self.y1[k]
            self.y1[k] = newy[k]
        return commits, total, satc


# ---------------------------------------------------------------------------
# DUT driver
# ---------------------------------------------------------------------------
async def _begin(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())


async def _reset(dut):
    dut.rst_n.value = 0
    for name, val in (("cfg_valid", 0), ("cfg_mode", 0), ("cfg_word", 0),
                      ("clear_valid", 0), ("sample_valid", 0),
                      ("n_modes", 0), ("x_in", 0)):
        getattr(dut, name).value = val
    for _ in range(4):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)
    await Timer(1, unit="ns")


async def _cfg(dut, mode, word):
    """One config handshake; returns (error_valid, error_code)."""
    dut.cfg_valid.value = 1
    dut.cfg_mode.value = _u(mode, MW)
    dut.cfg_word.value = _u(word, 72)
    await Timer(1, unit="ns")
    guard = 0
    while not int(dut.cfg_ready.value):
        await RisingEdge(dut.clk)
        await Timer(1, unit="ns")
        guard += 1
        assert guard < 50, "cfg_ready stuck"
    await RisingEdge(dut.clk)
    dut.cfg_valid.value = 0
    await Timer(1, unit="ns")
    return int(dut.error_valid.value), int(dut.error_code.value)


async def _clear(dut):
    dut.clear_valid.value = 1
    await Timer(1, unit="ns")
    guard = 0
    while not int(dut.clear_ready.value):
        await RisingEdge(dut.clk)
        await Timer(1, unit="ns")
        guard += 1
        assert guard < 50, "clear_ready stuck"
    await RisingEdge(dut.clk)
    dut.clear_valid.value = 0
    await Timer(1, unit="ns")
    assert int(dut.clear_done.value) == 1, "clear_done not asserted after handshake"


async def _frame(dut, x, n):
    """Run one sample frame; returns (cycles, commits, y_sum, sat_count)."""
    dut.sample_valid.value = 1
    dut.n_modes.value = _u(n, MW)
    dut.x_in.value = _u(x, 32)
    await Timer(1, unit="ns")
    guard = 0
    while not int(dut.sample_ready.value):
        await RisingEdge(dut.clk)
        await Timer(1, unit="ns")
        guard += 1
        assert guard < 200, "sample_ready stuck"
    await RisingEdge(dut.clk)                       # handshake edge
    dut.sample_valid.value = 0
    await Timer(1, unit="ns")

    commits = {}
    cycles = 0
    while True:
        _merge_commits(commits, _collect_commits(dut), "frame")
        if int(dut.out_valid.value):
            return (cycles, commits,
                    _s(int(dut.y_sum.value), 64), int(dut.sat_count.value))
        cycles += 1
        assert cycles < 5000, "frame did not finish"
        await RisingEdge(dut.clk)
        await Timer(1, unit="ns")


async def _sample_error(dut, x, n, code):
    """Assert a rejected sample request: error pulse, no frame started."""
    dut.sample_valid.value = 1
    dut.n_modes.value = _u(n, MW)
    dut.x_in.value = _u(x, 32)
    await Timer(1, unit="ns")
    guard = 0
    while not int(dut.sample_ready.value):
        await RisingEdge(dut.clk)
        await Timer(1, unit="ns")
        guard += 1
        assert guard < 200
    await RisingEdge(dut.clk)
    dut.sample_valid.value = 0
    await Timer(1, unit="ns")
    assert int(dut.error_valid.value) == 1, "expected error pulse"
    assert int(dut.error_code.value) == code, \
        f"error_code={int(dut.error_code.value)} want {code}"
    assert int(dut.busy.value) == 0, "busy must stay low on rejected sample"


async def _load(dut, ref, words):
    for k, w in enumerate(words):
        ev, ec = await _cfg(dut, k, w)
        assert ev == 0, f"unexpected cfg error {ec} at mode {k}"
        ref.cfg(k, w)


def _check_frame(res, ref_commits, ref_total, ref_sat, where=""):
    cycles, commits, total, satc = res
    assert set(commits) == set(ref_commits), \
        f"{where}: committed modes {sorted(commits)} != {sorted(ref_commits)}"
    for k in ref_commits:
        assert commits[k] == ref_commits[k], \
            f"{where}: mode {k} dut {commits[k]} != ref {ref_commits[k]}"
    assert total == ref_total, f"{where}: y_sum {total} != {ref_total}"
    assert satc == ref_sat, f"{where}: sat_count {satc} != {ref_sat}"
    return cycles


# ---------------------------------------------------------------------------
# coefficient word generators
# ---------------------------------------------------------------------------
def _edge_words():
    return [
        pack_word(0, 0, 0),
        pack_word(-(1 << (A1_BITS - 1)), 0, 0),
        pack_word((1 << (A1_BITS - 1)) - 1, (1 << A2_BITS) - 1, 0),
        pack_word(0, (1 << A2_BITS) - 1, (1 << (G_BITS - 1)) - 1),
        pack_word(0, 0, -(1 << (G_BITS - 1))),
        pack_word(-(1 << (A1_BITS - 1)), (1 << A2_BITS) - 1, (1 << (G_BITS - 1)) - 1),
    ]


def _rand_words(rng, count):
    words = []
    for _ in range(count):
        a1 = int(rng.integers(-(1 << (A1_BITS - 1)), 1 << (A1_BITS - 1)))
        a2 = int(rng.integers(0, 1 << A2_BITS))
        G = int(rng.integers(-(1 << (G_BITS - 1)), 1 << (G_BITS - 1)))
        words.append(pack_word(a1, a2, G))
    return words


def _rand_x(rng):
    return int(rng.integers(-(1 << (Y_BITS - 1)), (1 << (Y_BITS - 1))))


# ---------------------------------------------------------------------------
# T01 -- reset, pre-config state, idle X check, zero frame, missing coefficient
# ---------------------------------------------------------------------------
@cocotb.test(timeout_time=60, timeout_unit="sec")
async def t01_reset_preconfig(dut):
    await _begin(dut)
    await _reset(dut)

    for name in ("busy", "out_valid", "error_valid", "clear_done",
                 "cfg_ready", "clear_ready", "sample_ready",
                 "commit_valid", "commit_mode", "commit_y1", "commit_y2",
                 "commit_sat", "y_sum", "sat_count", "error_code"):
        assert getattr(dut, name).value.is_resolvable, f"{name} is X after reset"
    assert int(dut.busy.value) == 0
    assert int(dut.cfg_ready.value) == 1
    assert int(dut.clear_ready.value) == 1
    assert int(dut.sample_ready.value) == 1

    # zero-mode frame is legal and produces zero output
    res = await _frame(dut, 0, 0)
    assert res[1] == {} and res[2] == 0 and res[3] == 0, res
    assert res[0] <= 3 * 0 + 16

    # non-zero frame with nothing loaded -> error code 3, no side effect
    await _sample_error(dut, 12345, min(1, N_CFG), 3)
    dut._log.info("T01 reset/pre-config/zero-frame/missing-coeff OK")


# ---------------------------------------------------------------------------
# T02 -- mode counts
# ---------------------------------------------------------------------------
@cocotb.test(timeout_time=300, timeout_unit="sec")
async def t02_mode_counts(dut):
    await _begin(dut)
    import numpy as np
    rng = np.random.default_rng(1)
    counts = [n for n in (0, 1, 2, 3, 4, 5, 7, 12, 47, 48) if n <= N_CFG]
    measured = {}
    for n in counts:
        await _reset(dut)
        ref = RefBank()
        words = _rand_words(rng, n)
        await _load(dut, ref, words)
        x = _rand_x(rng)
        rc, rt, rs = ref.step(x, n)
        res = await _frame(dut, x, n)
        cyc = _check_frame(res, rc, rt, rs, f"T02 n={n}")
        budget = 3 * ((n + 3) // 4) + 16
        assert cyc <= budget, f"n={n}: cycles {cyc} > {budget}"
        measured[n] = cyc
    dut._log.info(f"T02 cycles per n_modes: {measured} (budgets <= "
                  f"{ {n: 3 * ((n + 3) // 4) + 16 for n in counts} })")
    dut._log.info("T02 mode counts bit-exact, within cycle bound")


# ---------------------------------------------------------------------------
# T03 -- many random full coefficient sets and signed inputs
# ---------------------------------------------------------------------------
@cocotb.test(timeout_time=600, timeout_unit="sec")
async def t03_random_coefficients(dut):
    await _begin(dut)
    import numpy as np
    rng = np.random.default_rng(0)
    edge = _edge_words()
    sets = []
    n_use = min(N_CFG, 8)
    for _ in range(6):
        sets.append(_rand_words(rng, n_use))
    total_sat = 0
    for si, words in enumerate(sets):
        await _reset(dut)
        ref = RefBank()
        await _load(dut, ref, words)
        for f in range(40):
            if f % 7 == 0:
                x = _rand_x(rng)
            elif f % 7 == 1:
                x = -(1 << (Y_BITS - 1))           # most negative
            elif f % 7 == 2:
                x = (1 << (Y_BITS - 1)) - 1        # most positive
            else:
                x = _rand_x(rng)
            rc, rt, rs = ref.step(x, n_use)
            res = await _frame(dut, x, n_use)
            _check_frame(res, rc, rt, rs, f"T03 set {si} frame {f}")
            total_sat += rs
    # edge sets in every lane
    for ei, w in enumerate(edge):
        await _reset(dut)
        ref = RefBank()
        await _load(dut, ref, [w] * n_use)
        for f in range(20):
            x = _rand_x(rng)
            rc, rt, rs = ref.step(x, n_use)
            res = await _frame(dut, x, n_use)
            _check_frame(res, rc, rt, rs, f"T03 edge {ei} frame {f}")
            total_sat += rs
    dut._log.info(f"T03 random/edge coefficients bit-exact, {total_sat} saturations")


# ---------------------------------------------------------------------------
# T04 -- half-LSB rounding and positive/negative saturation
# ---------------------------------------------------------------------------
@cocotb.test(timeout_time=120, timeout_unit="sec")
async def t04_rounding_saturation(dut):
    await _begin(dut)
    # G = 1 LSB, a1 = a2 = 0, so ynew = round(x / 2^24)
    w_unit = pack_word(0, 0, 1)
    await _reset(dut)
    ref = RefBank()
    await _load(dut, ref, [w_unit])
    x_half = 1 << 23                                   # +0.5 * 2^24
    rc, rt, rs = ref.step(x_half, 1)
    res = await _frame(dut, x_half, 1)
    _check_frame(res, rc, rt, rs, "T04 +half-LSB")
    assert rc[0][0] == 1, f"expected +half round to 1, got {rc[0]}"
    rc, rt, rs = ref.step(-x_half, 1)                  # -0.5 -> 0 (round half up)
    res = await _frame(dut, -x_half, 1)
    _check_frame(res, rc, rt, rs, "T04 -half-LSB")
    assert rc[0][0] == 0, f"expected -half round to 0, got {rc[0]}"

    # positive saturation: G max, x max, a1=a2=0
    w_sat = pack_word(0, 0, (1 << (G_BITS - 1)) - 1)
    await _reset(dut)
    ref = RefBank()
    await _load(dut, ref, [w_sat])
    for x, exp_sat in (((1 << (Y_BITS - 1)) - 1, 1), (-(1 << (Y_BITS - 1)), 1)):
        rc, rt, rs = ref.step(x, 1)
        res = await _frame(dut, x, 1)
        _check_frame(res, rc, rt, rs, f"T04 sat x={x}")
        assert rc[0][2] == 1 and rs == 1, "directed saturation not triggered"
        assert res[1][0][0] == (Y_MAX if x > 0 else Y_MIN)
    dut._log.info("T04 half-LSB rounding and saturation bit-exact")


# ---------------------------------------------------------------------------
# T05 -- four lanes, distinct coefficients, no cross-talk / lost / duplicate
# ---------------------------------------------------------------------------
@cocotb.test(timeout_time=300, timeout_unit="sec")
async def t05_lane_isolation(dut):
    await _begin(dut)
    import numpy as np
    rng = np.random.default_rng(5)
    n = N_CFG
    await _reset(dut)
    ref = RefBank()
    words = _rand_words(rng, n)
    await _load(dut, ref, words)
    for f in range(30):
        x = _rand_x(rng)
        rc, rt, rs = ref.step(x, n)
        res = await _frame(dut, x, n)
        _check_frame(res, rc, rt, rs, f"T05 frame {f}")
        assert sorted(res[1].keys()) == list(range(n)), "mode missing/duplicate"
    dut._log.info("T05 four-lane isolation: each mode committed exactly once")


# ---------------------------------------------------------------------------
# T06 -- raw 72-bit .mem real notes vs FixedModalSynth(max_poly=1, free_thr=0)
# ---------------------------------------------------------------------------
def _load_mem(instrument):
    mem_path = os.path.join(PARAMS, f"{instrument}_coeff.mem")
    idx_path = os.path.join(PARAMS, f"{instrument}_coeffindex.json")
    with open(mem_path, encoding="utf-8") as fh:
        all_words = [int(line, 16) for line in fh if line.strip()]
    with open(idx_path, encoding="utf-8") as fh:
        index = json.load(fh)
    table = CoeffTable()
    by_key = {}
    for key, meta in index.items():
        midi_s, dyn = key.split("|")
        midi = int(midi_s)
        off, nm = meta["offset"], meta["n_modes"]
        ws = all_words[off:off + nm]
        a1, a2, G = [], [], []
        for w in ws:
            u1, u2, u3 = unpack_word(w)
            a1.append(u1)
            a2.append(u2)
            G.append(u3)
        import numpy as np
        table.add(midi, dyn, np.array(a1, dtype=np.int64),
                  np.array(a2, dtype=np.int64), np.array(G, dtype=np.int64))
        by_key[(midi, dyn)] = ws
    return table, by_key, index


async def _run_real_note(dut, inst, midi, dyn, samples):
    table, by_key, _ = _load_mem(inst)
    words = by_key[(midi, dyn)]
    n = len(words)
    assert n <= N_CFG, f"{inst} {midi} {dyn}: {n} modes > N_MODES {N_CFG}"
    vel = 1.0 if dyn == "forte" else 0.5
    synth = FixedModalSynth(table, max_poly=1, max_modes=N_CFG, free_thr=0.0)
    synth.note_on(midi, vel)

    await _reset(dut)
    for k, w in enumerate(words):
        ev, ec = await _cfg(dut, k, w)
        assert ev == 0 and ec == 0, (inst, k, ev, ec)

    maxcyc = 0
    for t in range(samples):
        prev_y1 = synth.y1[0, :n].copy()
        prev_y2 = synth.y2[0, :n].copy()
        sat_before = synth.sat_count
        synth.step()
        xq = int(synth.xq[0])
        ref_y1 = [int(v) for v in synth.y1[0, :n]]
        ref_y2 = [int(v) for v in synth.y2[0, :n]]

        res = await _frame(dut, xq, n)
        cyc, commits, total, satc = res
        maxcyc = max(maxcyc, cyc)
        assert set(commits) == set(range(n)), f"{inst} frame {t}: bad commit set"
        for k in range(n):
            a1, a2, G = unpack_word(words[k])
            yn, s = _mode_step(a1, a2, G, int(prev_y1[k]), int(prev_y2[k]), xq)
            assert yn == ref_y1[k] and s == commits[k][2], \
                f"{inst} frame {t} mode {k}: formula {yn},{s} model {ref_y1[k]}"
            assert commits[k][0] == ref_y1[k] and commits[k][1] == ref_y2[k], \
                f"{inst} frame {t} mode {k}: dut {commits[k]} vs ref {(ref_y1[k], ref_y2[k])}"
        assert total == int(synth.y1[0, :n].sum()), f"{inst} frame {t}: y_sum"
        delta = synth.sat_count - sat_before
        assert satc == delta == sum(commits[k][2] for k in range(n)), \
            f"{inst} frame {t}: sat_count {satc} vs model delta {delta}"
    dut._log.info(f"T06 {inst} midi{midi} {dyn}: {samples} samples, {n} modes, "
                  f"max {maxcyc} cycles")
    return maxcyc


@cocotb.test(timeout_time=1800, timeout_unit="sec")
async def t06_real_audio_mem(dut):
    await _begin(dut)
    if not HEAVY:
        dut._log.info("T06 skipped (requires N_MODES=48)")
        return
    probes = [
        ("guitar", 40, "forte"),
        ("piano", 21, "forte"),        # required: piano MIDI21 forte, no fallback
        ("banjo", 48, "forte"),
        ("mandolin", 55, "piano"),
    ]
    for inst, midi, dyn in probes:
        _, by_key, _ = _load_mem(inst)
        assert (midi, dyn) in by_key, \
            f"required real note {inst} midi{midi} {dyn} absent from the .mem table"
        await _run_real_note(dut, inst, midi, dyn, 2048)
    dut._log.info("T06 real .mem notes match FixedModalSynth step()")


# ---------------------------------------------------------------------------
# T07 -- input changes during busy: no effect, ready low, no cfg side effect
# ---------------------------------------------------------------------------
@cocotb.test(timeout_time=300, timeout_unit="sec")
async def t07_busy_conflict(dut):
    await _begin(dut)
    import numpy as np
    rng = np.random.default_rng(7)
    n = min(N_CFG, 40)
    await _reset(dut)
    ref = RefBank()
    words = _rand_words(rng, n)
    await _load(dut, ref, words)
    x0 = _rand_x(rng)
    rc, rt, rs = ref.step(x0, n)

    # drive the frame manually and perturb inputs mid-flight
    dut.sample_valid.value = 1
    dut.n_modes.value = n
    dut.x_in.value = _u(x0, 32)
    await Timer(1, unit="ns")
    await RisingEdge(dut.clk)                          # handshake
    dut.sample_valid.value = 0
    await Timer(1, unit="ns")

    assert int(dut.cfg_ready.value) == 0
    assert int(dut.sample_ready.value) == 0
    assert int(dut.clear_ready.value) == 0

    # illegal/toxic perturbations that must be ignored while busy
    other = _rand_words(rng, 1)[0]
    dut.cfg_valid.value = 1
    dut.cfg_mode.value = 0
    dut.cfg_word.value = other
    dut.clear_valid.value = 1
    dut.sample_valid.value = 1
    dut.n_modes.value = min(N_CFG, 5)
    dut.x_in.value = 0

    commits = {}
    cycles = 0
    while True:
        _merge_commits(commits, _collect_commits(dut), "T07 busy frame")
        if int(dut.out_valid.value):
            break
        cycles += 1
        await RisingEdge(dut.clk)
        await Timer(1, unit="ns")
    total = _s(int(dut.y_sum.value), 64)
    satc = int(dut.sat_count.value)
    _check_frame((cycles, commits, total, satc), rc, rt, rs, "T07 busy frame")

    # release the held requests; they were never handshaken -> no side effects
    dut.cfg_valid.value = 0
    dut.clear_valid.value = 0
    dut.sample_valid.value = 0
    await RisingEdge(dut.clk)
    await Timer(1, unit="ns")
    assert int(dut.busy.value) == 0
    # run a fresh frame; coefficient at mode 0 must be the original one
    x1 = _rand_x(rng)
    rc2, rt2, rs2 = ref.step(x1, n)
    res = await _frame(dut, x1, n)
    _check_frame(res, rc2, rt2, rs2, "T07 after busy")
    dut._log.info("T07 busy conflicts ignored, no config side effect")


# ---------------------------------------------------------------------------
# T08 -- idle gaps; state only advances on committed frames
# ---------------------------------------------------------------------------
@cocotb.test(timeout_time=300, timeout_unit="sec")
async def t08_idle_gaps(dut):
    await _begin(dut)
    import numpy as np
    rng = np.random.default_rng(8)
    n = min(N_CFG, 12)
    xs = [_rand_x(rng) for _ in range(6)]

    async def run(gaps):
        await _reset(dut)
        ref = RefBank()
        await _load(dut, ref, _rand_words(np.random.default_rng(8), n))
        seq = []
        for k, x in enumerate(xs):
            for _ in range(gaps[k]):
                await RisingEdge(dut.clk)
            rc, rt, rs = ref.step(x, n)
            res = await _frame(dut, x, n)
            seq.append(_check_frame(res, rc, rt, rs, f"T08 gap frame {k}"))
        return seq

    a = await run([0, 0, 0, 0, 0, 0])
    b = await run([0, 3, 10, 1, 25, 0])
    assert a == b, f"gaps changed results: {a} vs {b}"
    dut._log.info("T08 idle gaps do not affect state or timing")


# ---------------------------------------------------------------------------
# T09 -- clear keeps coefficients and zeroes state; cfg does not clear state
# ---------------------------------------------------------------------------
@cocotb.test(timeout_time=300, timeout_unit="sec")
async def t09_clear_reload(dut):
    await _begin(dut)
    import numpy as np
    rng = np.random.default_rng(9)
    n = min(N_CFG, 10)
    words = _rand_words(rng, n)

    await _reset(dut)
    ref = RefBank()
    await _load(dut, ref, words)
    x = _rand_x(rng)
    rc, rt, rs = ref.step(x, n)
    _check_frame(await _frame(dut, x, n), rc, rt, rs, "T09 pre-clear")

    # clear: logical state zero, coefficients survive
    await _clear(dut)
    ref.clear()
    rc, rt, rs = ref.step(0, n)
    _check_frame(await _frame(dut, 0, n), rc, rt, rs, "T09 post-clear zero")

    # coefficients still present -> a non-zero excitation works
    rc, rt, rs = ref.step(x, n)
    _check_frame(await _frame(dut, x, n), rc, rt, rs, "T09 post-clear run")

    # cfg alone must not clear the running (non-zero) state.  Use a non-zero
    # feedback word and x=0 so a cleared state would force the result to zero.
    assert any(v != 0 for v in ref.y1), "expected non-zero history before cfg test"
    new_word = pack_word(1 << (A1_BITS - 2), 1 << (A2_BITS - 1), 1 << 23)
    a1n, a2n, _Gn = unpack_word(new_word)
    assert a1n != 0 and a2n != 0, "cfg-keeps-state needs non-zero feedback"
    ev, ec = await _cfg(dut, 0, new_word)
    assert ev == 0
    ref.cfg(0, new_word)
    hist = ref.y1[0]
    rc, rt, rs = ref.step(0, n)                        # x = 0: feedback only
    res = await _frame(dut, 0, n)
    _check_frame(res, rc, rt, rs, "T09 cfg-keeps-state")
    assert hist != 0, "mode 0 history was zero; cfg-keeps-state not exercised"
    assert res[1][0][0] != 0, "cfg cleared state (x=0 produced a zero state)"
    dut._log.info("T09 clear zeroes state, keeps coefficients; cfg keeps state")


# ---------------------------------------------------------------------------
# T10 -- shrink then grow n_modes; skipped slots keep their history
# ---------------------------------------------------------------------------
@cocotb.test(timeout_time=300, timeout_unit="sec")
async def t10_shrink_grow(dut):
    await _begin(dut)
    import numpy as np
    rng = np.random.default_rng(10)
    n_full = min(N_CFG, 12)
    n_small = max(1, n_full - 4)
    if n_full < 2:
        dut._log.info("T10 skipped (N_MODES too small)")
        return
    await _reset(dut)
    ref = RefBank()
    await _load(dut, ref, _rand_words(rng, n_full))
    seq = [n_full, n_full, n_small, n_small, n_full, n_small, n_full]
    for k, n in enumerate(seq):
        x = _rand_x(rng)
        rc, rt, rs = ref.step(x, n)
        _check_frame(await _frame(dut, x, n), rc, rt, rs, f"T10 frame {k} n={n}")
    dut._log.info("T10 skipped slots retain history across n_modes changes")


# ---------------------------------------------------------------------------
# T11 -- reset in the middle of a frame cancels everything
# ---------------------------------------------------------------------------
@cocotb.test(timeout_time=300, timeout_unit="sec")
async def t11_reset_during_busy(dut):
    await _begin(dut)
    import numpy as np
    rng = np.random.default_rng(11)
    n = N_CFG
    frame_cyc = 3 * ((n + 3) // 4) + 8        # handshake -> out_valid (worst lane)
    cand = [1, max(1, frame_cyc // 4), max(1, frame_cyc // 2),
            max(1, (3 * frame_cyc) // 4), max(1, frame_cyc - 2)]
    delays = sorted({d for d in cand if 1 <= d <= frame_cyc - 1})

    async def start_frame(x):
        dut.sample_valid.value = 1
        dut.n_modes.value = _u(n, MW)
        dut.x_in.value = _u(x, 32)
        await Timer(1, unit="ns")
        guard = 0
        while not int(dut.sample_ready.value):
            await RisingEdge(dut.clk)
            await Timer(1, unit="ns")
            guard += 1
            assert guard < 200
        await RisingEdge(dut.clk)
        dut.sample_valid.value = 0
        await Timer(1, unit="ns")
        assert int(dut.busy.value) == 1, "frame did not start"

    # Every delay gets a fresh reset + coefficient reload, then a verified-running
    # frame; the pulse lands mid-frame or in the write-back drain.
    for delay in delays:
        await _reset(dut)
        ref = RefBank()
        await _load(dut, ref, _rand_words(rng, n))
        await start_frame(_rand_x(rng))
        assert int(dut.busy.value) == 1, "busy low right after start"
        for _ in range(delay):
            await RisingEdge(dut.clk)
            await Timer(1, unit="ns")
            assert int(dut.busy.value) == 1, \
                f"frame already finished before delay {delay}"
        dut.rst_n.value = 0
        for _ in range(3):
            await RisingEdge(dut.clk)
        dut.rst_n.value = 1
        await RisingEdge(dut.clk)
        await Timer(1, unit="ns")
        assert int(dut.busy.value) == 0
        assert int(dut.out_valid.value) == 0
        assert int(dut.commit_valid.value) == 0

    # reconfigure and verify normal operation afterwards
    await _reset(dut)
    ref2 = RefBank()
    words = _rand_words(rng, n)
    await _load(dut, ref2, words)
    x = _rand_x(rng)
    rc, rt, rs = ref2.step(x, n)
    _check_frame(await _frame(dut, x, n), rc, rt, rs, "T11 after reset")
    dut._log.info(f"T11 mid-frame resets cancel pipeline (delays {delays})")


# ---------------------------------------------------------------------------
# T12 -- same-cycle priority and illegal requests
# ---------------------------------------------------------------------------
@cocotb.test(timeout_time=300, timeout_unit="sec")
async def t12_priority_illegal(dut):
    await _begin(dut)
    import numpy as np
    rng = np.random.default_rng(12)
    n = min(N_CFG, 4)
    await _reset(dut)
    ref = RefBank()
    await _load(dut, ref, _rand_words(rng, n))

    # clear beats cfg and sample in the same cycle
    dut.clear_valid.value = 1
    dut.cfg_valid.value = 1
    dut.cfg_mode.value = 0
    dut.cfg_word.value = pack_word(0, 0, 0)
    dut.sample_valid.value = 1
    dut.n_modes.value = n
    dut.x_in.value = 0
    await Timer(1, unit="ns")
    assert int(dut.clear_ready.value) == 1
    assert int(dut.cfg_ready.value) == 0
    assert int(dut.sample_ready.value) == 0
    await RisingEdge(dut.clk)
    dut.clear_valid.value = 0
    dut.cfg_valid.value = 0
    dut.sample_valid.value = 0
    await Timer(1, unit="ns")
    assert int(dut.clear_done.value) == 1
    assert int(dut.busy.value) == 0

    # cfg out of range -> code 1, coefficient bitmap untouched
    oob = N_CFG
    ev, ec = await _cfg(dut, oob, pack_word(1, 1, 1))
    assert (ev, ec) == (1, 1), f"cfg OOB: got {ev},{ec}"

    # n_modes out of range -> code 2 (only representable when MW has room)
    if (1 << MW) - 1 > N_CFG:
        await _sample_error(dut, 0, N_CFG + 1, 2)

    # required coefficient not loaded -> code 3 on a fully unloaded bank
    await _reset(dut)
    if N_CFG >= 2:
        await _sample_error(dut, 0, 2, 3)
    dut._log.info("T12 priority and error codes exact")


# ---------------------------------------------------------------------------
# T13 -- structural N_MODES and SKIP_ZERO_INPUT configurations
# ---------------------------------------------------------------------------
@cocotb.test(timeout_time=300, timeout_unit="sec")
async def t13_structural_config(dut):
    await _begin(dut)
    import numpy as np
    rng = np.random.default_rng(1234)
    n = N_CFG
    await _reset(dut)
    ref = RefBank()
    words = _rand_words(rng, n)
    await _load(dut, ref, words)

    digest = hashlib.sha256()
    maxcyc = 0
    for f in range(8):
        x = 0 if f % 2 else _rand_x(rng)
        rc, rt, rs = ref.step(x, n)
        res = await _frame(dut, x, n)
        cyc = _check_frame(res, rc, rt, rs, f"T13 N={N_CFG} skip={SKIPZ} f={f}")
        maxcyc = max(maxcyc, cyc)
        digest.update(repr((x, sorted(res[1].items()), res[2], res[3])).encode())
    budget = 3 * ((n + 3) // 4) + 16
    assert maxcyc <= budget, f"T13 cycles {maxcyc} > {budget}"
    if DIGEST_OUT:
        with open(DIGEST_OUT, "w", encoding="utf-8") as fh:
            fh.write(digest.hexdigest())
    dut._log.info(f"T13 structural N={N_CFG} SKIP_ZERO_INPUT={SKIPZ} "
                  f"max {maxcyc} cycles, digest {digest.hexdigest()[:16]}")


# ---------------------------------------------------------------------------
# T14 -- sustained 48-mode frames, cycle budget
# ---------------------------------------------------------------------------
@cocotb.test(timeout_time=600, timeout_unit="sec")
async def t14_full_frames(dut):
    await _begin(dut)
    import numpy as np
    if not HEAVY:
        dut._log.info("T14 skipped (requires N_MODES=48)")
        return
    rng = np.random.default_rng(14)
    n = 48
    await _reset(dut)
    ref = RefBank()
    await _load(dut, ref, _rand_words(rng, n))
    worst = 0
    for f in range(200):
        x = _rand_x(rng)
        rc, rt, rs = ref.step(x, n)
        res = await _frame(dut, x, n)
        cyc = _check_frame(res, rc, rt, rs, f"T14 frame {f}")
        worst = max(worst, cyc)
    budget = 3 * ((n + 3) // 4) + 16
    assert worst <= budget, f"T14 worst {worst} > {budget}"
    dut._log.info(f"T14 200 full frames, worst-case {worst} cycles (budget {budget})")


# ---------------------------------------------------------------------------
# runner
# ---------------------------------------------------------------------------
_TOLERATED_IVERILOG = "constant selects in always_"


def _sources():
    return [os.path.join(_ROOT, "rtl", "core", "modal_lane.sv"),
            os.path.join(_ROOT, "rtl", "core", "modal_bank.sv")]


def _iverilog_wall_check(sources, build_dir, nmodes, skipzero):
    """Compile with explicit -g2012/-Wall and reject every diagnostic except the
    known iverilog always_comb constant-select sensitivity note (out-of-range
    part selects must fail)."""
    import subprocess

    out = os.path.join(build_dir, "wallcheck.vvp")
    cmd = ["iverilog", "-g2012", "-Wall", "-o", out, "-s", "modal_bank",
           f"-Pmodal_bank.N_MODES={nmodes}",
           f"-Pmodal_bank.SKIP_ZERO_INPUT={skipzero}"] + [str(s) for s in sources]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(f"iverilog -Wall build failed ({proc.returncode}):\n"
                           f"{proc.stderr}{proc.stdout}")
    bad = []
    for line in (proc.stderr + "\n" + proc.stdout).splitlines():
        s = line.strip()
        if not s:
            continue
        low = s.lower()
        if "warning" not in low and "sorry" not in low and "error" not in low:
            continue
        if _TOLERATED_IVERILOG in s:
            continue
        bad.append(s)
    if bad:
        raise RuntimeError("iverilog -Wall diagnostics not tolerated:\n"
                           + "\n".join(bad))


def _parse_results(xml_path):
    """Return {'n':, 'failures': [...]} or None if the XML is absent/unparseable."""
    import xml.etree.ElementTree as ET

    if not os.path.exists(xml_path):
        return None
    try:
        root = ET.parse(xml_path).getroot()
    except ET.ParseError:
        return None
    suites = [root] if root.tag == "testsuite" else root.findall("testsuite")
    cases = []
    for s in suites:
        cases.extend(s.findall("testcase"))
    failures = [c.get("name", "?") for c in cases
                if c.find("failure") is not None or c.find("error") is not None]
    return {"n": len(cases), "failures": failures}


def _build_and_run(nmodes, skipzero, build_dir, testcase=None, digest=None,
                   test_module="test_modal_bank", sources=None):
    """Build + run, then fail loudly on missing/failed results XML.

    cocotb's runner only auto-checks the XML when PYTEST_CURRENT_TEST is set, so a
    plain script would otherwise exit 0 after an assertion failure.
    """
    from cocotb_tools.runner import get_runner

    srcs = list(sources) if sources else _sources()
    # Normalise to absolute: cocotb resolves a relative results_xml against
    # test_dir (sim/), not the caller's cwd.
    build_dir = os.path.abspath(os.path.expanduser(build_dir))
    if digest:
        digest = os.path.abspath(os.path.expanduser(digest))
    os.makedirs(build_dir, exist_ok=True)
    _iverilog_wall_check(srcs, build_dir, nmodes, skipzero)

    params = {"N_MODES": nmodes, "SKIP_ZERO_INPUT": skipzero}
    runner = get_runner("icarus")
    # always=True: the Icarus runner's out-of-date check uses only source mtime,
    # with no parameter hash, so a reused build_dir would silently keep the old
    # parameterisation (e.g. N1) when only N_MODES/SKIP_ZERO_INPUT change.
    runner.build(sources=srcs, hdl_toplevel="modal_bank",
                 parameters=params, build_dir=build_dir, waves=False,
                 build_args=["-Wall"], always=True,
                 timescale=("1ns", "1ps"))
    env = {"MODAL_BANK_NMODES": str(nmodes), "MODAL_BANK_SKIPZERO": str(skipzero)}
    if digest:
        env["MODAL_BANK_DIGEST_OUT"] = digest
    results_xml = os.path.join(build_dir, "results.xml")
    if os.path.exists(results_xml):
        os.remove(results_xml)
    runner.test(test_module=test_module, hdl_toplevel="modal_bank",
                test_dir=_HERE, build_dir=build_dir, parameters=params,
                extra_env=env, testcase=testcase,
                results_xml=results_xml,
                timescale=("1ns", "1ps"))

    summary = _parse_results(results_xml)
    if summary is None:
        raise RuntimeError(f"missing or unparseable results XML: {results_xml}")
    if summary["n"] == 0:
        raise RuntimeError(
            f"no tests ran (testcase filter={testcase!r}); XML {results_xml}")
    if summary["failures"]:
        raise RuntimeError(
            f"cocotb tests failed: {summary['failures']} (XML {results_xml})")
    return summary


def _matrix(base_dir):
    """T13 across N_MODES / SKIP_ZERO_INPUT, checking skip equivalence."""
    base_dir = os.path.abspath(os.path.expanduser(base_dir))
    digests = {}
    for nmodes in (1, 7, 48):
        for skipzero in (0, 1):
            label = f"N{nmodes}_s{skipzero}"
            bdir = os.path.join(base_dir, label)
            dig = os.path.join(bdir, "digest.txt")
            print(f"[matrix] build {label} -> {bdir}")
            # raises before the digest is read if the testcase did not pass
            _build_and_run(nmodes, skipzero, bdir,
                           testcase="t13_structural_config", digest=dig)
            with open(dig, encoding="utf-8") as fh:
                digests[(nmodes, skipzero)] = fh.read().strip()
        if digests[(nmodes, 0)] != digests[(nmodes, 1)]:
            print(f"[matrix] FAIL: skip 0/1 differ for N={nmodes}")
            return 1
    print("[matrix] OK: SKIP_ZERO_INPUT=0 and 1 produce identical results")
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--n-modes", type=int, default=48,
                    help="structural N_MODES (1..48, default 48)")
    ap.add_argument("--skip-zero-input", type=int, default=0, choices=(0, 1),
                    help="bypass the G multiply register when x==0 (default 0)")
    ap.add_argument("--build-dir", default=os.path.join(_ROOT, "sim", "build", "modal_bank"),
                    help="build/output directory (default sim/build/modal_bank)")
    ap.add_argument("--matrix", action="store_true",
                    help="run T13 across N_MODES in {1,7,48} and SKIP_ZERO_INPUT in {0,1}")
    args = ap.parse_args(argv)

    if not 1 <= args.n_modes <= 48:
        ap.error("--n-modes must be in 1..48")

    if args.matrix:
        try:
            return _matrix(args.build_dir)
        except RuntimeError as exc:
            print(f"[matrix] FAIL: {exc}", file=sys.stderr)
            return 1

    try:
        _build_and_run(args.n_modes, args.skip_zero_input, args.build_dir)
    except RuntimeError as exc:
        print(f"[FAIL] {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
