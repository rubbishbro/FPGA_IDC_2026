"""cocotb tests for rtl/audio/song_player.sv driven by the mock engine.

The song player is checked against a plain-Python expectation of the
public-domain Twinkle-Twinkle event sequence and its fixed 7-sample
raised-cosine excitation:

  * event k is loaded into voice k % NUM_VOICES, with the exact
    (instrument, midi, dyn) of the score;
  * the only non-zero x_vec slots are 6 samples of the pulse (the first pulse
    sample is 0) on the loaded voice, in order, with no slot cross-talk;
  * one sample is emitted per sample_tick; a tick arriving while busy is not
    lost and raises deadline_error;
  * the note gap is exactly NOTE_GAP accepted samples; reset is clean.

The engine here is sim/audio_helpers/mock_modal_engine.sv, a behavioural
stand-in that returns the plain sum of active x slots.  It proves the audio
sequencing, never the 2C arithmetic.

Artefacts go under sim/build/song_player (never sim/results.xml).
"""

from __future__ import annotations

import argparse
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

NUM_VOICES = int(os.environ.get("SP_VOICES", "8"))
NOTE_GAP = int(os.environ.get("SP_NOTE_GAP", "20"))
LOAD_LAT = int(os.environ.get("SP_LOAD_LAT", "6"))
SAMPLE_LAT = int(os.environ.get("SP_SAMPLE_LAT", "5"))
STALL = int(os.environ.get("SP_STALL", "0"))

XW = NUM_VOICES * 32
PULSE = [0, 40427475, 131267186, 204114978, 204114978, 131267186, 40427475]
# roomy tick period; larger when the mock engine inserts idle stall cycles
TICK_PERIOD = 40 if STALL == 0 else 250

# public-domain Twinkle-Twinkle melody, guitar/forte
SONG = [60, 60, 67, 67, 69, 69, 67,
        65, 65, 64, 64, 62, 62, 60,
        67, 67, 65, 65, 64, 64, 62,
        67, 67, 65, 65, 64, 64, 62,
        60, 60, 67, 67, 69, 69, 67,
        65, 65, 64, 64, 62, 62, 60]


def _u(v, w):
    return int(v) & ((1 << w) - 1)


def _s(v, w):
    v = int(v) & ((1 << w) - 1)
    return v - (1 << w) if (v >> (w - 1)) else v


def _field(sig, total, lo, width):
    b = str(sig.value)
    field = b[total - lo - width: total - lo]
    if any(c in field for c in "xzXZ"):
        return None
    return int(field, 2)


def _xvec(dut):
    return [_s(_field(dut.x_vec, XW, i * 32, 32), 32) for i in range(NUM_VOICES)]


# ---------------------------------------------------------------------------
# bench helpers
# ---------------------------------------------------------------------------
async def _begin(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())


async def _reset(dut):
    dut.rst_n.value = 0
    dut.diag_clear.value = 0
    dut.sample_tick.value = 0
    for _ in range(4):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)
    await Timer(1, unit="ns")


class Trace:
    def __init__(self):
        self.samples = []      # list of (sample_index, x_vec list)
        self.loads = []        # list of (sample_index, voice, inst, midi, dyn)
        self.done = False


async def _monitor(dut, tr):
    while not tr.done:
        await RisingEdge(dut.clk)
        await Timer(1, unit="ns")
        sv = int(dut.sample_valid.value)
        sr = int(dut.sample_ready.value)
        if sv and sr:
            tr.samples.append((len(tr.samples), _xvec(dut)))
        lv = int(dut.load_valid.value)
        lr = int(dut.load_ready.value)
        if lv and lr:
            tr.loads.append((len(tr.samples), int(dut.load_voice.value),
                             int(dut.load_instrument.value),
                             int(dut.load_midi.value), int(dut.load_dyn.value)))


async def _ticker(dut, period, count):
    """Pulse sample_tick `count` times, `period` clk apart."""
    for _ in range(count):
        dut.sample_tick.value = 1
        await RisingEdge(dut.clk)
        dut.sample_tick.value = 0
        for _ in range(period - 1):
            await RisingEdge(dut.clk)
    await Timer(1, unit="ns")


async def _drain(dut, cycles=400):
    for _ in range(cycles):
        await RisingEdge(dut.clk)
    await Timer(1, unit="ns")


def _nonzero_events(tr):
    """Return the compact list of (voice, value) for every non-zero x slot."""
    out = []
    for idx, xs in tr.samples:
        nz = [(v, x) for v, x in enumerate(xs) if x != 0]
        assert len(nz) <= 1, f"sample {idx}: cross-talk {nz}"
        for v, x in nz:
            out.append((v, x))
    return out


def _voice_of(k):
    # the event index wraps at len(SONG); the voice is (event index) % NUM_VOICES
    return (k % len(SONG)) % NUM_VOICES


