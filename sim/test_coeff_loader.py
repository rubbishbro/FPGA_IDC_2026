"""cocotb regression for rtl/core/coeff_loader.sv (module 2B).

Checks the loader against the *original* per-instrument ``*.mem`` /
``*_coeffindex.json`` files and the generated merged ROM images:

  * all 250 valid keys load, word-for-word, with exactly one clear before the
    first coefficient write and load_done after the final handshake
  * all 1024 dense index combinations: a present key loads, a missing key is
    rejected with error_code 2 and *no* clear/cfg
  * fixed random and hard backpressure: fields never move while blocked and no
    word is lost or duplicated
  * reset during lookup / clear / mid-stream / final word leaves no ghost
    completion
  * no-backpressure load latency <= 4*n+24 and error latency <= 16 cycles
  * a structural N_MODES smaller than the entry is rejected (error 3), never
    silently truncated
  * the offline generator is byte-for-byte reproducible and rejects malformed
    JSON / out-of-range MIDI / illegal dynamic / extra words

Runner (``python sim/test_coeff_loader.py``) builds with Icarus, always
recompiles, uses explicit -g2012/-Wall, absolute paths and an explicitly parsed
results XML.  Artefacts go under ``sim/build/coeff_loader/``; ``sim/results.xml``
is never touched.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import random
import shutil
import sys
import tempfile

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = os.path.dirname(_HERE)
sys.path.insert(0, os.path.join(_ROOT, "python", "modal_sim"))
sys.path.insert(0, os.path.join(_ROOT, "python"))

from fixed_point import unpack_word  # noqa: E402
import gen_hw_rom as G  # noqa: E402

PARAMS = os.path.join(_ROOT, "FFT_results", "params")
ROM_DIR = os.path.join(_ROOT, "rtl", "rom")

N_CFG = int(os.environ.get("LOADER_NMODES", "48"))
V_CFG = int(os.environ.get("LOADER_NUMVOICES", "32"))
MW = max(1, N_CFG.bit_length())
VW = max(1, (V_CFG - 1).bit_length()) if V_CFG > 1 else 1

COEFF_WORDS = G.read_mem(os.path.join(ROM_DIR, "modal_coeff.mem"))
INDEX_WORDS = [int(l.strip(), 16) for l in
               open(os.path.join(ROM_DIR, "modal_index.mem")) if l.strip()]


def _addr(inst, midi, dyn):
    return (inst << 8) | (midi << 1) | dyn


_KEYS_CACHE = None


def _longest():
    fits = [x for x in _all_keys() if x["n"] <= N_CFG]
    return max(fits, key=lambda x: x["n"]) if fits else None


def _all_keys():
    """250 original entries: dict(inst, midi, dyn, n, words)."""
    global _KEYS_CACHE
    if _KEYS_CACHE is not None:
        return _KEYS_CACHE
    out = []
    for name, code in G.INSTRUMENTS:
        mem, entries = G.load_instrument(PARAMS, name)
        for midi, dyn, off, n in entries:
            out.append(dict(inst=code, name=name, midi=midi, dyn=dyn,
                            dyncode=G.DYN_CODE[dyn], n=n,
                            words=mem[off:off + n]))
    _KEYS_CACHE = out
    return out


def _u(v, w):
    return int(v) & ((1 << w) - 1)


def _i(sig):
    """int() of a possibly-X signal, returning 0 while unresolved."""
    try:
        return int(sig.value)
    except ValueError:
        return 0


def _s(v, w):
    v = int(v) & ((1 << w) - 1)
    return v - (1 << w) if (v >> (w - 1)) else v


class Sink:
    """Downstream clear/cfg sink with configurable ready and an event log."""

    def __init__(self, mode="ready", seed=0):
        self.mode = mode
        self.rng = random.Random(seed)
        self.events = []
        self.cycle = 0
        self.block_until = 0

    def _cfg_ready(self):
        if self.mode == "ready":
            return True
        if self.mode == "random":
            return self.rng.random() < 0.5
        if self.mode == "block":
            return self.cycle >= self.block_until
        return True

    async def run(self, dut):
        # previous-cycle values (the handshake at this edge uses last cycle's
        # valid and the ready we drove for that cycle)
        pv = pcv = pdone = perr = 0
        pword = pmode = pvoice = pcvoice = 0
        prc = True
        prst = 1
        while True:
            await RisingEdge(dut.clk)
            await Timer(1, unit="ns")

            # handshake(s) that completed at this edge
            if prst:
                if pv and prc:
                    self.events.append(dict(cycle=self.cycle, kind="cfg",
                                            voice=pvoice, mode=pmode,
                                            word=pword))
                if pcv:
                    self.events.append(dict(cycle=self.cycle, kind="clear",
                                            voice=pcvoice))
                if pdone:
                    self.events.append(dict(cycle=self.cycle, kind="done",
                                            voice=_i(dut.done_voice),
                                            n=_i(dut.loaded_n_modes)))
                if perr:
                    self.events.append(dict(cycle=self.cycle, kind="error",
                                            code=_i(dut.error_code)))

            # sample this cycle and drive ready for it
            v = _i(dut.cfg_valid)
            pword = _i(dut.cfg_word) if v else 0
            pmode = _i(dut.cfg_mode) if v else 0
            pvoice = _i(dut.cfg_voice) if v else 0
            pcv = _i(dut.clear_valid)
            pcvoice = _i(dut.clear_voice) if pcv else 0
            pdone = _i(dut.load_done)
            perr = _i(dut.error_valid)
            prst = _i(dut.rst_n)
            prc = self._cfg_ready()
            pv = v if prst else 0
            dut.cfg_ready.value = 1 if prc else 0
            dut.clear_ready.value = 1
            self.cycle += 1
            await Timer(1, unit="ns")


async def _begin(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())


async def _reset(dut, sink):
    dut.rst_n.value = 0
    dut.load_valid.value = 0
    dut.load_voice.value = 0
    dut.load_instrument.value = 0
    dut.load_midi.value = 0
    dut.load_dyn.value = 0
    dut.cfg_ready.value = 1
    dut.clear_ready.value = 1
    for _ in range(4):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)
    await Timer(1, unit="ns")
    sink.events.clear()


async def _load(dut, sink, voice, inst, midi, dyn):
    """Present one load request; return (kind, cycles, code)."""
    await Timer(1, unit="ns")
    guard = 0
    while not int(dut.load_ready.value):
        await RisingEdge(dut.clk)
        await Timer(1, unit="ns")
        guard += 1
        assert guard < 5000, "load_ready stuck"
    dut.load_valid.value = 1
    dut.load_voice.value = _u(voice, VW)
    dut.load_instrument.value = _u(inst, 2)
    dut.load_midi.value = _u(midi, 7)
    dut.load_dyn.value = _u(dyn, 1)
    await RisingEdge(dut.clk)                    # handshake edge
    await Timer(1, unit="ns")
    assert _i(dut.busy) == 1, "busy did not assert after load handshake"
    dut.load_valid.value = 0
    cyc = 0
    while True:
        if _i(dut.load_done):
            await _settle(dut)
            return ("done", cyc, 0)
        if _i(dut.error_valid):
            await _settle(dut)
            return ("error", cyc, _i(dut.error_code))
        await RisingEdge(dut.clk)
        await Timer(1, unit="ns")
        cyc += 1
        assert cyc < 100000, "load transaction did not finish"


async def _settle(dut):
    """Let the downstream monitor record the terminal event before analysis."""
    for _ in range(3):
        await RisingEdge(dut.clk)
        await Timer(1, unit="ns")


def _cfg_events(sink, voice):
    return [e for e in sink.events if e["kind"] == "cfg" and e["voice"] == voice]


def _clear_events(sink, voice):
    return [e for e in sink.events if e["kind"] == "clear" and e["voice"] == voice]


# ---------------------------------------------------------------------------
# T01 -- reset / idle
# ---------------------------------------------------------------------------
@cocotb.test(timeout_time=60, timeout_unit="sec")
async def t01_reset_idle(dut):
    sink = Sink()
    await _begin(dut)
    cocotb.start_soon(sink.run(dut))
    await _reset(dut, sink)
    for name in ("load_ready", "busy", "load_done", "error_valid", "error_code",
                 "clear_valid", "cfg_valid", "done_voice", "loaded_n_modes"):
        assert getattr(dut, name).value.is_resolvable, f"{name} is X after reset"
    assert int(dut.load_ready.value) == 1
    assert int(dut.busy.value) == 0
    assert int(dut.load_done.value) == 0
    assert int(dut.clear_valid.value) == 0
    assert int(dut.cfg_valid.value) == 0
    dut._log.info("T01 reset/idle OK")


# ---------------------------------------------------------------------------
# T02 -- all valid keys load word-for-word
# ---------------------------------------------------------------------------
@cocotb.test(timeout_time=900, timeout_unit="sec")
async def t02_all_valid_keys(dut):
    sink = Sink()
    await _begin(dut)
    cocotb.start_soon(sink.run(dut))
    await _reset(dut, sink)

    keys = _all_keys()
    assert len(keys) == 250, f"expected 250 keys, got {len(keys)}"
    total_words = 0
    skipped = 0
    for i, k in enumerate(keys):
        if k["n"] > N_CFG:
            voice = i % V_CFG
            sink.events.clear()
            kind, cyc, code = await _load(dut, sink, voice, k["inst"], k["midi"],
                                          k["dyncode"])
            assert kind == "error" and code == 3, \
                f"over-limit key {k['name']} midi{k['midi']}: {kind}/{code}"
            assert _cfg_events(sink, voice) == [] and _clear_events(sink, voice) == []
            skipped += 1
            continue
        voice = i % V_CFG
        sink.events.clear()
        kind, cyc, code = await _load(dut, sink, voice, k["inst"], k["midi"],
                                      k["dyncode"])
        assert kind == "done", \
            f"key {k['name']} midi{k['midi']} {k['dyn']}: got {kind} code {code}"
        cfgs = _cfg_events(sink, voice)
        assert len(cfgs) == k["n"], \
            f"key {k['name']} midi{k['midi']} {k['dyn']}: {len(cfgs)} cfg != {k['n']}"
        assert [c["mode"] for c in cfgs] == list(range(k["n"])), "mode order wrong"
        got = [c["word"] for c in cfgs]
        assert got == k["words"], \
            f"key {k['name']} midi{k['midi']} {k['dyn']}: coefficient mismatch"
        clears = _clear_events(sink, voice)
        assert len(clears) == 1, f"expected exactly one clear, got {clears}"
        assert clears[0]["cycle"] < cfgs[0]["cycle"], "clear not before first cfg"
        done = [e for e in sink.events if e["kind"] == "done"]
        assert len(done) == 1 and done[0]["voice"] == voice
        assert done[0]["cycle"] >= cfgs[-1]["cycle"], "load_done before last cfg"
        assert done[0]["n"] == k["n"], "loaded_n_modes wrong"
        total_words += k["n"]
    if N_CFG >= 48:
        assert total_words == 5483, f"loaded {total_words} words"
        assert skipped == 0
    dut._log.info(f"T02 keys loaded bit-exact ({total_words} words, {skipped} "
                  f"over-limit rejected at N={N_CFG})")


# ---------------------------------------------------------------------------
# T03 -- all 1024 index combinations, missing entries rejected
# ---------------------------------------------------------------------------
@cocotb.test(timeout_time=900, timeout_unit="sec")
async def t03_dense_index(dut):
    sink = Sink()
    await _begin(dut)
    cocotb.start_soon(sink.run(dut))
    await _reset(dut, sink)

    valid = set()
    meta = {}
    for k in _all_keys():
        valid.add(_addr(k["inst"], k["midi"], k["dyncode"]))
        meta[_addr(k["inst"], k["midi"], k["dyncode"])] = k

    n_valid = n_missing = n_over = 0
    for addr in range(1024):
        inst = addr >> 8
        midi = (addr >> 1) & 0x7F
        dyn = addr & 1
        voice = addr % V_CFG
        sink.events.clear()
        kind, cyc, code = await _load(dut, sink, voice, inst, midi, dyn)
        if addr in valid:
            k = meta[addr]
            if k["n"] > N_CFG:
                assert kind == "error" and code == 3, \
                    f"addr {addr}: over-limit entry not rejected ({kind}/{code})"
                assert _cfg_events(sink, voice) == [] and _clear_events(sink, voice) == []
                n_over += 1
                continue
            assert kind == "done", f"addr {addr}: expected done, got {kind}/{code}"
            cfgs = _cfg_events(sink, voice)
            assert len(cfgs) == k["n"] and [c["mode"] for c in cfgs] == list(range(k["n"]))
            assert [c["word"] for c in cfgs] == k["words"]
            n_valid += 1
        else:
            assert kind == "error" and code == 2, \
                f"addr {addr}: expected error2, got {kind}/{code}"
            assert _cfg_events(sink, voice) == [], "missing entry wrote coefficients"
            assert _clear_events(sink, voice) == [], "missing entry cleared state"
            assert not [e for e in sink.events if e["kind"] == "done"]
            n_missing += 1
    if N_CFG >= 48:
        assert n_valid == 250 and n_missing == 774 and n_over == 0, \
            (n_valid, n_missing, n_over)
    dut._log.info(f"T03 dense index: {n_valid} present / {n_missing} missing / "
                  f"{n_over} over-limit exact (N={N_CFG})")


# ---------------------------------------------------------------------------
# T04 -- backpressure: fields stable, no lost/duplicated words
# ---------------------------------------------------------------------------
@cocotb.test(timeout_time=600, timeout_unit="sec")
async def t04_backpressure(dut):
    sink = Sink()
    await _begin(dut)
    cocotb.start_soon(sink.run(dut))
    await _reset(dut, sink)

    keys = [k for k in _all_keys() if k["n"] <= N_CFG]
    if not keys:
        dut._log.info("T04 skipped (no entry fits structural N)")
        return
    probe = max(keys, key=lambda k: k["n"])
    vb = V_CFG - 1
    vr = min(2, V_CFG - 1)

    # hard block: hold cfg_ready low for 30 cycles and verify absolute stability
    sink.events.clear()
    sink.mode = "block"
    sink.block_until = sink.cycle + 500          # far ahead; we release manually
    await Timer(1, unit="ns")
    # drive the request up to the clear, then we will observe cfg_valid
    while not int(dut.load_ready.value):
        await RisingEdge(dut.clk)
        await Timer(1, unit="ns")
    dut.load_valid.value = 1
    dut.load_voice.value = _u(vb, VW)
    dut.load_instrument.value = _u(probe["inst"], 2)
    dut.load_midi.value = _u(probe["midi"], 7)
    dut.load_dyn.value = _u(probe["dyncode"], 1)
    await RisingEdge(dut.clk)
    await Timer(1, unit="ns")
    dut.load_valid.value = 0
    # advance until cfg_valid is presented
    g = 0
    while not int(dut.cfg_valid.value):
        await RisingEdge(dut.clk)
        await Timer(1, unit="ns")
        g += 1
        assert g < 200
    held_word = int(dut.cfg_word.value)
    held_mode = int(dut.cfg_mode.value)
    held_voice = int(dut.cfg_voice.value)
    for _ in range(30):
        assert int(dut.cfg_valid.value) == 1, "cfg_valid dropped while blocked"
        assert int(dut.cfg_word.value) == held_word, "cfg_word moved while blocked"
        assert int(dut.cfg_mode.value) == held_mode, "cfg_mode moved while blocked"
        assert int(dut.cfg_voice.value) == held_voice, "cfg_voice moved while blocked"
        await RisingEdge(dut.clk)
        await Timer(1, unit="ns")
    # release and finish
    sink.mode = "ready"
    sink.events.clear()
    kind, cyc, code = await _wait_done(dut, sink)
    assert kind == "done", f"blocked load ended {kind}/{code}"
    cfgs = _cfg_events(sink, vb)
    assert len(cfgs) == probe["n"]
    assert [c["mode"] for c in cfgs] == list(range(probe["n"]))
    assert [c["word"] for c in cfgs] == probe["words"], "blocked load word mismatch"

    # fixed random backpressure on another long load
    sink.mode = "random"
    sink.rng = random.Random(1234)
    sink.events.clear()
    kind, cyc, code = await _load(dut, sink, vr, probe["inst"], probe["midi"],
                                  probe["dyncode"])
    assert kind == "done"
    cfgs = _cfg_events(sink, vr)
    assert [c["word"] for c in cfgs] == probe["words"], "random-bp word mismatch"
    assert [c["mode"] for c in cfgs] == list(range(probe["n"]))
    sink.mode = "ready"
    dut._log.info("T04 backpressure stability and completeness OK")


async def _wait_done(dut, sink):
    cyc = 0
    while True:
        if _i(dut.load_done):
            await _settle(dut)
            return ("done", cyc, 0)
        if _i(dut.error_valid):
            await _settle(dut)
            return ("error", cyc, _i(dut.error_code))
        await RisingEdge(dut.clk)
        await Timer(1, unit="ns")
        cyc += 1
        assert cyc < 100000


# ---------------------------------------------------------------------------
# T05 -- busy: ready low, inputs ignored, repeat load allowed
# ---------------------------------------------------------------------------
@cocotb.test(timeout_time=300, timeout_unit="sec")
async def t05_busy_toxic(dut):
    sink = Sink()
    await _begin(dut)
    cocotb.start_soon(sink.run(dut))
    await _reset(dut, sink)
    k = _longest()
    if k is None:
        dut._log.info("T05 skipped (no entry fits structural N)")
        return

    # start a load and, while busy, poison every load input
    vs = min(1, V_CFG - 1)
    sink.events.clear()
    await Timer(1, unit="ns")
    while not int(dut.load_ready.value):
        await RisingEdge(dut.clk)
        await Timer(1, unit="ns")
    dut.load_valid.value = 1
    dut.load_voice.value = _u(vs, VW)
    dut.load_instrument.value = _u(k["inst"], 2)
    dut.load_midi.value = _u(k["midi"], 7)
    dut.load_dyn.value = _u(k["dyncode"], 1)
    await RisingEdge(dut.clk)
    await Timer(1, unit="ns")
    assert int(dut.load_ready.value) == 0, "load_ready high while busy"
    # poison
    dut.load_voice.value = _u(0, VW)
    dut.load_instrument.value = 3
    dut.load_midi.value = 1
    dut.load_dyn.value = 0
    kind, cyc, code = await _wait_done(dut, sink)
    assert kind == "done"
    cfgs = _cfg_events(sink, vs)
    assert len(cfgs) == k["n"], "poisoned inputs changed the latched request"
    assert [c["word"] for c in cfgs] == k["words"]
    # repeat the same load: must succeed again with a fresh clear
    sink.events.clear()
    kind, cyc, code = await _load(dut, sink, vs, k["inst"], k["midi"], k["dyncode"])
    assert kind == "done"
    assert len(_clear_events(sink, vs)) == 1
    assert [c["word"] for c in _cfg_events(sink, vs)] == k["words"]
    dut._log.info("T05 busy/toxic/repeat OK")


# ---------------------------------------------------------------------------
# T06 -- reset at each transaction phase leaves no ghost
# ---------------------------------------------------------------------------
@cocotb.test(timeout_time=600, timeout_unit="sec")
async def t06_reset_phases(dut):
    sink = Sink()
    await _begin(dut)
    cocotb.start_soon(sink.run(dut))
    await _reset(dut, sink)
    k = _longest()
    if k is None:
        dut._log.info("T06 skipped (no entry fits structural N)")
        return

    vt = min(2, V_CFG - 1)
    L = 2 * k["n"] + 4
    cand = [0, 1, 2, 3, 4, 6, 10, L // 4, L // 2, (3 * L) // 4, L - 2]
    delays = sorted({max(0, min(d, L - 1)) for d in cand})
    for d in sorted(set(delays)):
        await _reset(dut, sink)
        dut.rst_n.value = 1
        sink.events.clear()
        await Timer(1, unit="ns")
        while not int(dut.load_ready.value):
            await RisingEdge(dut.clk)
            await Timer(1, unit="ns")
        dut.load_valid.value = 1
        dut.load_voice.value = _u(vt, VW)
        dut.load_instrument.value = _u(k["inst"], 2)
        dut.load_midi.value = _u(k["midi"], 7)
        dut.load_dyn.value = _u(k["dyncode"], 1)
        await RisingEdge(dut.clk)
        await Timer(1, unit="ns")
        dut.load_valid.value = 0
        for _ in range(d):
            await RisingEdge(dut.clk)
            await Timer(1, unit="ns")
        dut.rst_n.value = 0
        for _ in range(3):
            await RisingEdge(dut.clk)
            await Timer(1, unit="ns")
        assert int(dut.busy.value) == 0
        assert int(dut.load_done.value) == 0
        assert int(dut.cfg_valid.value) == 0
        assert int(dut.clear_valid.value) == 0
        assert not [e for e in sink.events if e["kind"] == "done"], \
            f"ghost done after reset at delay {d}"
        dut.rst_n.value = 1
        await RisingEdge(dut.clk)
        await Timer(1, unit="ns")
        sink.events.clear()
        # normal reload after reset
        kind, cyc, code = await _load(dut, sink, vt, k["inst"], k["midi"],
                                      k["dyncode"])
        assert kind == "done"
        assert [c["word"] for c in _cfg_events(sink, vt)] == k["words"]
    dut._log.info(f"T06 reset phases ({len(set(delays))}) clean")


# ---------------------------------------------------------------------------
# T07 -- latency bounds
# ---------------------------------------------------------------------------
@cocotb.test(timeout_time=300, timeout_unit="sec")
async def t07_latency(dut):
    sink = Sink()
    await _begin(dut)
    cocotb.start_soon(sink.run(dut))
    await _reset(dut, sink)

    probe = _longest()
    if probe is not None:
        sink.events.clear()
        kind, cyc, code = await _load(dut, sink, 0, probe["inst"], probe["midi"],
                                      probe["dyncode"])
        assert kind == "done"
        budget = 4 * probe["n"] + 24
        assert cyc <= budget, f"load latency {cyc} > {budget} for n={probe['n']}"
    else:
        cyc = budget = 0

    # error latency: missing entry
    missing = None
    valid = {_addr(x["inst"], x["midi"], x["dyncode"]) for x in _all_keys()}
    for addr in range(1024):
        if addr not in valid:
            missing = addr
            break
    inst, midi, dyn = missing >> 8, (missing >> 1) & 0x7F, missing & 1
    sink.events.clear()
    kind, ecyc, code = await _load(dut, sink, 0, inst, midi, dyn)
    assert kind == "error" and code == 2
    assert ecyc <= 16, f"error latency {ecyc} > 16"
    dut._log.info(f"T07 load latency {cyc}<={budget}, error latency {ecyc}<=16")


# ---------------------------------------------------------------------------
# T08 -- structural N_MODES rejection
# ---------------------------------------------------------------------------
@cocotb.test(timeout_time=300, timeout_unit="sec")
async def t08_structural_reject(dut):
    sink = Sink()
    await _begin(dut)
    cocotb.start_soon(sink.run(dut))
    await _reset(dut, sink)
    if N_CFG >= 48:
        dut._log.info("T08 skipped (N_MODES>=48; over-limit entry not representable)")
        return
    big = max(_all_keys(), key=lambda k: k["n"])
    assert big["n"] > N_CFG
    sink.events.clear()
    kind, cyc, code = await _load(dut, sink, 0, big["inst"], big["midi"],
                                  big["dyncode"])
    assert kind == "error" and code == 3, f"expected error3, got {kind}/{code}"
    assert _cfg_events(sink, 0) == [], "over-limit entry truncated and written"
    assert _clear_events(sink, 0) == [], "over-limit entry cleared state"
    dut._log.info(f"T08 over-limit entry n={big['n']} > N={N_CFG} rejected")


# ---------------------------------------------------------------------------
# T09 -- voice out of range (only representable when VW has room)
# ---------------------------------------------------------------------------
@cocotb.test(timeout_time=120, timeout_unit="sec")
async def t09_voice_oob(dut):
    sink = Sink()
    await _begin(dut)
    cocotb.start_soon(sink.run(dut))
    await _reset(dut, sink)
    if (1 << VW) <= V_CFG:
        dut._log.info("T09 skipped (voice index always valid)")
        return
    oob = V_CFG
    sink.events.clear()
    await Timer(1, unit="ns")
    while not int(dut.load_ready.value):
        await RisingEdge(dut.clk)
        await Timer(1, unit="ns")
    dut.load_valid.value = 1
    dut.load_voice.value = _u(oob, VW)
    dut.load_instrument.value = 0
    dut.load_midi.value = 40
    dut.load_dyn.value = 1
    await RisingEdge(dut.clk)
    await Timer(1, unit="ns")
    dut.load_valid.value = 0
    assert _i(dut.error_valid) == 1 and _i(dut.error_code) == 1, \
        f"expected error1, got {_i(dut.error_valid)}/{_i(dut.error_code)}"
    assert _i(dut.busy) == 0, "busy must stay low for a voice-OOB request"
    assert not [e for e in sink.events if e["kind"] in ("cfg", "clear", "done")]
    assert _i(dut.load_ready) == 1
    dut._log.info(f"T09 voice {oob} out of range rejected with error 1")


# ---------------------------------------------------------------------------
# offline generator checks (run by the CLI, not under cocotb)
# ---------------------------------------------------------------------------
def _generator_checks():
    """Return a list of failure strings (empty == pass)."""
    fails = []
    probe = tempfile.mkdtemp(prefix="gen_hw_rom_")
    try:
        before = {p: hashlib.sha256(open(p, "rb").read()).hexdigest()
                  for p in _source_files()}

        cw1, iw1, m1 = G.build(PARAMS)
        cw2, iw2, m2 = G.build(PARAMS)
        if cw1 != cw2 or iw1 != iw2:
            fails.append("generator not reproducible in memory")
        if m1["total_modes"] != 5483 or m1["total_entries"] != 250:
            fails.append(f"bad totals {m1['total_modes']}/{m1['total_entries']}")

        # committed images must equal a fresh build
        cpath, ipath, _ = G.write_products(cw1, iw1, m1, probe)
        if open(cpath).read() != open(os.path.join(ROM_DIR, "modal_coeff.mem")).read():
            fails.append("committed modal_coeff.mem differs from fresh build")
        if open(ipath).read() != open(os.path.join(ROM_DIR, "modal_index.mem")).read():
            fails.append("committed modal_index.mem differs from fresh build")

        def bad_dir():
            d = tempfile.mkdtemp(prefix="genbad_", dir=probe)
            for name, _ in G.INSTRUMENTS:
                shutil.copy(os.path.join(PARAMS, f"{name}_coeff.mem"), d)
                shutil.copy(os.path.join(PARAMS, f"{name}_coeffindex.json"), d)
            return d

        # malformed JSON
        d = bad_dir()
        with open(os.path.join(d, "piano_coeffindex.json"), "w") as fh:
            fh.write("{not json")
        fails += _expect_reject(d, "malformed JSON")

        # MIDI out of range
        d = bad_dir()
        _mutate_json(d, "guitar_coeffindex.json",
                     lambda o: o.update({("200|forte"): o.pop("40|forte")}))
        fails += _expect_reject(d, "MIDI out of range")

        # illegal dynamic
        d = bad_dir()
        _mutate_json(d, "banjo_coeffindex.json",
                     lambda o: o.update({("48|mezzo"): o.pop("48|forte")}))
        fails += _expect_reject(d, "illegal dynamic")

        # offset out of range
        d = bad_dir()
        _mutate_json(d, "mandolin_coeffindex.json",
                     lambda o: o["55|piano"].update({"offset": 10 ** 6}))
        fails += _expect_reject(d, "offset out of range")

        # n_modes > 48
        d = bad_dir()
        _mutate_json(d, "piano_coeffindex.json",
                     lambda o: o["21|forte"].update({"n_modes": 49}))
        fails += _expect_reject(d, "n_modes > 48")

        # extra word appended to a mem
        d = bad_dir()
        with open(os.path.join(d, "banjo_coeff.mem"), "a") as fh:
            fh.write("000000000000000000\n")
        fails += _expect_reject(d, "extra coefficient word")

        after = {p: hashlib.sha256(open(p, "rb").read()).hexdigest()
                 for p in _source_files()}
        if before != after:
            fails.append("original source files were modified")
    except Exception as exc:  # noqa: BLE001
        fails.append(f"generator exception: {exc!r}")
    finally:
        shutil.rmtree(probe, ignore_errors=True)
    return fails


def _source_files():
    out = []
    for name, _ in G.INSTRUMENTS:
        out.append(os.path.join(PARAMS, f"{name}_coeff.mem"))
        out.append(os.path.join(PARAMS, f"{name}_coeffindex.json"))
    return out


def _mutate_json(d, name, fn):
    p = os.path.join(d, name)
    with open(p) as fh:
        o = json.load(fh)
    fn(o)
    with open(p, "w") as fh:
        json.dump(o, fh)


def _expect_reject(d, why):
    try:
        G.build(d)
    except G.RomError:
        return []
    except Exception as exc:  # noqa: BLE001
        return [f"{why}: wrong exception {exc!r}"]
    return [f"{why}: generator accepted bad input"]


# ---------------------------------------------------------------------------
# runner
# ---------------------------------------------------------------------------
_TOLERATED = "constant selects in always_"


def _sources():
    return [os.path.join(_ROOT, "rtl", "core", "coeff_loader.sv")]


def _params():
    return {
        "N_MODES": N_CFG,
        "NUM_VOICES": V_CFG,
        "COEFF_FILE": '"' + os.path.join(ROM_DIR, "modal_coeff.mem") + '"',
        "INDEX_FILE": '"' + os.path.join(ROM_DIR, "modal_index.mem") + '"',
    }


def _iverilog_wall_check(build_dir):
    import subprocess
    out = os.path.join(build_dir, "wallcheck.vvp")
    cmd = ["iverilog", "-g2012", "-Wall", "-o", out, "-s", "coeff_loader"]
    for k, v in _params().items():
        cmd.append(f"-Pcoeff_loader.{k}={v}")
    cmd += [str(s) for s in _sources()]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(f"iverilog -Wall failed:\n{proc.stderr}{proc.stdout}")
    bad = []
    for line in (proc.stderr + "\n" + proc.stdout).splitlines():
        s = line.strip()
        if not s or ("warning" not in s.lower() and "error" not in s.lower()
                     and "sorry" not in s.lower()):
            continue
        if _TOLERATED in s:
            continue
        bad.append(s)
    if bad:
        raise RuntimeError("iverilog -Wall diagnostics not tolerated:\n"
                           + "\n".join(bad))


def _parse_results(xml_path):
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


def _build_and_run(build_dir, testcase=None):
    from cocotb_tools.runner import get_runner
    build_dir = os.path.abspath(os.path.expanduser(build_dir))
    os.makedirs(build_dir, exist_ok=True)
    _iverilog_wall_check(build_dir)
    runner = get_runner("icarus")
    runner.build(sources=_sources(), hdl_toplevel="coeff_loader",
                 parameters=_params(), build_dir=build_dir, waves=False,
                 build_args=["-Wall"], always=True, timescale=("1ns", "1ps"))
    env = {"LOADER_NMODES": str(N_CFG), "LOADER_NUMVOICES": str(V_CFG)}
    results_xml = os.path.join(build_dir, "results.xml")
    if os.path.exists(results_xml):
        os.remove(results_xml)
    runner.test(test_module="test_coeff_loader", hdl_toplevel="coeff_loader",
                test_dir=_HERE, build_dir=build_dir, parameters=_params(),
                extra_env=env, testcase=testcase, results_xml=results_xml,
                timescale=("1ns", "1ps"))
    summary = _parse_results(results_xml)
    if summary is None:
        raise RuntimeError(f"missing/unparseable results XML: {results_xml}")
    if summary["n"] == 0:
        raise RuntimeError(f"no tests ran (filter={testcase!r}); XML {results_xml}")
    if summary["failures"]:
        raise RuntimeError(f"cocotb failed: {summary['failures']} (XML {results_xml})")
    return summary


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--n-modes", type=int, default=48)
    ap.add_argument("--num-voices", type=int, default=32)
    ap.add_argument("--build-dir", default=os.path.join(_HERE, "build", "coeff_loader"))
    ap.add_argument("--testcase", default=None)
    ap.add_argument("--matrix", action="store_true")
    args = ap.parse_args(argv)

    global N_CFG, V_CFG, MW, VW

    fails = _generator_checks()
    if fails:
        for f in fails:
            print(f"[gen] FAIL: {f}", file=sys.stderr)
        return 1
    print("[gen] generator reproducible and strict")

    if args.matrix:
        base = os.path.abspath(os.path.expanduser(args.build_dir))
        ok = True
        for n in (1, 7, 48):
            for v in (1, 3, 32):
                label = f"N{n}_V{v}"
                print(f"[matrix] {label}")
                N_CFG, V_CFG = n, v
                MW = max(1, n.bit_length())
                VW = max(1, (v - 1).bit_length()) if v > 1 else 1
                try:
                    _build_and_run(os.path.join(base, label))
                except RuntimeError as exc:
                    print(f"[matrix] FAIL {label}: {exc}", file=sys.stderr)
                    ok = False
        print("[matrix] OK" if ok else "[matrix] FAIL")
        return 0 if ok else 1

    N_CFG, V_CFG = args.n_modes, args.num_voices
    MW = max(1, N_CFG.bit_length())
    VW = max(1, (V_CFG - 1).bit_length()) if V_CFG > 1 else 1

    try:
        summary = _build_and_run(args.build_dir, args.testcase)
    except RuntimeError as exc:
        print(f"[FAIL] {exc}", file=sys.stderr)
        return 1
    print(f"[coeff_loader] {summary['n']} tests PASS "
          f"(N_MODES={args.n_modes}, NUM_VOICES={args.num_voices})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
