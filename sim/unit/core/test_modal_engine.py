"""cocotb integration regression for rtl/core/modal_engine.sv (module 2B+2C).

The engine wires the coefficient loader to the 32-voice poly bank.  These tests
drive the external load/sample ports only and check:

  * 32 voices of the real piano MIDI21 forte note over >=100 frames, compared
    per commit / per voice / overall against ``FixedModalSynth(max_poly=1,
    free_thr=0).step()``; every frame <= 1800 cycles
  * multi-instrument, multi-dynamic voices with different mode counts over a
    2048-sample window, still against FixedModalSynth
  * an active but not-loaded voice is rejected (error 4) with no partial commit
  * a failed load leaves the slot, its state and its coefficients untouched;
    reloading one slot clears only that slot's history
  * load/compute mutual exclusion and load priority
  * reset during load or compute leaves no stale load_done/out/commit

Runner: ``python sim/unit/core/test_modal_engine.py``.  Icarus + always=True, explicit
-g2012/-Wall, absolute paths, parsed XML, non-zero on any failure/no-test.
Artefacts under ``sim/build/modal_engine/``; ``sim/results.xml`` untouched.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys

import cocotb
import numpy as np
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

from fixed_point import (A1_FRAC, C_FRAC, Y_BITS, Y_MIN, Y_MAX,  # noqa: E402
                         CoeffTable, FixedModalSynth, unpack_word)
from _test_runner import build_and_run  # noqa: E402

PARAMS = os.path.join(_ROOT, "FFT_results", "params")
ROM_DIR = os.path.join(_ROOT, "rtl", "rom")
A1_SHIFT = C_FRAC - A1_FRAC

N_CFG = int(os.environ.get("ENGINE_NMODES", "48"))
V_CFG = int(os.environ.get("ENGINE_NUMVOICES", "32"))
SKIPZ = int(os.environ.get("ENGINE_SKIPZERO", "0"))
MW = max(1, N_CFG.bit_length())
VW = max(1, (V_CFG - 1).bit_length()) if V_CFG > 1 else 1
SW = max(1, (V_CFG * N_CFG).bit_length())
DIGEST_OUT = os.environ.get("ENGINE_DIGEST_OUT")

INST_CODE = {"guitar": 0, "piano": 1, "banjo": 2, "mandolin": 3}
_MEM_CACHE = {}


def _inst_mem(name):
    if name not in _MEM_CACHE:
        with open(os.path.join(PARAMS, f"{name}_coeff.mem")) as fh:
            _MEM_CACHE[name] = [int(l.strip(), 16) for l in fh if l.strip()]
    return _MEM_CACHE[name]


def _inst_index(name):
    with open(os.path.join(PARAMS, f"{name}_coeffindex.json")) as fh:
        return json.load(fh)


def _note(name, midi, dyn):
    m = _inst_index(name)[f"{midi}|{dyn}"]
    mem = _inst_mem(name)
    return mem[m["offset"]:m["offset"] + m["n_modes"]]


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


def _pack_xvec(xvec):
    w = 0
    for v, x in enumerate(xvec):
        w |= _u(x, 32) << (v * 32)
    return w


class VoiceRef:
    """One independent FixedModalSynth(max_poly=1, free_thr=0) voice."""

    def __init__(self, name, midi, dyn, vel):
        words = _note(name, midi, dyn)
        table = CoeffTable()
        a1, a2, G = [], [], []
        for w in words:
            u1, u2, u3 = unpack_word(w)
            a1.append(u1)
            a2.append(u2)
            G.append(u3)
        table.add(midi, dyn, np.array(a1, dtype=np.int64),
                  np.array(a2, dtype=np.int64), np.array(G, dtype=np.int64))
        self.words = words
        self.midi, self.dyn = midi, dyn
        self.n = len(words)
        self.synth = FixedModalSynth(table, max_poly=1, max_modes=N_CFG,
                                     free_thr=0.0)
        self.synth.note_on(midi, vel)

    def step(self):
        """Advance one sample; return (xq, commits{mode:(y1,y2,sat)}, sum, sat)."""
        p1 = self.synth.y1[0, :self.n].copy()
        p2 = self.synth.y2[0, :self.n].copy()
        self.synth.step()
        xq = int(self.synth.xq[0])
        y1 = [int(v) for v in self.synth.y1[0, :self.n]]
        y2 = [int(v) for v in self.synth.y2[0, :self.n]]
        commits = {}
        sat = 0
        for m in range(self.n):
            a1, a2, G = unpack_word(self.words[m])
            _, s = _mode_step(a1, a2, G, int(p1[m]), int(p2[m]), xq)
            commits[m] = (y1[m], int(p1[m]), s)
            sat += s
        return xq, commits, y1, y2, sat


# ---------------------------------------------------------------------------
# drivers
# ---------------------------------------------------------------------------
async def _begin(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())


async def _reset(dut):
    dut.rst_n.value = 0
    for name, val in (("load_valid", 0), ("load_voice", 0), ("load_instrument", 0),
                      ("load_midi", 0), ("load_dyn", 0), ("load_vel", 255),
                      ("sample_valid", 0),
                      ("active_mask", 0), ("x_vec", 0)):
        getattr(dut, name).value = val
    for _ in range(4):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)
    await Timer(1, unit="ns")


async def _eload(dut, voice, inst, midi, dyn, timeout=5000):
    await Timer(1, unit="ns")
    guard = 0
    while not _i(dut.load_ready):
        await RisingEdge(dut.clk)
        await Timer(1, unit="ns")
        guard += 1
        assert guard < timeout, "load_ready stuck"
    dut.load_valid.value = 1
    dut.load_voice.value = _u(voice, VW)
    dut.load_instrument.value = _u(inst, 2)
    dut.load_midi.value = _u(midi, 7)
    dut.load_dyn.value = _u(dyn, 1)
    dut.load_vel.value = 255
    await RisingEdge(dut.clk)
    await Timer(1, unit="ns")
    assert _i(dut.busy) == 1, "engine busy did not assert on load"
    dut.load_valid.value = 0
    cyc = 0
    while True:
        if _i(dut.load_done):
            dv, dn = _i(dut.done_voice), _i(dut.loaded_n_modes)
            return ("done", cyc, dv, dn)
        if _i(dut.error_valid):
            return ("error", cyc, _i(dut.error_code), 0)
        await RisingEdge(dut.clk)
        await Timer(1, unit="ns")
        cyc += 1
        assert cyc < timeout, "load did not finish"


async def _eframe(dut, act, xvec, timeout=400000):
    dut.sample_valid.value = 1
    dut.active_mask.value = _u(act, V_CFG)
    dut.x_vec.value = _pack_xvec(xvec)
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
                assert None not in (v, m, y1, y2), "X on commit bus"
                key = (v, m)
                assert key not in commits, f"duplicate commit {key}"
                commits[key] = (_s(y1, 32), _s(y2, 32),
                                (_i(dut.commit_sat) >> i) & 1)
        if _i(dut.voice_valid):
            voices.append((_i(dut.voice_id), _s(_i(dut.voice_sum), 64)))
        if _i(dut.out_valid):
            return (cyc, commits, voices, _s(_i(dut.mix_sum), 64),
                    _i(dut.sat_count))
        if _i(dut.error_valid):
            raise AssertionError(f"engine error {_i(dut.error_code)} during frame "
                                 f"after {cyc} cycles")
        cyc += 1
        assert cyc < timeout, "frame did not finish"
        await RisingEdge(dut.clk)
        await Timer(1, unit="ns")


def _check_frame(res, refs, act, nvec, where=""):
    cyc, commits, voices, mix, sat = res
    exp_commits = {}
    exp_voices = {}
    exp_sat = 0
    for v in range(V_CFG):
        if not ((act >> v) & 1):
            continue
        xq, cm, y1, y2, s = refs[v]
        for m, val in cm.items():
            exp_commits[(v, m)] = val
        exp_voices[v] = sum(y1)
        exp_sat += s
    assert set(commits) == set(exp_commits), \
        f"{where}: commit set differs ({len(commits)} vs {len(exp_commits)})"
    for k in exp_commits:
        assert commits[k] == exp_commits[k], \
            f"{where}: commit {k} {commits[k]} != {exp_commits[k]}"
    assert dict(voices) == exp_voices, f"{where}: voice sums differ"
    assert mix == sum(exp_voices.values()), f"{where}: mix"
    assert sat == exp_sat, f"{where}: sat {sat} != {exp_sat}"
    return cyc


# ---------------------------------------------------------------------------
# E01 -- 32 voices, real piano MIDI21 forte, 100 frames
# ---------------------------------------------------------------------------
@cocotb.test(timeout_time=2400, timeout_unit="sec")
async def e01_real_piano_32(dut):
    await _begin(dut)
    if N_CFG < 48 or V_CFG < 2:
        dut._log.info("E01 skipped")
        return
    await _reset(dut)
    refs = []
    nvec = []
    for v in range(V_CFG):
        vel = 0.6 + 0.4 * (v / max(1, V_CFG - 1))          # forte, distinct x
        refs.append(VoiceRef("piano", 21, "forte", vel))
        nvec.append(48)
    for v in range(V_CFG):
        kind, cyc, dv, dn = await _eload(dut, v, 1, 21, 1)
        assert kind == "done" and dv == v and dn == 48, (v, kind, dv, dn)
    act = (1 << V_CFG) - 1
    worst = 0
    total = 0
    for f in range(100):
        xvec, snap = [], []
        for v in range(V_CFG):
            xq, cm, y1, y2, s = refs[v].step()
            xvec.append(xq)
            snap.append((xq, cm, y1, y2, s))
        res = await _eframe(dut, act, xvec)
        cyc = _check_frame(res, snap, act, nvec, f"E01 frame {f}")
        worst = max(worst, cyc)
        total += len(res[1])
    assert worst <= 1800, f"E01 worst frame {worst} > 1800"
    assert total == 100 * V_CFG * 48
    dut._log.info(f"E01 32-voice piano21forte x100 frames bit-exact vs "
                  f"FixedModalSynth, worst {worst} cycles")


# ---------------------------------------------------------------------------
# E02 -- multi-instrument/dynamic, different lengths, 2048 samples
# ---------------------------------------------------------------------------
@cocotb.test(timeout_time=2400, timeout_unit="sec")
async def e02_mixed_2048(dut):
    await _begin(dut)
    if V_CFG < 2 or N_CFG < 48:
        dut._log.info("E02 skipped")
        return
    probes = [
        ("guitar", 40, "forte", 1.0),
        ("guitar", 45, "piano", 0.4),
        ("piano", 21, "forte", 0.8),
        ("piano", 24, "piano", 0.3),
        ("banjo", 48, "forte", 0.9),
        ("banjo", 55, "piano", 0.5),
        ("mandolin", 55, "piano", 0.2),
        ("mandolin", 60, "piano", 0.45),
    ]
    nv = min(V_CFG, len(probes))
    await _reset(dut)
    refs, nvec, used = [], [], []
    for v in range(nv):
        name, midi, dyn, vel = probes[v]
        ref = VoiceRef(name, midi, dyn, vel)
        kind, cyc, dv, dn = await _eload(dut, v, INST_CODE[name], midi,
                                         1 if dyn == "forte" else 0)
        assert kind == "done" and dn == ref.n, (v, name, kind, dn, ref.n)
        refs.append(ref)
        nvec.append(ref.n)
        used.append((name, midi, dyn))
    act = (1 << nv) - 1
    xbase = [0] * V_CFG
    worst = 0
    for f in range(2048):
        xvec = list(xbase)
        snap = []
        for v in range(nv):
            xq, cm, y1, y2, s = refs[v].step()
            xvec[v] = xq
            snap.append((xq, cm, y1, y2, s))
        res = await _eframe(dut, act, xvec)
        cyc = _check_frame(res, snap, act, nvec, f"E02 frame {f}")
        worst = max(worst, cyc)
    dut._log.info(f"E02 {nv} mixed voices x2048 samples bit-exact vs "
                  f"FixedModalSynth (worst {worst} cycles)")


# ---------------------------------------------------------------------------
# E03 -- active unloaded voice rejected with error 4, no partial commit
# ---------------------------------------------------------------------------
@cocotb.test(timeout_time=600, timeout_unit="sec")
async def e03_unloaded_active(dut):
    await _begin(dut)
    if V_CFG < 2:
        dut._log.info("E03 skipped")
        return
    await _reset(dut)
    ref = VoiceRef("piano", 21, "forte", 1.0) if N_CFG >= 48 else None
    if ref is None:
        dut._log.info("E03 skipped (N<48)")
        return
    kind, cyc, dv, dn = await _eload(dut, 0, 1, 21, 1)
    assert kind == "done"
    # voice 1 active but never loaded
    dut.sample_valid.value = 1
    dut.active_mask.value = 0b11
    dut.x_vec.value = _pack_xvec([1 << 20, 1 << 20] + [0] * (V_CFG - 2))
    await Timer(1, unit="ns")
    while not _i(dut.sample_ready):
        await RisingEdge(dut.clk)
        await Timer(1, unit="ns")
    await RisingEdge(dut.clk)
    dut.sample_valid.value = 0
    await Timer(1, unit="ns")
    assert _i(dut.error_valid) == 1 and _i(dut.error_code) == 4, \
        f"expected error 4, got {_i(dut.error_valid)}/{_i(dut.error_code)}"
    assert _i(dut.busy) == 0 and _i(dut.out_valid) == 0
    # voice 0 must not have advanced: its first frame starts from zero
    xq, cm, y1, y2, s = ref.step()
    xvec = [xq] + [0] * (V_CFG - 1)
    res = await _eframe(dut, 0b1, xvec)
    _check_frame(res, [(xq, cm, y1, y2, s)], 0b1, [ref.n], "E03 after error")
    dut._log.info("E03 unloaded active voice rejected (error 4), no partial commit")


async def _run_frames(dut, refs, act, nv, steps):
    """Advance each reference one sample and drive one engine frame, checking."""
    xbase = [0] * V_CFG
    nvec = [refs[v].n for v in range(nv)] + [0] * (V_CFG - nv)
    for f in range(steps):
        xvec = list(xbase)
        snap = []
        for v in range(nv):
            xq, cm, y1, y2, s = refs[v].step()
            xvec[v] = xq
            snap.append((xq, cm, y1, y2, s))
        res = await _eframe(dut, act, xvec)
        cyc = _check_frame(res, snap, act, nvec, f"frame {f}")
    return [ [int(y) for y in refs[v].synth.y1[0, :refs[v].n]]
             for v in range(nv) ]


# ---------------------------------------------------------------------------
# E04 -- failed load keeps slot; reload one slot clears only its history
# ---------------------------------------------------------------------------
@cocotb.test(timeout_time=900, timeout_unit="sec")
async def e04_failed_load_reload(dut):
    await _begin(dut)
    if V_CFG < 2 or N_CFG < 48:
        dut._log.info("E04 skipped")
        return
    await _reset(dut)
    ref0 = VoiceRef("piano", 21, "forte", 1.0)
    ref1 = VoiceRef("guitar", 40, "forte", 0.9)
    kind, _, _, _ = await _eload(dut, 0, 1, 21, 1)
    assert kind == "done"
    kind, _, _, _ = await _eload(dut, 1, 0, 40, 1)
    assert kind == "done"
    # build up non-trivial state in both voices
    st = await _run_frames(dut, [ref0, ref1], 0b11, 2, 8)
    assert any(y != 0 for y in st[0]) and any(y != 0 for y in st[1]), st
    # a missing entry load targeting voice 0 must fail and change nothing
    kind, cyc, code, _ = await _eload(dut, 0, 0, 21, 1)  # guitar has no MIDI 21
    assert kind == "error" and code == 2, f"expected load error 2, got {kind}/{code}"
    # both voices carry on from their previous state
    await _run_frames(dut, [ref0, ref1], 0b11, 2, 4)
    old0 = [int(y) for y in ref0.synth.y1[0, :ref0.n]]
    # successfully reload voice 0: its history is cleared, voice 1 is not
    kind, _, _, _ = await _eload(dut, 0, 1, 21, 1)
    assert kind == "done"
    fresh0 = VoiceRef("piano", 21, "forte", 1.0)      # zero state
    await _run_frames(dut, [fresh0, ref1], 0b11, 2, 4)
    new0 = [int(y) for y in fresh0.synth.y1[0, :fresh0.n]]
    # the engine matched the fresh trajectory, which must differ from the old one
    assert new0 != old0, "reload did not clear the slot history"
    dut._log.info("E04 failed load untouched; reload clears only its own slot")


# ---------------------------------------------------------------------------
# E05 -- load/sample mutual exclusion and priority
# ---------------------------------------------------------------------------
@cocotb.test(timeout_time=300, timeout_unit="sec")
async def e05_mutual_exclusion(dut):
    await _begin(dut)
    if N_CFG < 48:
        dut._log.info("E05 skipped")
        return
    await _reset(dut)
    # both load and sample offered on the same idle cycle -> load wins, sample
    # is not accepted
    dut.load_valid.value = 1
    dut.load_voice.value = 0
    dut.load_instrument.value = 1
    dut.load_midi.value = 21
    dut.load_dyn.value = 1
    dut.load_vel.value = 255
    dut.sample_valid.value = 1
    dut.active_mask.value = 0
    await Timer(1, unit="ns")
    assert _i(dut.load_ready) == 1
    assert _i(dut.sample_ready) == 0, "sample accepted while load offered"
    await RisingEdge(dut.clk)
    await Timer(1, unit="ns")
    dut.load_valid.value = 0
    # loader busy -> sample_ready stays 0
    assert _i(dut.busy) == 1
    assert _i(dut.sample_ready) == 0
    cyc = 0
    while not _i(dut.load_done):
        assert _i(dut.sample_ready) == 0
        await RisingEdge(dut.clk)
        await Timer(1, unit="ns")
        cyc += 1
        assert cyc < 5000
    # after load, offer a sample then assert load_ready drops while it runs
    ref = VoiceRef("piano", 21, "forte", 1.0)
    xq, cm, y1, y2, s = ref.step()
    dut.sample_valid.value = 1
    dut.active_mask.value = 1
    dut.x_vec.value = _pack_xvec([xq] + [0] * (V_CFG - 1))
    await Timer(1, unit="ns")
    while not _i(dut.sample_ready):
        await RisingEdge(dut.clk)
        await Timer(1, unit="ns")
    await RisingEdge(dut.clk)
    await Timer(1, unit="ns")
    dut.sample_valid.value = 0
    assert _i(dut.busy) == 1
    assert _i(dut.load_ready) == 0, "load_ready high while computing"
    while not _i(dut.out_valid):
        await RisingEdge(dut.clk)
        await Timer(1, unit="ns")
    assert _i(dut.error_valid) == 0
    dut._log.info("E05 load/sample mutual exclusion and load priority OK")


# ---------------------------------------------------------------------------
# E06 -- reset during load / compute leaves no stale token
# ---------------------------------------------------------------------------
@cocotb.test(timeout_time=600, timeout_unit="sec")
async def e06_reset_stale(dut):
    await _begin(dut)
    if N_CFG < 4:
        dut._log.info("E06 skipped")
        return
    # reset in the middle of a load
    await _reset(dut)
    dut.load_valid.value = 1
    dut.load_voice.value = 0
    dut.load_instrument.value = 1
    dut.load_midi.value = 21
    dut.load_dyn.value = 1
    dut.load_vel.value = 255
    await Timer(1, unit="ns")
    while not _i(dut.load_ready):
        await RisingEdge(dut.clk)
        await Timer(1, unit="ns")
    await RisingEdge(dut.clk)
    dut.load_valid.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
        await Timer(1, unit="ns")
    dut.rst_n.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
        await Timer(1, unit="ns")
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)
    await Timer(1, unit="ns")
    assert _i(dut.load_done) == 0 and _i(dut.out_valid) == 0
    assert _i(dut.commit_valid) == 0 and _i(dut.error_valid) == 0
    assert _i(dut.busy) == 0
    # an active voice is now unloaded again -> error 4
    if V_CFG >= 1:
        dut.sample_valid.value = 1
        dut.active_mask.value = 1
        await Timer(1, unit="ns")
        while not _i(dut.sample_ready):
            await RisingEdge(dut.clk)
            await Timer(1, unit="ns")
        await RisingEdge(dut.clk)
        dut.sample_valid.value = 0
        await Timer(1, unit="ns")
        assert _i(dut.error_valid) == 1 and _i(dut.error_code) == 4
    # reset in the middle of a compute
    if N_CFG >= 48:
        await _reset(dut)
        for v in range(min(V_CFG, 4)):
            kind, _, _, _ = await _eload(dut, v, 1, 21, 1)
            assert kind == "done"
        nv = min(V_CFG, 4)
        dut.sample_valid.value = 1
        dut.active_mask.value = (1 << nv) - 1
        dut.x_vec.value = _pack_xvec([1 << 20] * nv + [0] * (V_CFG - nv))
        await Timer(1, unit="ns")
        while not _i(dut.sample_ready):
            await RisingEdge(dut.clk)
            await Timer(1, unit="ns")
        await RisingEdge(dut.clk)
        dut.sample_valid.value = 0
        for _ in range(7):
            await RisingEdge(dut.clk)
            await Timer(1, unit="ns")
        dut.rst_n.value = 0
        for _ in range(3):
            await RisingEdge(dut.clk)
            await Timer(1, unit="ns")
        dut.rst_n.value = 1
        await RisingEdge(dut.clk)
        await Timer(1, unit="ns")
        assert _i(dut.out_valid) == 0 and _i(dut.commit_valid) == 0
        assert _i(dut.load_done) == 0
    dut._log.info("E06 reset leaves no stale load_done/out/commit")


# ---------------------------------------------------------------------------
# E07 -- deterministic digest for the skip0/skip1 matrix
# ---------------------------------------------------------------------------
def _fitting_keys():
    """One loadable (instrument, midi, dyn) per instrument for this N_MODES."""
    out = []
    for name in ("piano", "guitar", "banjo", "mandolin"):
        idx = _inst_index(name)
        for key, meta in sorted(idx.items()):
            if meta["n_modes"] <= N_CFG:
                midi, dyn = key.split("|")
                out.append((name, int(midi), dyn))
                break
    return out


@cocotb.test(timeout_time=600, timeout_unit="sec")
async def e07_digest(dut):
    """Skip0/skip1 equivalence digest: same deterministic stimulus, no reference."""
    await _begin(dut)
    await _reset(dut)
    nv = min(V_CFG, 3)
    fits = _fitting_keys()
    used = 0
    for v in range(min(nv, len(fits))):
        name, midi, dyn = fits[v]
        kind, _, _, _ = await _eload(dut, v, INST_CODE[name], midi,
                                     1 if dyn == "forte" else 0)
        assert kind == "done", (v, name, midi, dyn, kind)
        used += 1
    act = (1 << used) - 1
    digest = hashlib.sha256()
    xrng = np.random.default_rng(7)
    mask = (1 << 31) - 1
    for f in range(64):
        xvec = [0] * V_CFG
        for v in range(used):
            val = int(xrng.integers(-(1 << 30), 1 << 30))
            # force a genuine zero input sometimes to hit the skip path
            xvec[v] = 0 if (f % 5 == 0) else (val & mask) - (1 << 30)
        res = await _eframe(dut, act, xvec)
        digest.update(repr((f, sorted(res[1].items()), sorted(res[2]),
                            res[3], res[4])).encode())
    if DIGEST_OUT:
        with open(DIGEST_OUT, "w", encoding="utf-8") as fh:
            fh.write(digest.hexdigest())
    dut._log.info(f"E07 digest {digest.hexdigest()[:16]} ({used} voices)")


# ---------------------------------------------------------------------------
# runner
# ---------------------------------------------------------------------------
def _sources():
    return [os.path.join(_ROOT, "rtl", "core", "coeff_loader.sv"),
            os.path.join(_ROOT, "rtl", "core", "poly_modal_lane.sv"),
            os.path.join(_ROOT, "rtl", "core", "modal_poly_bank.sv"),
            os.path.join(_ROOT, "rtl", "core", "modal_engine.sv")]


def _params(nmodes, nvoices, skipz):
    return {
        "N_MODES": nmodes, "NUM_VOICES": nvoices, "SKIP_ZERO_INPUT": skipz,
        "COEFF_FILE": '"' + os.path.join(ROM_DIR, "modal_coeff.mem") + '"',
        "INDEX_FILE": '"' + os.path.join(ROM_DIR, "modal_index.mem") + '"',
    }


def _run_one(nmodes, nvoices, skipz, build_dir, testcase=None, digest=None):
    env = {"ENGINE_NMODES": str(nmodes), "ENGINE_NUMVOICES": str(nvoices),
           "ENGINE_SKIPZERO": str(skipz)}
    if digest:
        env["ENGINE_DIGEST_OUT"] = digest
    return build_and_run(_sources(), "modal_engine", "test_modal_engine", _HERE,
                         build_dir, _params(nmodes, nvoices, skipz), env,
                         testcase=testcase)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--n-modes", type=int, default=48)
    ap.add_argument("--num-voices", type=int, default=32)
    ap.add_argument("--skip-zero-input", type=int, default=0, choices=(0, 1))
    ap.add_argument("--build-dir",
                    default=os.path.join(_ROOT, "sim", "build", "modal_engine"))
    ap.add_argument("--testcase", default=None)
    ap.add_argument("--matrix", action="store_true")
    args = ap.parse_args(argv)

    global N_CFG, V_CFG, MW, VW, SW
    if args.matrix:
        base = os.path.abspath(os.path.expanduser(args.build_dir))
        ok = True
        for n in (1, 7, 48):
            for v in (1, 3, 32):
                digests = {}
                for s in (0, 1):
                    label = f"N{n}_V{v}_s{s}"
                    bdir = os.path.join(base, label)
                    dig = os.path.join(bdir, "digest.txt")
                    print(f"[matrix] {label}")
                    try:
                        _run_one(n, v, s, bdir, testcase="e07_digest",
                                 digest=dig)
                    except RuntimeError as exc:
                        print(f"[matrix] FAIL {label}: {exc}", file=sys.stderr)
                        ok = False
                        continue
                    with open(dig, encoding="utf-8") as fh:
                        digests[s] = fh.read().strip()
                if len(digests) == 2 and digests[0] != digests[1]:
                    print(f"[matrix] FAIL N={n} V={v}: skip0/skip1 differ",
                          file=sys.stderr)
                    ok = False
        print("[matrix] OK" if ok else "[matrix] FAIL")
        return 0 if ok else 1

    N_CFG, V_CFG = args.n_modes, args.num_voices
    MW = max(1, N_CFG.bit_length())
    VW = max(1, (V_CFG - 1).bit_length()) if V_CFG > 1 else 1
    SW = max(1, (V_CFG * N_CFG).bit_length())
    try:
        summary = _run_one(args.n_modes, args.num_voices, args.skip_zero_input,
                           args.build_dir, args.testcase)
    except RuntimeError as exc:
        print(f"[FAIL] {exc}", file=sys.stderr)
        return 1
    print(f"[modal_engine] {summary['n']} tests PASS "
          f"(N={args.n_modes}, V={args.num_voices}, skip={args.skip_zero_input})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