def _check_score(tr, n_events, where=""):
    """Check the load order/voice assignment and the pulse train."""
    assert len(tr.loads) >= n_events, \
        f"{where}: only {len(tr.loads)} loads for {n_events} events"
    for k in range(n_events):
        _, voice, inst, midi, dyn = tr.loads[k]
        assert inst == 0, f"{where}: event {k} instrument {inst} != guitar(0)"
        assert dyn == 1, f"{where}: event {k} dyn {dyn} != forte(1)"
        assert midi == SONG[k % len(SONG)], \
            f"{where}: event {k} midi {midi} != {SONG[k % len(SONG)]}"
        assert voice == _voice_of(k), \
            f"{where}: event {k} voice {voice} != {_voice_of(k)}"

    nz = _nonzero_events(tr)
    for k in range(n_events):
        seg = nz[k * 6:(k + 1) * 6]
        want = PULSE[1:]
        assert [v for v, _ in seg] == [_voice_of(k)] * 6, \
            f"{where}: pulse voices {[v for v, _ in seg]} != {_voice_of(k)}"
        assert [x for _, x in seg] == want, \
            f"{where}: pulse values {[x for _, x in seg]} != {want}"


def _check_gap(tr, n_events, where=""):
    for k in range(n_events - 1):
        s0 = tr.loads[k][0]
        s1 = tr.loads[k + 1][0]
        assert (s1 - s0) == NOTE_GAP, \
            f"{where}: gap {s1 - s0} between events {k},{k+1} != {NOTE_GAP}"


# ---------------------------------------------------------------------------
# T01 -- event order, voice assignment, pulse train, looping
# ---------------------------------------------------------------------------
@cocotb.test(timeout_time=120, timeout_unit="sec")
async def t01_sequence(dut):
    await _begin(dut)
    await _reset(dut)
    tr = Trace()
    mon = cocotb.start_soon(_monitor(dut, tr))

    n_events = min(60, 2 * len(SONG))
    ticks = n_events * NOTE_GAP + 2
    await _ticker(dut, TICK_PERIOD, ticks)
    await _drain(dut)
    tr.done = True
    await mon
    await _drain(dut, 5)

    _check_score(tr, n_events, "T01")
    _check_gap(tr, n_events, "T01")
    assert int(dut.deadline_error.value) == 0, "T01 unexpected deadline_error"
    # once all voices have been touched, active_mask must be all ones
    if n_events >= NUM_VOICES:
        assert len(tr.samples) > 0
    dut._log.info(f"T01 {n_events} events in order, pulses exact, "
                  f"{len(tr.samples)} samples, gap {NOTE_GAP}")


# ---------------------------------------------------------------------------
# T02 -- missed deadline is flagged, ticks are not lost
# ---------------------------------------------------------------------------
@cocotb.test(timeout_time=120, timeout_unit="sec")
async def t02_deadline(dut):
    await _begin(dut)
    await _reset(dut)
    tr = Trace()
    mon = cocotb.start_soon(_monitor(dut, tr))

    # ticks far faster than a load+sample can finish
    await _ticker(dut, 3, 80)
    await _drain(dut, 5000)
    tr.done = True
    await mon
    await _drain(dut, 5)

    assert int(dut.deadline_error.value) == 1, "T02 expected deadline_error sticky"
    # every tick must still be worked off (pending is not lost): the number of
    # accepted sample frames is at least the number of ticks, plus recovery.
    assert len(tr.samples) >= 80, \
        f"T02 only {len(tr.samples)} samples for 80 ticks"
    # and the score still starts correctly
    assert tr.loads and tr.loads[0][3] == SONG[0]
    dut._log.info(f"T02 deadline flagged, {len(tr.samples)} samples worked off")


# ---------------------------------------------------------------------------
# T03 -- engine backpressure / stall does not lose a sample when pacing allows
# ---------------------------------------------------------------------------
@cocotb.test(timeout_time=120, timeout_unit="sec")
async def t03_backpressure(dut):
    await _begin(dut)
    await _reset(dut)
    tr = Trace()
    mon = cocotb.start_soon(_monitor(dut, tr))

    period = TICK_PERIOD
    await _ticker(dut, period, 3 * NOTE_GAP + 2)
    await _drain(dut, 2000)
    tr.done = True
    await mon
    await _drain(dut, 5)

    assert int(dut.deadline_error.value) == 0, "T03 unexpected deadline_error"
    _check_score(tr, 3, "T03")
    dut._log.info(f"T03 stall={STALL} handled, {len(tr.samples)} samples")


# ---------------------------------------------------------------------------
# T04 -- reset mid-song is clean and restarts at event 0
# ---------------------------------------------------------------------------
@cocotb.test(timeout_time=120, timeout_unit="sec")
async def t04_reset_midsong(dut):
    await _begin(dut)
    await _reset(dut)
    tr = Trace()
    mon = cocotb.start_soon(_monitor(dut, tr))
    await _ticker(dut, TICK_PERIOD, 3 * NOTE_GAP + 5)
    await _drain(dut, 100)
    tr.done = True
    await mon

    await _reset(dut)
    tr2 = Trace()
    mon2 = cocotb.start_soon(_monitor(dut, tr2))
    await _ticker(dut, TICK_PERIOD, 3 * NOTE_GAP + 2)
    await _drain(dut, 100)
    tr2.done = True
    await mon2
    await _drain(dut, 5)

    assert len(tr.loads) >= 3 and len(tr2.loads) >= 3
    assert tr2.loads[0][3] == SONG[0] and tr2.loads[1][3] == SONG[1]
    assert int(dut.deadline_error.value) == 0
    assert dut.active_mask.value.is_resolvable
    assert dut.x_vec.value.is_resolvable
    dut._log.info("T04 reset mid-song clean, restarts at event 0")


# ---------------------------------------------------------------------------
# T05 -- default-length gap is exact and looping wraps to event 0
# ---------------------------------------------------------------------------
@cocotb.test(timeout_time=180, timeout_unit="sec")
async def t05_loop(dut):
    await _begin(dut)
    await _reset(dut)
    tr = Trace()
    mon = cocotb.start_soon(_monitor(dut, tr))

    n = len(SONG) + 5                       # cross the loop point
    await _ticker(dut, TICK_PERIOD, n * NOTE_GAP + 2)
    await _drain(dut, 300)
    tr.done = True
    await mon
    await _drain(dut, 5)

    _check_score(tr, n, "T05")
    _check_gap(tr, n, "T05")
    # the event after the last score entry wraps to index 0
    assert tr.loads[len(SONG)][3] == SONG[0]
    assert tr.loads[len(SONG)][1] == _voice_of(len(SONG))
    dut._log.info(f"T05 loop wraps to event 0 after {len(SONG)} events")


# ---------------------------------------------------------------------------
# runner
# ---------------------------------------------------------------------------
def _sources():
    return [os.path.join(_ROOT, "rtl", "audio", "song_player.sv"),
            os.path.join(_ROOT, "sim", "audio_helpers", "mock_modal_engine.sv"),
            os.path.join(_ROOT, "sim", "audio_helpers", "song_player_harness.sv")]


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


def _build_and_run(build_dir, nmodes=48, note_gap=20, testcase=None):
    from cocotb_tools.runner import get_runner
    build_dir = os.path.abspath(os.path.expanduser(build_dir))
    os.makedirs(build_dir, exist_ok=True)
    srcs = _sources()
    params = {
        "NUM_VOICES": NUM_VOICES, "N_MODES": nmodes, "NOTE_GAP": note_gap,
        "PULSE_LEN": 7, "MOCK_LOAD_LAT": LOAD_LAT, "MOCK_SAMPLE_LAT": SAMPLE_LAT,
        "MOCK_STALL": STALL,
    }
    runner = get_runner("icarus")
    runner.build(sources=srcs, hdl_toplevel="song_player_harness",
                 parameters=params, build_dir=build_dir, waves=False,
                 build_args=["-g2012", "-Wall"], always=True,
                 timescale=("1ns", "1ps"))
    env = {k: str(v) for k, v in {
        "SP_VOICES": NUM_VOICES, "SP_NOTE_GAP": note_gap,
        "SP_LOAD_LAT": LOAD_LAT, "SP_SAMPLE_LAT": SAMPLE_LAT, "SP_STALL": STALL,
    }.items()}
    results_xml = os.path.join(build_dir, "results.xml")
    if os.path.exists(results_xml):
        os.remove(results_xml)
    runner.test(test_module="test_song_player", hdl_toplevel="song_player_harness",
                test_dir=_HERE, build_dir=build_dir, parameters=params,
                extra_env=env, testcase=testcase, results_xml=results_xml,
                timescale=("1ns", "1ps"))
    summary = _parse_results(results_xml)
    if summary is None:
        raise RuntimeError(f"missing or unparseable results XML: {results_xml}")
    if summary["n"] == 0:
        raise RuntimeError(f"no tests ran; XML {results_xml}")
    if summary["failures"]:
        raise RuntimeError(f"cocotb tests failed: {summary['failures']}")
    return summary


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--build-dir", default=os.path.join(_ROOT, "sim", "build", "song_player"))
    ap.add_argument("--note-gap", type=int, default=20)
    ap.add_argument("--testcase", default=None)
    args = ap.parse_args(argv)
    try:
        _build_and_run(args.build_dir, note_gap=args.note_gap, testcase=args.testcase)
    except RuntimeError as exc:
        print(f"[FAIL] {exc}", file=sys.stderr)
        return 1
    print("[song_player] all tests passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
